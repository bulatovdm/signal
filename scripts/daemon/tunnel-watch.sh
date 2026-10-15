#!/bin/bash
# Signal — Measure the router's tunnel the way this Mac gets it, and keep a history.
#
# Runs as root under launchd next to the keeper and the link watcher (ADR-016).
# It only reads: the router through GET requests to RCI, the network through
# ping, traceroute and two downloads. Nothing on the router or the Mac changes.
#
# Why a history: "slow after the Mac is switched on, fixed by rebooting the
# router, only on the VDSina policy" is an impression until every sample carries
# the tunnel's UDP port, whether the tunnel was busy with someone else's traffic,
# and what the Mac actually got. The router picks a new random port on every
# boot, so a flow stuck on a bad path would show up as slow samples on one port
# and normal ones after the port changed.
#
# Written for /bin/bash 3.2 — no associative arrays, no mapfile, BSD date/sed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/lib" ]]; then LIB_DIR="$SCRIPT_DIR/lib"; else LIB_DIR="$SCRIPT_DIR/../lib"; fi
source "$LIB_DIR/awdl.sh"
source "$LIB_DIR/stats.sh"
source "$LIB_DIR/router.sh"

STATE_DIR="${SIGNAL_STATE_DIR:-/usr/local/var/run/signal}"
TUNNEL_STATUS_FILE="$STATE_DIR/tunnel"
MARK_FILE="$STATE_DIR/tunnel-mark"
LOG_DIR="${SIGNAL_LOG_DIR:-/usr/local/var/log/signal}"
EVENTS_FILE="$LOG_DIR/tunnel.log"
CONFIG_FILE="${SIGNAL_CONFIG_FILE:-/usr/local/etc/signal/keeper.conf}"

TUNNEL_INTERVAL_SECONDS=900
# The cable, not whatever carries the default route: Dmitriy moves the Wi-Fi
# side to another tunnel at times, and the history must stay about one path.
# Every probe is bound to this interface, and the policy is looked up by its MAC.
TUNNEL_INTERFACE="${SIGNAL_TUNNEL_INTERFACE:-en0}"
# How often the wait between samples looks at the mark file.
TUNNEL_MARK_POLL_SECONDS=10
# Traffic through the tunnel is counted over this window before the probe, so
# the probe's own downloads never count as someone else's load.
TUNNEL_BUSY_WINDOW_SECONDS=5
TUNNEL_BUSY_MBIT=10
TUNNEL_PING_HOST=1.1.1.1
TUNNEL_PING_COUNT=20
TUNNEL_PING_INTERVAL=0.2
TUNNEL_HOP_PROBES=6
# Two sources, because one lies: Cloudflare answers 429 and slows down after a
# series of requests (veil, 2026-09-16).
TUNNEL_CLOUDFLARE_URL="https://speed.cloudflare.com/__down?bytes=10000000"
TUNNEL_OVH_URL="https://proof.ovh.net/files/1Gb.dat"
TUNNEL_OVH_RANGE="0-10485759"
TUNNEL_DOWNLOAD_TIMEOUT=20
# Provisional: the clean measurement on 2026-10-09 gave 67–90 Mbit/s through
# VDSina. Revisit once the history shows what a bad morning looks like.
TUNNEL_SLOW_MBIT=30
# The first sample waits for the network after boot, but not forever.
TUNNEL_BOOT_WAIT_SECONDS=120
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

# The mark file belongs to whoever is at the keyboard, like the keeper's
# request file (ADR-005): `signal mark` writes it without sudo.
ensure_state_files() {
    mkdir -p "$STATE_DIR" "$LOG_DIR"
    chmod 755 "$STATE_DIR" "$LOG_DIR"
    [[ -f "$MARK_FILE" ]] || : > "$MARK_FILE"
    local console_user
    console_user=$(stat -f '%Su' /dev/console 2>/dev/null)
    if [[ -n "$console_user" && "$console_user" != "root" ]]; then
        chown "$console_user" "$MARK_FILE" 2>/dev/null
    fi
    chmod 644 "$MARK_FILE"
}

# "epoch text" — the epoch tells a new mark from one already handled.
read_mark() { head -1 "$MARK_FILE" 2>/dev/null; }

mbit_between() {
    local before=$1 after=$2 seconds=$3
    if [[ -n "$before" && -n "$after" && "$before" != "?" && "$after" != "?" && "$after" -ge "$before" ]]; then
        awk -v a="$before" -v b="$after" -v s="$seconds" 'BEGIN { printf "%.1f", (b - a) * 8 / s / 1000000 }'
    else
        echo "?"
    fi
}

# Sets ROUTER_UPTIME CPULOAD POLICY TUNNEL PORT HANDSHAKE and leaves the session
# open for the busy window. POLICY "-" means the Mac has no policy and goes
# straight to the provider; TUNNEL "-" means no tunnel carries its traffic.
router_snapshot() {
    ROUTER_UPTIME="?"; CPULOAD="?"; POLICY="?"; TUNNEL="?"; PORT="?"; HANDSHAKE="?"
    router_load_config || return 1
    router_login || return 1

    local system mac
    system=$(router_get /show/system) || return 1
    ROUTER_UPTIME=$("$JQ_BIN" -r '.uptime // "?"' <<<"$system")
    CPULOAD=$("$JQ_BIN" -r '.cpuload // "?"' <<<"$system")

    mac=$(ifconfig "$IFACE" ether 2>/dev/null | awk '/ether/ {print $2; exit}')
    read -r POLICY TUNNEL <<<"$(router_policy_tunnel "$mac")"
    case "$TUNNEL" in
        Wireguard*) read -r PORT HANDSHAKE <<<"$(router_tunnel_peer "$TUNNEL")" ;;
    esac
    [[ -n "$PORT" ]] || PORT="?"; [[ -n "$HANDSHAKE" ]] || HANDSHAKE="?"
    return 0
}

# Traffic in the tunnel (towards home / from home) and on the Mac's own
# interface over the busy window, before the probe adds any of its own.
measure_busy() {
    TUNNEL_DOWN_MBIT="?"; TUNNEL_UP_MBIT="?"; MAC_MBIT="?"
    local rx1="" tx1="" rx2="" tx2="" mac1 mac2 started finished seconds
    case "$TUNNEL" in Wireguard*) read -r rx1 tx1 <<<"$(router_interface_bytes "$TUNNEL")" ;; esac
    mac1=$(interface_bytes "$IFACE")
    started=$(date +%s)
    sleep "$TUNNEL_BUSY_WINDOW_SECONDS"
    case "$TUNNEL" in Wireguard*) read -r rx2 tx2 <<<"$(router_interface_bytes "$TUNNEL")" ;; esac
    mac2=$(interface_bytes "$IFACE")
    finished=$(date +%s)
    seconds=$((finished - started)); [[ $seconds -gt 0 ]] || seconds=1
    # The router's rxbytes on a tunnel are what came out of it — towards home.
    TUNNEL_DOWN_MBIT=$(mbit_between "$rx1" "$rx2" "$seconds")
    TUNNEL_UP_MBIT=$(mbit_between "$tx1" "$tx2" "$seconds")
    MAC_MBIT=$(mbit_between "$mac1" "$mac2" "$seconds")
}

# "address median replies" of the second hop. Behind the router's tunnel it is
# the entry node; without a policy it is the provider.
second_hop() {
    traceroute -n -i "$IFACE" -f 2 -m 2 -q "$TUNNEL_HOP_PROBES" -w 1 "$TUNNEL_PING_HOST" 2>/dev/null | awk '
        {
            for (i = 1; i <= NF; i++) {
                if (address == "" && $i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) address = $i
                if ($(i + 1) == "ms") values[n++] = $i + 0
            }
        }
        END {
            if (n == 0) { printf "%s ? 0\n", (address == "" ? "?" : address); exit }
            for (i = 0; i < n - 1; i++)
                for (j = 0; j < n - 1 - i; j++)
                    if (values[j] > values[j+1]) { t = values[j]; values[j] = values[j+1]; values[j+1] = t }
            printf "%s %.1f %d\n", address, values[int(n / 2)], n
        }'
}

# Mbit/s of one download, or "?" when the source refused (429 and the like).
download_mbit() {
    local url=$1 range=${2:-} answer code speed
    if [[ -n "$range" ]]; then
        answer=$(/usr/bin/curl -s -o /dev/null --interface "$IFACE" -m "$TUNNEL_DOWNLOAD_TIMEOUT" -r "$range" -w '%{http_code} %{speed_download}' "$url" 2>/dev/null)
    else
        answer=$(/usr/bin/curl -s -o /dev/null --interface "$IFACE" -m "$TUNNEL_DOWNLOAD_TIMEOUT" -w '%{http_code} %{speed_download}' "$url" 2>/dev/null)
    fi
    read -r code speed <<<"$answer"
    case "$code" in
        200|206) awk -v s="$speed" 'BEGIN { printf "%.1f", s * 8 / 1000000 }' ;;
        *) echo "?" ;;
    esac
}

best_of() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        if (a == "?" && b == "?") { print "?"; exit }
        if (a == "?") { print b; exit }
        if (b == "?") { print a; exit }
        print (a + 0 >= b + 0) ? a : b
    }'
}

is_at_least() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a != "?" && a + 0 >= b + 0) }'; }
is_below()    { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a != "?" && a + 0 <  b + 0) }'; }

take_sample() {
    IFACE="$TUNNEL_INTERFACE"
    router_snapshot
    measure_busy
    router_logout

    local output
    output="$(ping -b "$IFACE" -c "$TUNNEL_PING_COUNT" -i "$TUNNEL_PING_INTERVAL" -t $((TUNNEL_PING_COUNT / 4 + 5)) "$TUNNEL_PING_HOST" 2>&1)"
    read -r _ _ PING_MAX _ PING_P50 PING_P95 _ _ <<<"$(rtt_stats <<<"$output")"
    PING_LOSS="$(ping_loss_pct <<<"$output")"

    read -r HOP2 HOP2_RTT HOP2_REPLIES <<<"$(second_hop)"

    CF_MBIT="$(download_mbit "$TUNNEL_CLOUDFLARE_URL")"
    OVH_MBIT="$(download_mbit "$TUNNEL_OVH_URL" "$TUNNEL_OVH_RANGE")"
    BEST_MBIT="$(best_of "$CF_MBIT" "$OVH_MBIT")"
}

classify() {
    if ! interface_is_active "$IFACE"; then
        VERDICT="нет кабеля"
    elif [[ "$PING_LOSS" == "100" && "$BEST_MBIT" == "?" ]]; then
        VERDICT="нет связи"
    elif is_at_least "$TUNNEL_DOWN_MBIT" "$TUNNEL_BUSY_MBIT"; then
        VERDICT="занят"
    elif [[ "$BEST_MBIT" == "?" ]] || is_below "$BEST_MBIT" "$TUNNEL_SLOW_MBIT"; then
        VERDICT="медленно"
    else
        VERDICT="норма"
    fi
}

csv_file() { echo "$LOG_DIR/tunnel-$(date +%Y-%m).csv"; }

append_sample() {
    local file
    file="$(csv_file)"
    if [[ ! -f "$file" ]]; then
        echo "timestamp,mark,verdict,interface,policy,tunnel,port,router_uptime_s,router_cpu_pct,handshake_s,tunnel_down_mbit,tunnel_up_mbit,mac_mbit,ping_loss_pct,ping_p50,ping_p95,ping_max,hop2,hop2_rtt,hop2_replies,cloudflare_mbit,ovh_mbit" > "$file"
    fi
    # The mark text is stripped of commas and quotes by `signal mark`.
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SAMPLE_MARK" "$VERDICT" "$IFACE" "$POLICY" "$TUNNEL" "$PORT" \
        "$ROUTER_UPTIME" "$CPULOAD" "$HANDSHAKE" "$TUNNEL_DOWN_MBIT" "$TUNNEL_UP_MBIT" "$MAC_MBIT" \
        "$PING_LOSS" "$PING_P50" "$PING_P95" "$PING_MAX" "$HOP2" "$HOP2_RTT" "$HOP2_REPLIES" \
        "$CF_MBIT" "$OVH_MBIT" >> "$file"
    chmod 644 "$file" 2>/dev/null
}

write_status() {
    local temporary="$TUNNEL_STATUS_FILE.tmp"
    cat > "$temporary" <<STATUS
{"updated":$(date +%s),"interval":$TUNNEL_INTERVAL_SECONDS,"verdict":"$VERDICT","mark":"$SAMPLE_MARK","interface":"$IFACE","policy":"$POLICY","tunnel":"$TUNNEL","port":"$PORT","router_uptime":"$ROUTER_UPTIME","cpuload":"$CPULOAD","handshake":"$HANDSHAKE","tunnel_down":"$TUNNEL_DOWN_MBIT","mac_mbit":"$MAC_MBIT","ping_p50":"$PING_P50","ping_max":"$PING_MAX","ping_loss":"$PING_LOSS","hop2":"$HOP2","hop2_rtt":"$HOP2_RTT","cloudflare":"$CF_MBIT","ovh":"$OVH_MBIT","slow_since":$SLOW_SINCE,"pid":$$}
STATUS
    mv -f "$temporary" "$TUNNEL_STATUS_FILE"
    chmod 644 "$TUNNEL_STATUS_FILE"
}

human_duration() {
    local minutes=$(( ($1 + 30) / 60 ))
    if [[ $minutes -lt 60 ]]; then echo "${minutes} мин"; else echo "$((minutes / 60)) ч $((minutes % 60)) мин"; fi
}

# Router reboots, port and policy changes are what the hypothesis is about, so
# they go to the event log as soon as a sample sees them.
log_changes() {
    if [[ "$ROUTER_UPTIME" != "?" && "$LAST_UPTIME" != "?" && "$ROUTER_UPTIME" -lt "$LAST_UPTIME" ]]; then
        log_event "роутер перезагружен (работает $(human_duration "$ROUTER_UPTIME")), порт $TUNNEL: $LAST_PORT → $PORT"
    elif [[ "$PORT" != "?" && "$LAST_PORT" != "?" && "$PORT" != "$LAST_PORT" && "$TUNNEL" == "$LAST_TUNNEL" ]]; then
        log_event "порт $TUNNEL сменился без перезагрузки роутера: $LAST_PORT → $PORT"
    fi
    if [[ "$LAST_TUNNEL" != "?" && "$TUNNEL" != "?" && "$TUNNEL" != "$LAST_TUNNEL" ]]; then
        log_event "трафик Mac теперь идёт через ${TUNNEL} (политика ${POLICY}), было ${LAST_TUNNEL}"
    fi
    [[ "$ROUTER_UPTIME" != "?" ]] && LAST_UPTIME="$ROUTER_UPTIME"
    [[ "$PORT" != "?" ]] && LAST_PORT="$PORT"
    [[ "$TUNNEL" != "?" ]] && LAST_TUNNEL="$TUNNEL"
}

log_episode() {
    local now
    now=$(date +%s)
    if [[ "$VERDICT" == "медленно" || "$VERDICT" == "нет связи" ]]; then
        if [[ $SLOW_SINCE -eq 0 ]]; then
            SLOW_SINCE=$now
            log_event "$VERDICT: Cloudflare $CF_MBIT, OVH $OVH_MBIT Мбит/с, ping p50 $PING_P50, потери $PING_LOSS% ($TUNNEL, порт $PORT, роутер работает $(human_duration "${ROUTER_UPTIME/\?/0}"))"
        fi
    elif [[ $SLOW_SINCE -ne 0 && "$VERDICT" == "норма" ]]; then
        log_event "снова норма после $(human_duration $((now - SLOW_SINCE))): Cloudflare $CF_MBIT, OVH $OVH_MBIT Мбит/с ($TUNNEL, порт $PORT)"
        SLOW_SINCE=0
    fi
}

run_sample() {
    take_sample
    classify
    log_changes
    log_episode
    append_sample
    write_status
}

# After boot the network comes up a few seconds after launchd starts us; the
# first sample is the one the complaint is about, so it waits for the gateway.
wait_for_network() {
    local waited=0
    while [[ $waited -lt $TUNNEL_BOOT_WAIT_SECONDS ]]; do
        ping -c 1 -t 2 "$(default_gateway)" >/dev/null 2>&1 && return 0
        sleep 5; waited=$((waited + 5))
    done
    return 1
}

# Waits until the next sample is due, or returns early when a new mark arrives.
# Sets SAMPLE_MARK to the mark's text, or to "" for a scheduled sample.
wait_for_next() {
    local due=$1 mark epoch text
    while [[ $(date +%s) -lt $due ]]; do
        mark="$(read_mark)"
        epoch="${mark%% *}"
        if [[ -n "$mark" && "$epoch" != "$LAST_MARK_EPOCH" ]]; then
            LAST_MARK_EPOCH="$epoch"
            text="${mark#* }"; [[ "$text" == "$mark" ]] && text=""
            SAMPLE_MARK="${text:-отметка}"
            log_event "отметка: $SAMPLE_MARK — внеочередной замер"
            return
        fi
        sleep "$TUNNEL_MARK_POLL_SECONDS"
    done
    SAMPLE_MARK=""
}

# --once takes a single sample and exits: for trying the watcher from the repo
# with SIGNAL_STATE_DIR and SIGNAL_LOG_DIR pointed somewhere harmless.
ONCE=false
[[ "${1:-}" == "--once" ]] && ONCE=true

main() {
    ensure_state_files
    SLOW_SINCE=0
    LAST_UPTIME="?"; LAST_PORT="?"; LAST_TUNNEL="?"
    SAMPLE_MARK=""
    # A mark left from before the start is history, not a request.
    LAST_MARK_EPOCH="$(read_mark)"; LAST_MARK_EPOCH="${LAST_MARK_EPOCH%% *}"

    if [[ "$ONCE" != true ]]; then
        local router_note="роутер читается"
        router_load_config || router_note="роутер не читается: нет $ROUTER_CONFIG_FILE или jq"
        log_event "наблюдатель туннеля запущен (pid $$, раз в $((TUNNEL_INTERVAL_SECONDS / 60)) мин и по отметке; $router_note)"
        wait_for_network || log_event "шлюз не ответил за ${TUNNEL_BOOT_WAIT_SECONDS} с после запуска — замеряю как есть"
    fi

    while true; do
        local cycle_started
        cycle_started=$(date +%s)
        run_sample
        [[ "$ONCE" == true ]] && break
        wait_for_next $((cycle_started + TUNNEL_INTERVAL_SECONDS))
    done
}

main
