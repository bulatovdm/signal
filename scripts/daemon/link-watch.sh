#!/bin/bash
# Signal — Watch the Wi-Fi link once a minute and name the cause when it goes bad.
#
# Runs as root under launchd next to the keeper, but never touches an
# interface: it only reads (ADR-014). The keeper stays the single owner of
# awdl0, and nobody owns en1 but the user.
#
# Why a history at all: the problems come and go, and without one every episode
# starts from guessing. On 2026-09-23 the cause (a Mac left associated through a
# 2.4 → 5 GHz fast transition, 23% of downlink frames retried) was found only
# by digging through the unified log by hand. Every sample here keeps the
# numbers that told that story apart from AWDL and from a busy uplink.
#
# Why root: macOS redacts the BSSID for everyone else, and the BSSID is what the
# driver's peer is compared against.
#
# Written for /bin/bash 3.2 — no associative arrays, no mapfile, BSD date/sed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Installed next to its lib (/usr/local/libexec/signal/lib); run from the repo,
# the lib is a sibling of daemon/.
if [[ -d "$SCRIPT_DIR/lib" ]]; then LIB_DIR="$SCRIPT_DIR/lib"; else LIB_DIR="$SCRIPT_DIR/../lib"; fi
source "$LIB_DIR/awdl.sh"
source "$LIB_DIR/stats.sh"

STATE_DIR="${SIGNAL_STATE_DIR:-/usr/local/var/run/signal}"
LINK_STATUS_FILE="$STATE_DIR/link"
LOG_DIR="${SIGNAL_LOG_DIR:-/usr/local/var/log/signal}"
EVENTS_FILE="$LOG_DIR/link.log"
CONFIG_FILE="${SIGNAL_CONFIG_FILE:-/usr/local/etc/signal/keeper.conf}"

LINK_INTERVAL_SECONDS=60
# 20 replies at 0.1 s: two seconds of probing a minute is enough to see a
# median of 60 ms against 3, and too little to disturb anything.
LINK_PING_COUNT=20
LINK_PING_INTERVAL=0.1
# Same acceptance limits as `signal measure`, so "норма" means one thing.
LINK_MAX_LIMIT=10.0
LINK_STDDEV_LIMIT=1.5
# What makes a minute "плохо" rather than "всплески": a median this high is felt
# in every page load, while AWDL spikes leave the median at 3 ms.
LINK_BAD_P50=10
LINK_BAD_LOSS_PCT=10
# Downlink retries: 1.5% on a healthy association, 23% on the broken one.
LINK_RETRY_PCT=10
LINK_WEAK_RSSI=-70
LINK_BACKGROUND_MBIT=10.0
LOG_MAX_BYTES=524288

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log_event() {
    mkdir -p "$LOG_DIR"
    if [[ -f "$EVENTS_FILE" ]]; then
        local size
        size=$(stat -f%z "$EVENTS_FILE" 2>/dev/null || echo 0)
        [[ "$size" -gt "$LOG_MAX_BYTES" ]] && mv -f "$EVENTS_FILE" "${EVENTS_FILE}.1"
    fi
    echo "$(timestamp) $1" >> "$EVENTS_FILE"
    chmod 644 "$EVENTS_FILE" 2>/dev/null
}

# airport prints octets without leading zeros ("0:1a:…"); the kernel log prints
# them upper-case. Both are brought to one spelling before comparing.
normalize_mac() {
    awk -F: 'NF == 6 {
        out = ""
        for (i = 1; i <= 6; i++) {
            octet = tolower($i); if (length(octet) == 1) octet = "0" octet
            out = out (i > 1 ? ":" : "") octet
        }
        print out; exit
    } { print "?"; exit }'
}

current_bssid() {
    local raw
    raw=$(ipconfig getsummary "$WIFI_INTERFACE" 2>/dev/null | awk -F' : ' '/^ *BSSID/ {print $2; exit}')
    case "$raw" in
        ""|*redacted*)
            raw=$(wdutil info 2>/dev/null | awk -F': ' '/^ *BSSID/ {gsub(/ /, "", $2); print $2; exit}') ;;
    esac
    case "$raw" in
        ""|*redacted*|None) echo "?" ;;
        *) normalize_mac <<<"$raw" ;;
    esac
}

# The peer the driver keeps link statistics for. On a healthy association it is
# the BSSID; after the 2.4 → 5 GHz transition on 2026-09-23 it stayed the
# 2.4 GHz BSSID while the radio sat on channel 149.
kernel_peer() {
    local raw
    raw=$(/usr/bin/log show --last "${LINK_INTERVAL_SECONDS}s" --style compact \
            --predicate 'process == "kernel" AND eventMessage CONTAINS "LQM-WIFI: TX("' 2>/dev/null \
        | grep -oE 'TX\([0-9A-Fa-f:]{17}\)' | grep -viE 'ff:ff:ff:ff:ff:ff' | tail -1 \
        | sed -E 's/TX\((.*)\)/\1/')
    if [[ -n "$raw" ]]; then normalize_mac <<<"$raw"; else echo "?"; fi
}

# Frame counters summed over the last interval of airportd's link-quality
# reports (one every 5 s): "rx_frames rx_retry tx_frames tx_retrans".
# Undocumented log format — when it changes, the columns turn to "?" and the
# RTT columns still carry the symptom.
link_quality_counters() {
    /usr/bin/log show --last "${LINK_INTERVAL_SECONDS}s" --style compact \
            --predicate 'process == "airportd" AND eventMessage CONTAINS "LQM: rssi"' 2>/dev/null \
        | awk '{
            for (i = 1; i <= NF; i++) {
                split($i, kv, "=")
                if (kv[1] == "rxFrames") rx += kv[2]
                else if (kv[1] == "rxRetryFrames") rr += kv[2]
                else if (kv[1] == "txFrames") tx += kv[2]
                else if (kv[1] == "txRetrans") tr += kv[2]
            }
            seen++
        }
        END {
            if (seen == 0) { print "? ? ? ?"; exit }
            printf "%d %d %d %d\n", rx, rr, tx, tr
        }'
}

percent_of() {
    awk -v part="$1" -v whole="$2" 'BEGIN {
        if (part == "?" || whole == "?" || whole + 0 == 0) { print "?"; exit }
        printf "%.1f", part * 100 / whole
    }'
}

# One airport call for everything the radio says: "channel rssi noise tx_rate".
# The channel arrives as "149,80" and is stored as "149/80" (CSV and JSON safe).
radio_snapshot() {
    [[ -x "$AIRPORT_BIN" ]] || { echo "? ? ? ?"; return; }
    "$AIRPORT_BIN" -I 2>/dev/null | awk -F': ' '
        /agrCtlRSSI/ { rssi = $2 } /agrCtlNoise/ { noise = $2 }
        /lastTxRate/ { rate = $2 } /^ *channel/ { channel = $2 }
        END {
            gsub(/ /, "", channel); gsub(/,/, "/", channel)
            gsub(/ /, "", rssi); gsub(/ /, "", noise); gsub(/ /, "", rate)
            printf "%s %s %s %s\n", (channel == "" ? "?" : channel), (rssi == "" ? "?" : rssi),
                                    (noise == "" ? "?" : noise), (rate == "" ? "?" : rate)
        }'
}

is_at_least() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a != "?" && a + 0 >= b + 0) }'; }
is_below()    { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a != "?" && a + 0 <  b + 0) }'; }

# Sets VERDICT, CAUSE_KIND, CAUSE and HINT. The cause is looked for only when
# the minute is not clean, in the order of how cheap it is to rule out: AWDL
# and background traffic explain a bad minute by themselves; only when both are
# absent do the association and the retries become the suspects.
classify() {
    VERDICT="норма"; CAUSE_KIND=""; CAUSE=""; HINT=""

    if [[ "$RECEIVED" -eq 0 ]]; then
        VERDICT="нет связи"; CAUSE_KIND="nolink"; CAUSE="шлюз $GATEWAY не отвечает"
        HINT="проверить подключение Wi-Fi"
        return
    fi

    if is_at_least "$P50" "$LINK_BAD_P50" || is_at_least "$LOSS" "$LINK_BAD_LOSS_PCT"; then
        VERDICT="плохо"
    elif is_below "$MAX" "$LINK_MAX_LIMIT" && is_below "$STDDEV" "$LINK_STDDEV_LIMIT" \
            && [[ "$LOSS" == "0" ]]; then
        return
    else
        VERDICT="всплески"
    fi

    if [[ "$AWDL" != "down" ]]; then
        CAUSE_KIND="awdl"; CAUSE="AWDL активен"
        HINT="сторож погасит его после grace"
    elif is_at_least "$BACKGROUND" "$LINK_BACKGROUND_MBIT"; then
        CAUSE_KIND="background"; CAUSE="фоновый трафик $BACKGROUND Мбит/с"
        HINT="закачка или синхронизация занимает канал"
    elif [[ "$BSSID" != "?" && "$PEER" != "?" && "$PEER" != "$BSSID" ]]; then
        CAUSE_KIND="peer"; CAUSE="драйвер ведёт пира $PEER при BSSID $BSSID"
        HINT="переподключить Wi-Fi"
    elif is_at_least "$RX_RETRY_PCT" "$LINK_RETRY_PCT"; then
        CAUSE_KIND="retry"; CAUSE="повторы на приёме $RX_RETRY_PCT%"
        HINT="переподключить Wi-Fi"
    elif is_below "$RSSI" "$LINK_WEAK_RSSI"; then
        CAUSE_KIND="weak"; CAUSE="слабый сигнал $RSSI dBm"
        HINT=""
    else
        CAUSE_KIND="unknown"; CAUSE="причина не определена"
        HINT="signal measure и журнал сессии"
    fi
}

csv_file() { echo "$LOG_DIR/link-$(date +%Y-%m).csv"; }

append_sample() {
    local file
    file="$(csv_file)"
    if [[ ! -f "$file" ]]; then
        echo "timestamp,gateway,count,received,loss_pct,min,avg,max,stddev,p50,p95,awdl,background_mbit,channel,rssi,noise,tx_rate,bssid,peer,rx_frames,rx_retry_pct,tx_frames,tx_retry_pct,verdict,cause" > "$file"
    fi
    # Causes are written by this script and never contain commas.
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$GATEWAY" "$LINK_PING_COUNT" "$RECEIVED" "$LOSS" \
        "$MIN" "$AVG" "$MAX" "$STDDEV" "$P50" "$P95" "$AWDL" "$BACKGROUND" \
        "$CHANNEL" "$RSSI" "$NOISE" "$TX_RATE" "$BSSID" "$PEER" \
        "$RX_FRAMES" "$RX_RETRY_PCT" "$TX_FRAMES" "$TX_RETRY_PCT" "$VERDICT" "$CAUSE" >> "$file"
    chmod 644 "$file" 2>/dev/null
}

write_status() {
    local temporary="$LINK_STATUS_FILE.tmp"
    cat > "$temporary" <<STATUS
{"updated":$(date +%s),"interval":$LINK_INTERVAL_SECONDS,"verdict":"$VERDICT","cause_kind":"$CAUSE_KIND","cause":"$CAUSE","hint":"$HINT","bad_since":$BAD_SINCE,"p50":$P50,"p95":$P95,"max":$MAX,"loss":$LOSS,"awdl":"$AWDL","background":"$BACKGROUND","channel":"$CHANNEL","rssi":"$RSSI","bssid":"$BSSID","peer":"$PEER","rx_retry_pct":"$RX_RETRY_PCT","pid":$$}
STATUS
    mv -f "$temporary" "$LINK_STATUS_FILE"
    chmod 644 "$LINK_STATUS_FILE"
}

human_minutes() {
    local minutes=$(( ($1 + 30) / 60 ))
    if [[ $minutes -lt 60 ]]; then echo "${minutes} мин"; else echo "$((minutes / 60)) ч $((minutes % 60)) мин"; fi
}

take_sample() {
    GATEWAY="$(default_gateway)"
    local awdl_before bytes_before bytes_after started finished output stats
    awdl_before="$(awdl_state_word)"
    bytes_before="$(interface_bytes "$WIFI_INTERFACE")"
    started=$(date +%s)
    output="$(ping -c "$LINK_PING_COUNT" -i "$LINK_PING_INTERVAL" -t $((LINK_PING_COUNT / 5 + 5)) "$GATEWAY" 2>&1)"
    finished=$(date +%s)
    bytes_after="$(interface_bytes "$WIFI_INTERFACE")"

    stats="$(rtt_stats <<<"$output")"
    read -r MIN AVG MAX STDDEV P50 P95 _ RECEIVED <<<"$stats"
    LOSS="$(ping_loss_pct <<<"$output")"
    BACKGROUND="$(background_mbit "${bytes_before:-}" "${bytes_after:-}" $((finished - started)))"

    AWDL="$(awdl_state_word)"
    [[ "$awdl_before" == "$AWDL" ]] || AWDL="${awdl_before}→${AWDL}"

    read -r CHANNEL RSSI NOISE TX_RATE <<<"$(radio_snapshot)"
    BSSID="$(current_bssid)"
    PEER="$(kernel_peer)"

    local rx_retry tx_retrans
    read -r RX_FRAMES rx_retry TX_FRAMES tx_retrans <<<"$(link_quality_counters)"
    RX_RETRY_PCT="$(percent_of "$rx_retry" "$RX_FRAMES")"
    TX_RETRY_PCT="$(percent_of "$tx_retrans" "$TX_FRAMES")"
}

# --once takes a single sample and exits: for trying the watcher from the repo
# with SIGNAL_STATE_DIR and SIGNAL_LOG_DIR pointed somewhere harmless.
ONCE=false
[[ "${1:-}" == "--once" ]] && ONCE=true

main() {
    mkdir -p "$STATE_DIR" "$LOG_DIR"
    chmod 755 "$STATE_DIR" "$LOG_DIR"
    [[ "$ONCE" == true ]] || log_event "наблюдатель запущен (pid $$, раз в ${LINK_INTERVAL_SECONDS}с, ${LINK_PING_COUNT} ping)"

    BAD_SINCE=0
    local last_kind=""

    while true; do
        local cycle_started now
        cycle_started=$(date +%s)

        take_sample
        classify
        now=$(date +%s)

        # Only "плохо" and "нет связи" open an episode: "всплески" is a single
        # glitch in 20 replies far more often than it is a trend.
        if [[ "$VERDICT" == "плохо" || "$VERDICT" == "нет связи" ]]; then
            if [[ $BAD_SINCE -eq 0 ]]; then
                BAD_SINCE=$now
                log_event "$VERDICT: $CAUSE (p50 $P50, max $MAX, потери $LOSS%)${HINT:+ — $HINT}"
            elif [[ "$CAUSE_KIND" != "$last_kind" ]]; then
                log_event "всё ещё $VERDICT, причина теперь: $CAUSE"
            fi
            last_kind=$CAUSE_KIND
        elif [[ $BAD_SINCE -ne 0 ]]; then
            log_event "снова $VERDICT после $(human_minutes $((now - BAD_SINCE))) плохого канала (p50 $P50)"
            BAD_SINCE=0
            last_kind=""
        fi

        append_sample
        write_status

        [[ "$ONCE" == true ]] && break

        local elapsed=$(( $(date +%s) - cycle_started ))
        [[ $elapsed -lt $LINK_INTERVAL_SECONDS ]] && sleep $((LINK_INTERVAL_SECONDS - elapsed))
    done
}

main
