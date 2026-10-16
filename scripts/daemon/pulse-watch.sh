#!/bin/bash
# Signal — A heartbeat every 5 s on every path a page load depends on, and a
# snapshot of the router the moment one of them goes quiet (ADR-017).
#
# Why: on 2026-10-15 Dmitriy saw the browser hang for a minute or two while the
# link watcher (2 s of pings a minute) and the tunnel watcher (every 15 min)
# recorded nothing, and nothing could be found afterwards. An outage has to be
# caught while it lasts, and the place it lives in has to be named by which
# checks failed together:
#   the router by cable / by Wi-Fi     — the Mac's own link and the router;
#   the internet by cable / by Wi-Fi   — everything past the router, per tunnel;
#   DNS the way a browser asks         — the system resolver, a never-asked name;
#   HTTPS by cable                     — TCP and TLS, when ping still passes.
# Two more, by cable, only locate an outage once it is open (they never open
# one): the entry node (hop 2) and the exit node's tunnel address. On
# 2026-10-15 two outages were caught with the router and DNS alive and the
# internet gone through the VDSina tunnel; these tell home → entry from
# entry → exit from exit → internet.
#
# Like the other watchers it only reads: no interface, route or router setting
# changes. Written for /bin/bash 3.2 — no associative arrays, no mapfile.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/lib" ]]; then LIB_DIR="$SCRIPT_DIR/lib"; else LIB_DIR="$SCRIPT_DIR/../lib"; fi
source "$LIB_DIR/awdl.sh"
source "$LIB_DIR/router.sh"

STATE_DIR="${SIGNAL_STATE_DIR:-/usr/local/var/run/signal}"
PULSE_STATUS_FILE="$STATE_DIR/pulse"
LOG_DIR="${SIGNAL_LOG_DIR:-/usr/local/var/log/signal}"
EVENTS_FILE="$LOG_DIR/pulse.log"
SNAPSHOT_DIR="$LOG_DIR/pulse"
CONFIG_FILE="${SIGNAL_CONFIG_FILE:-/usr/local/etc/signal/keeper.conf}"

PULSE_INTERVAL_SECONDS=5
# Two misses in a row: a single lost ping is noise, ten seconds of silence is
# what a person notices.
PULSE_FAILS_TO_OPEN=2
PULSE_CABLE_INTERFACE=en0
PULSE_WIFI_INTERFACE="$WIFI_INTERFACE"
PULSE_INTERNET_HOST=1.1.1.1
PULSE_HTTPS_URL="https://www.gstatic.com/generate_204"
# github.io answers any label (wildcard), so a fresh name always has an answer
# and neither the Mac nor the router can serve it from cache.
PULSE_DNS_ZONE=github.io
# The exit node's address inside the inter-node tunnel (veil: wg0 10.30.0.0/24).
PULSE_EXIT_HOST=10.30.0.1
PULSE_SNAPSHOTS_KEPT=200
LOG_MAX_BYTES=524288

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

CHECKS="gw_cable gw_wifi net_cable net_wifi dns https"
LOCATORS="entry_cable exit_cable"
CSV_HEADER="timestamp,cycles,gw_cable,gw_wifi,net_cable,net_wifi,dns,https,entry_cable,exit_cable,outage"

check_title() {
    case "$1" in
        gw_cable)  echo "роутер по кабелю" ;;
        gw_wifi)   echo "роутер по Wi-Fi" ;;
        net_cable) echo "интернет по кабелю" ;;
        net_wifi)  echo "интернет по Wi-Fi" ;;
        dns)       echo "DNS" ;;
        https)     echo "HTTPS" ;;
        entry_cable) echo "входной сервер" ;;
        exit_cable)  echo "выходной сервер" ;;
    esac
}

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

# Each probe writes ok, fail or skip (interface not active) into its own file,
# so all six run at once and a cycle lasts as long as the slowest one.
probe_ping() {
    local name=$1 interface=$2 host=$3
    if ! interface_is_active "$interface"; then echo skip > "$WORK/$name"; return; fi
    if ping -b "$interface" -c 1 -t 2 "$host" >/dev/null 2>&1; then echo ok; else echo fail; fi > "$WORK/$name"
}

# dscacheutil goes through the system resolver like a browser does; perl's alarm
# gives it a deadline it does not have of its own.
probe_dns() {
    local output
    output=$(/usr/bin/perl -e 'alarm 3; exec @ARGV' /usr/bin/dscacheutil -q host -a name "p$RANDOM$RANDOM.$PULSE_DNS_ZONE" 2>/dev/null)
    if grep -q 'address' <<<"$output"; then
        echo ok
    else
        echo fail
    fi > "$WORK/dns"
}

# The entry node does not answer ping from home (veil: replies from 10.60.0.0/24
# go into wg0), but it does send "time exceeded" for TTL 2 — rate-limited, about
# 40% lost even when idle (2026-10-09). Three tries, alive if any came back.
probe_entry() {
    if ! interface_is_active "$PULSE_CABLE_INTERFACE"; then echo skip > "$WORK/entry_cable"; return; fi
    # ping itself exits non-zero (no echo reply ever comes back), and under
    # pipefail that would fail a piped grep too: read the output first.
    local output
    output=$(ping -b "$PULSE_CABLE_INTERFACE" -m 2 -c 3 -i 0.2 -t 2 "$PULSE_INTERNET_HOST" 2>/dev/null)
    if grep -q 'Time to live exceeded' <<<"$output"; then
        echo ok
    else
        echo fail
    fi > "$WORK/entry_cable"
}

probe_https() {
    if ! interface_is_active "$PULSE_CABLE_INTERFACE"; then echo skip > "$WORK/https"; return; fi
    local code
    code=$(/usr/bin/curl -s -o /dev/null --interface "$PULSE_CABLE_INTERFACE" -m 4 -w '%{http_code}' "$PULSE_HTTPS_URL" 2>/dev/null)
    if [[ "$code" == "204" ]]; then echo ok; else echo fail; fi > "$WORK/https"
}

run_probes() {
    local gateway pids=""
    gateway="$(default_gateway)"
    probe_ping gw_cable "$PULSE_CABLE_INTERFACE" "$gateway" & pids="$pids $!"
    probe_ping gw_wifi "$PULSE_WIFI_INTERFACE" "$gateway" & pids="$pids $!"
    probe_ping net_cable "$PULSE_CABLE_INTERFACE" "$PULSE_INTERNET_HOST" & pids="$pids $!"
    probe_ping net_wifi "$PULSE_WIFI_INTERFACE" "$PULSE_INTERNET_HOST" & pids="$pids $!"
    probe_dns & pids="$pids $!"
    probe_https & pids="$pids $!"
    probe_entry & pids="$pids $!"
    probe_ping exit_cable "$PULSE_CABLE_INTERFACE" "$PULSE_EXIT_HOST" & pids="$pids $!"
    # Only the probes: a snapshot running in the background must not hold the
    # heartbeat up.
    # shellcheck disable=SC2086
    wait $pids
}

result_of() { cat "$WORK/$1" 2>/dev/null || echo fail; }

# Names the place from which checks failed together, nearest first: if the
# router itself is silent, everything past it is silent too.
where_from() {
    local down=" $1 "
    has() { [[ "$down" == *" $1 "* ]]; }
    if has gw_cable && has gw_wifi; then echo "роутер не отвечает ни по кабелю, ни по Wi-Fi"
    elif has gw_cable; then echo "нет связи с роутером по кабелю"
    elif has gw_wifi && ! has net_cable; then echo "нет связи с роутером по Wi-Fi"
    elif has net_cable; then
        local both=""
        has net_wifi && both=" (и по Wi-Fi)"
        if [[ "$LOC_ENTRY" == "fail" ]]; then echo "за роутером$both: дом → входной сервер"
        elif [[ "$LOC_EXIT" == "fail" ]]; then echo "за роутером$both: входной → выходной сервер (туннель между серверами)"
        elif [[ "$LOC_EXIT" == "ok" ]]; then echo "за роутером$both: за выходным сервером (его выход в интернет)"
        else echo "за роутером$both: туннель кабеля или дальше"
        fi
    elif has net_wifi; then echo "за роутером по Wi-Fi: туннель Wi-Fi или дальше"
    elif has dns && ! has https; then echo "DNS не отвечает при живой сети"
    elif has https && ! has dns; then echo "HTTPS не проходит при живом ping"
    else echo "DNS и HTTPS не проходят при живом ping"
    fi
}

titles_of() {
    local name out=""
    for name in $1; do out="${out:+$out, }$(check_title "$name")"; done
    echo "$out"
}

# What the router and the path looked like at the moment: both of the Mac's
# policies and tunnels, their handshakes and traffic, the router's last log
# lines, and a traceroute by cable. Written to its own file, so the event log
# stays one line per outage.
take_snapshot() {
    local file=$1 down=$2
    {
        echo "Снимок $(timestamp): $(where_from "$down") ($(titles_of "$down"))"
        echo
        echo "== Mac"
        echo "основной маршрут: $(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')"
        local interface
        for interface in "$PULSE_CABLE_INTERFACE" "$PULSE_WIFI_INTERFACE"; do
            echo "$interface: $(ifconfig "$interface" 2>/dev/null | awk '/status:/ {print $2}')"
        done
        echo
        echo "== Роутер"
        if router_load_config && router_login; then
            router_get /show/system | "$JQ_BIN" -r '"работает \(.uptime) с, процессор \(.cpuload)%"' 2>/dev/null
            local mac policy tunnel port handshake rx1 tx1 rx2 tx2
            for interface in "$PULSE_CABLE_INTERFACE" "$PULSE_WIFI_INTERFACE"; do
                mac=$(ifconfig "$interface" ether 2>/dev/null | awk '/ether/ {print $2; exit}')
                read -r policy tunnel <<<"$(router_policy_tunnel "$mac")"
                port="?"; handshake="?"; rx1=""; rx2=""
                case "$tunnel" in
                    Wireguard*)
                        read -r port handshake <<<"$(router_tunnel_peer "$tunnel")"
                        read -r rx1 tx1 <<<"$(router_interface_bytes "$tunnel")"
                        sleep 2
                        read -r rx2 tx2 <<<"$(router_interface_bytes "$tunnel")"
                        ;;
                esac
                printf '%s: политика %s, туннель %s (активный), порт %s, рукопожатие %s с назад' \
                    "$interface" "$policy" "$tunnel" "$port" "$handshake"
                if [[ -n "$rx1" && -n "$rx2" ]]; then
                    awk -v a="$rx1" -v b="$rx2" -v c="$tx1" -v d="$tx2" \
                        'BEGIN { printf ", к дому %.2f / от дома %.2f Мбит/с", (b - a) * 8 / 2e6, (d - c) * 8 / 2e6 }'
                fi
                echo
            done
            if [[ "$policy" != "-" && "$policy" != "?" ]]; then
                local permitted check
                echo "туннели политики $policy по приоритету:"
                while read -r permitted; do
                    [[ -n "$permitted" ]] || continue
                    check=$(router_ping_check "$permitted")
                    echo "  $permitted${check:+, проверка доступности: $check}$([[ "$permitted" == "$tunnel" ]] && echo " ← сейчас")"
                done <<<"$(router_policy_permitted "$policy")"
            fi
            echo
            echo "== Журнал роутера, последние строки"
            router_log_tail 25
            router_logout
        else
            echo "не читается: нет $ROUTER_CONFIG_FILE, jq или ответа RCI"
        fi
        echo
        echo "== traceroute по кабелю до $PULSE_INTERNET_HOST"
        traceroute -n -i "$PULSE_CABLE_INTERFACE" -m 8 -q 1 -w 1 "$PULSE_INTERNET_HOST" 2>&1
    } > "$file" 2>&1
    chmod 644 "$file"

    # Keep the newest ones only: a flapping evening must not fill the disk.
    ls -1t "$SNAPSHOT_DIR"/*.txt 2>/dev/null | tail -n +$((PULSE_SNAPSHOTS_KEPT + 1)) | while read -r old; do rm -f "$old"; done
}

csv_file() { echo "$LOG_DIR/pulse-$(date +%Y-%m).csv"; }

# One row a minute: how many 5-second checks failed, per path. Single misses
# that never open an outage still show up here.
append_minute() {
    local file name row
    file="$(csv_file)"
    # A file started with other columns is set aside, not appended to: a CSV
    # whose rows disagree with its header misleads every reader.
    if [[ -f "$file" && "$(head -1 "$file")" != "$CSV_HEADER" ]]; then
        mv -f "$file" "${file%.csv}.before-$(date +%Y%m%d%H%M%S).csv"
    fi
    [[ -f "$file" ]] || echo "$CSV_HEADER" > "$file"
    # The row is written at the start of the next minute; it is labelled with the
    # minute it counts (rows before 2026-10-16 14:xx carry the next minute).
    row="$MINUTE_STAMP,$MINUTE_CYCLES"
    for name in $CHECKS $LOCATORS; do row="$row,$(eval echo "\$MISSES_$name")"; done
    echo "$row,$MINUTE_OUTAGE" >> "$file"
    chmod 644 "$file" 2>/dev/null
    MINUTE_CYCLES=0; MINUTE_OUTAGE=0
    MINUTE_STAMP=$(date -u +%Y-%m-%dT%H:%MZ)
    for name in $CHECKS $LOCATORS; do eval "MISSES_$name=0"; done
}

write_status() {
    local temporary="$PULSE_STATUS_FILE.tmp" state where=""
    if [[ $OUTAGE_SINCE -gt 0 ]]; then state="обрыв"; where="$(where_from "$OPEN_DOWN")"; else state="норма"; fi
    cat > "$temporary" <<STATUS
{"updated":$(date +%s),"interval":$PULSE_INTERVAL_SECONDS,"state":"$state","where":"$where","since":$OUTAGE_SINCE,"last_outage":"$LAST_OUTAGE","pid":$$}
STATUS
    mv -f "$temporary" "$PULSE_STATUS_FILE"
    chmod 644 "$PULSE_STATUS_FILE"
}

human_seconds() {
    if [[ $1 -lt 90 ]]; then echo "$1 с"; else echo "$(( $1 / 60 )) мин $(( $1 % 60 )) с"; fi
}

# One cycle: run the probes, count misses, open, change or close an outage.
evaluate() {
    local now name result count down="" seen=""
    now=$(date +%s)
    LOC_ENTRY="$(result_of entry_cable)"; LOC_EXIT="$(result_of exit_cable)"
    for name in $LOCATORS; do
        [[ "$(result_of "$name")" == "fail" ]] && eval "MISSES_$name=\$((MISSES_$name + 1))"
    done
    for name in $CHECKS; do
        result="$(result_of "$name")"
        if [[ "$result" == "fail" ]]; then
            eval "count=\$((FAILS_$name + 1)); FAILS_$name=\$count; MISSES_$name=\$((MISSES_$name + 1))"
            [[ $count -eq 1 ]] && eval "FIRST_FAIL_$name=$now"
            [[ $count -ge $PULSE_FAILS_TO_OPEN ]] && down="${down:+$down }$name"
        else
            eval "FAILS_$name=0"
        fi
    done

    if [[ -n "$down" ]]; then
        MINUTE_OUTAGE=1
        if [[ $OUTAGE_SINCE -gt 0 ]]; then
            OUT_CYCLES=$((OUT_CYCLES + 1))
            [[ "$LOC_ENTRY" == "ok" ]] && OUT_ENTRY_OK=$((OUT_ENTRY_OK + 1))
            [[ "$LOC_EXIT" == "ok" ]] && OUT_EXIT_OK=$((OUT_EXIT_OK + 1))
        fi
        if [[ $OUTAGE_SINCE -eq 0 ]]; then
            # The outage began at the first miss of whatever failed, not when
            # it crossed the threshold.
            OUTAGE_SINCE=$now
            for name in $down; do
                seen=$(eval echo "\$FIRST_FAIL_$name")
                [[ -n "$seen" && $seen -lt $OUTAGE_SINCE ]] && OUTAGE_SINCE=$seen
            done
            OPEN_DOWN="$down"; WORST_DOWN="$down"
            OUT_CYCLES=0; OUT_ENTRY_OK=0; OUT_EXIT_OK=0
            local snapshot="$SNAPSHOT_DIR/$(date +%Y%m%d-%H%M%S).txt"
            log_event "обрыв с $(date -r "$OUTAGE_SINCE" '+%H:%M:%S'): $(where_from "$down") — не отвечает: $(titles_of "$down"); снимок $(basename "$snapshot")"
            take_snapshot "$snapshot" "$down" &
        elif [[ "$down" != "$OPEN_DOWN" ]]; then
            log_event "обрыв продолжается: $(where_from "$down") — не отвечает: $(titles_of "$down")"
            OPEN_DOWN="$down"
            [[ ${#down} -gt ${#WORST_DOWN} ]] && WORST_DOWN="$down"
        fi
    elif [[ $OUTAGE_SINCE -gt 0 ]]; then
        local lasted=$((now - OUTAGE_SINCE))
        LAST_OUTAGE="$(date -r "$OUTAGE_SINCE" '+%d.%m %H:%M:%S') $(human_seconds $lasted) — $(where_from "$WORST_DOWN")"
        local located=""
        [[ $OUT_CYCLES -gt 0 ]] && located="; за обрыв входной сервер отвечал в $OUT_ENTRY_OK из $OUT_CYCLES проверок, выходной — в $OUT_EXIT_OK из $OUT_CYCLES"
        log_event "связь вернулась через $(human_seconds $lasted) ($(where_from "$WORST_DOWN"))$located"
        OUTAGE_SINCE=0; OPEN_DOWN=""; WORST_DOWN=""
    fi
}

# --once runs a single cycle and prints the results: for trying the probes from
# the repo with SIGNAL_STATE_DIR and SIGNAL_LOG_DIR pointed somewhere harmless.
ONCE=false
[[ "${1:-}" == "--once" ]] && ONCE=true

main() {
    mkdir -p "$STATE_DIR" "$LOG_DIR" "$SNAPSHOT_DIR"
    chmod 755 "$STATE_DIR" "$LOG_DIR" "$SNAPSHOT_DIR"
    WORK=$(mktemp -d -t signal-pulse)
    trap 'rm -rf "$WORK"' EXIT

    local name
    for name in $CHECKS; do eval "FAILS_$name=0; MISSES_$name=0; FIRST_FAIL_$name="; done
    for name in $LOCATORS; do eval "MISSES_$name=0"; done
    OUTAGE_SINCE=0; OPEN_DOWN=""; WORST_DOWN=""; LAST_OUTAGE=""
    OUT_CYCLES=0; OUT_ENTRY_OK=0; OUT_EXIT_OK=0; LOC_ENTRY="?"; LOC_EXIT="?"
    MINUTE_CYCLES=0; MINUTE_OUTAGE=0
    MINUTE_STAMP=$(date -u +%Y-%m-%dT%H:%MZ)
    local minute
    minute=$(date +%M)

    if [[ "$ONCE" == true ]]; then
        run_probes
        for name in $CHECKS $LOCATORS; do printf '%-11s %s\n' "$name" "$(result_of "$name")"; done
        return
    fi

    log_event "пульс запущен (pid $$, раз в ${PULSE_INTERVAL_SECONDS} с: роутер и интернет по кабелю и Wi-Fi, DNS, HTTPS; место — по входному и выходному серверу)"
    while true; do
        local cycle_started
        cycle_started=$(date +%s)
        run_probes
        MINUTE_CYCLES=$((MINUTE_CYCLES + 1))
        evaluate
        write_status
        if [[ "$(date +%M)" != "$minute" ]]; then
            append_minute
            minute=$(date +%M)
        fi
        local elapsed=$(( $(date +%s) - cycle_started ))
        [[ $elapsed -lt $PULSE_INTERVAL_SECONDS ]] && sleep $((PULSE_INTERVAL_SECONDS - elapsed))
    done
}

main
