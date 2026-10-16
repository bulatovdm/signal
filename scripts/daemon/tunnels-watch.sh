#!/bin/bash
# Signal — Every tunnel of the router, seen by the router itself, every 10 s (ADR-018).
#
# The pulse and the tunnel watcher measure the one tunnel the Mac sits in. This
# one asks the router to ping through each tunnel by name — its entry node and
# its exit — so a week of data exists for every tunnel whatever policy the Mac
# is in. Nothing on the router changes: no policy, no ping-check profile.
#
# One probe is "a reply within ~200 ms": RCI hands back the output of "tools
# ping" after about 0.25 s without waiting (ADR-018). Every row therefore also
# carries the tunnel's traffic, which tells a queue under a download from a
# path that has gone silent.
#
# Written for /bin/bash 3.2 — indexed arrays only, no mapfile, BSD date/sed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/lib" ]]; then LIB_DIR="$SCRIPT_DIR/lib"; else LIB_DIR="$SCRIPT_DIR/../lib"; fi
source "$LIB_DIR/router.sh"

STATE_DIR="${SIGNAL_STATE_DIR:-/usr/local/var/run/signal}"
STATUS_FILE="$STATE_DIR/tunnels"
LOG_DIR="${SIGNAL_LOG_DIR:-/usr/local/var/log/signal}"
EVENTS_FILE="$LOG_DIR/tunnels.log"
CONFIG_FILE="${SIGNAL_CONFIG_FILE:-/usr/local/etc/signal/keeper.conf}"

TUNNELS_INTERVAL_SECONDS=10
# interface:label:entry:exit — the entry node's and the exit node's addresses
# inside each tunnel (veil ADR-037, ADR-038).
TUNNELS_SPEC="Wireguard1:VDSina:10.60.0.1:10.30.0.1 Wireguard2:TimeWeb:10.60.0.1:10.30.0.1 Wireguard3:запасной:10.61.0.1:10.30.0.1"
TUNNELS_POLICIES="Policy2 Policy3"
TUNNELS_WATCHDOG_INTERFACE=Wireguard1
# Three silent probes in a row (~30 s) open an episode: a person notices that,
# and a single lost probe is noise.
TUNNELS_SILENT_PROBES=3
# Above this towards home, a silent exit is more likely a queue than a cut.
TUNNELS_LOAD_MBIT=20
LOG_MAX_BYTES=524288

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

IFACES=(); LABELS=(); ENTRIES=(); EXITS=()
for item in $TUNNELS_SPEC; do
    IFS=: read -r iface label entry exit_host <<<"$item"
    IFACES+=("$iface"); LABELS+=("$label"); ENTRIES+=("$entry"); EXITS+=("$exit_host")
done
COUNT=${#IFACES[@]}

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

human_seconds() {
    if [[ $1 -lt 90 ]]; then echo "$1 с"; else echo "$(( $1 / 60 )) мин $(( $1 % 60 )) с"; fi
}

csv_header() {
    local i row="timestamp,epoch"
    for ((i = 0; i < COUNT; i++)); do row="$row,${IFACES[$i]}_in,${IFACES[$i]}_out"; done
    for ((i = 0; i < COUNT; i++)); do row="$row,${IFACES[$i]}_down,${IFACES[$i]}_up"; done
    local policy
    for policy in $TUNNELS_POLICIES; do row="$row,$policy"; done
    echo "$row,${TUNNELS_WATCHDOG_INTERFACE}_check"
}

csv_file() { echo "$LOG_DIR/tunnels-$(date +%Y-%m).csv"; }

append_row() {
    local file header
    file="$(csv_file)"; header="$(csv_header)"
    # A file started with other columns is set aside, not appended to.
    if [[ -f "$file" && "$(head -1 "$file")" != "$header" ]]; then
        mv -f "$file" "${file%.csv}.before-$(date +%Y%m%d%H%M%S).csv"
    fi
    [[ -f "$file" ]] || echo "$header" > "$file"
    echo "$1" >> "$file"
    chmod 644 "$file" 2>/dev/null
}

mbit() {
    local before=$1 after=$2 seconds=$3
    if [[ -n "$before" && -n "$after" && "$before" != "?" && "$after" != "?" && "$after" -ge "$before" && $seconds -gt 0 ]]; then
        awk -v a="$before" -v b="$after" -v s="$seconds" 'BEGIN { printf "%.1f", (b - a) * 8 / s / 1000000 }'
    else
        echo "?"
    fi
}

ensure_session() {
    [[ -n "$ROUTER_JAR" ]] && router_get /show/system >/dev/null 2>&1 && return 0
    router_load_config && router_login
}

# One cycle. Sets ROW and the per-tunnel IN_i, OUT_i, DOWN_i, ACTIVE_<policy>.
sample() {
    local now i iface rx tx seconds row downs="" policies="" policy active check="?"
    now=$(date +%s)
    row="$(date -u +%Y-%m-%dT%H:%M:%SZ),$now"
    if ! ensure_session; then
        for ((i = 0; i < COUNT; i++)); do eval "IN_$i='?'; OUT_$i='?'; DOWN_$i='?'"; row="$row,?,?"; downs="$downs,?,?"; done
        for policy in $TUNNELS_POLICIES; do policies="$policies,?"; eval "ACTIVE_$policy='?'"; done
        ROW="$row$downs$policies,?"
        router_logout
        return
    fi

    for ((i = 0; i < COUNT; i++)); do
        local in_rtt out_rtt
        in_rtt=$(router_ping_via "${IFACES[$i]}" "${ENTRIES[$i]}")
        out_rtt=$(router_ping_via "${IFACES[$i]}" "${EXITS[$i]}")
        eval "IN_$i='$in_rtt'; OUT_$i='$out_rtt'"
        row="$row,$in_rtt,$out_rtt"

        read -r rx tx <<<"$(router_interface_bytes "${IFACES[$i]}")"
        seconds=$(( now - ${LAST_AT:-$now} ))
        local down up
        down=$(mbit "$(eval echo "\${LAST_RX_$i:-}")" "${rx:-}" "$seconds")
        up=$(mbit "$(eval echo "\${LAST_TX_$i:-}")" "${tx:-}" "$seconds")
        eval "LAST_RX_$i='${rx:-}'; LAST_TX_$i='${tx:-}'; DOWN_$i='$down'"
        downs="$downs,$down,$up"
    done
    LAST_AT=$now

    for policy in $TUNNELS_POLICIES; do
        active=$(router_policy_active "$policy"); active="${active:-?}"
        eval "ACTIVE_$policy='$active'"
        policies="$policies,$active"
    done
    check=$(router_ping_check "$TUNNELS_WATCHDOG_INTERFACE"); check="${check:-?}"
    ROW="$row$downs$policies,$check"
}

# Episodes: a tunnel whose entry or exit stays silent for TUNNELS_SILENT_PROBES
# probes in a row. Silence is "-" only; "?" (request failed) neither opens nor
# closes anything.
track_episodes() {
    local now i in_rtt out_rtt in_miss out_miss since down segment
    now=$(date +%s)
    for ((i = 0; i < COUNT; i++)); do
        in_rtt=$(eval echo "\$IN_$i"); out_rtt=$(eval echo "\$OUT_$i"); down=$(eval echo "\$DOWN_$i")
        [[ "$in_rtt" == "?" || "$out_rtt" == "?" ]] && continue
        in_miss=$(eval echo "\${IN_MISS_$i:-0}"); out_miss=$(eval echo "\${OUT_MISS_$i:-0}")
        if [[ "$in_rtt" == "-" ]]; then in_miss=$((in_miss + 1)); [[ $in_miss -eq 1 ]] && eval "FIRST_MISS_$i=$now"; else in_miss=0; fi
        if [[ "$out_rtt" == "-" ]]; then out_miss=$((out_miss + 1)); [[ $out_miss -eq 1 && $in_miss -eq 0 ]] && eval "FIRST_MISS_$i=$now"; else out_miss=0; fi
        eval "IN_MISS_$i=$in_miss; OUT_MISS_$i=$out_miss"

        since=$(eval echo "\${EPISODE_SINCE_$i:-0}")
        if [[ $in_miss -ge $TUNNELS_SILENT_PROBES || $out_miss -ge $TUNNELS_SILENT_PROBES ]]; then
            if [[ $in_miss -ge $TUNNELS_SILENT_PROBES ]]; then segment="вход → дом"; else segment="вход → выход"; fi
            if [[ $since -eq 0 ]]; then
                since=$(eval echo "\${FIRST_MISS_$i:-$now}")
                eval "EPISODE_SINCE_$i=$since; EPISODE_SEGMENT_$i='$segment'"
                local load=""
                awk -v d="$down" -v l="$TUNNELS_LOAD_MBIT" 'BEGIN { exit !(d != "?" && d + 0 >= l) }' \
                    && load="; к дому $down Мбит/с — похоже на очередь под нагрузкой"
                log_event "${LABELS[$i]} (${IFACES[$i]}): нет ответа с $(date -r "$since" '+%H:%M:%S'), участок $segment$load"
            elif [[ "$segment" == "вход → дом" && "$(eval echo "\$EPISODE_SEGMENT_$i")" != "$segment" ]]; then
                eval "EPISODE_SEGMENT_$i='$segment'"
                log_event "${LABELS[$i]} (${IFACES[$i]}): теперь молчит и вход — участок вход → дом"
            fi
        elif [[ $since -gt 0 && "$in_rtt" != "-" && "$out_rtt" != "-" ]]; then
            log_event "${LABELS[$i]} (${IFACES[$i]}): ответ вернулся через $(human_seconds $((now - since))) (участок $(eval echo "\$EPISODE_SEGMENT_$i"))"
            eval "EPISODE_SINCE_$i=0"
        fi
    done
}

# The watchdog's moves, seen as a change of the policy's active tunnel.
track_policies() {
    local now policy active last since
    now=$(date +%s)
    for policy in $TUNNELS_POLICIES; do
        active=$(eval echo "\$ACTIVE_$policy"); last=$(eval echo "\${LAST_ACTIVE_$policy:-}")
        [[ "$active" == "?" ]] && continue
        if [[ -n "$last" && "$active" != "$last" ]]; then
            since=$(eval echo "\${MOVED_AT_$policy:-0}")
            if [[ $since -gt 0 ]]; then
                log_event "$policy: вернулась на $active через $(human_seconds $((now - since))) (была на $last)"
                eval "MOVED_AT_$policy=0"
            else
                log_event "$policy: ушла с $last на $active"
                eval "MOVED_AT_$policy=$now"
            fi
        fi
        eval "LAST_ACTIVE_$policy='$active'"
    done
}

write_status() {
    local temporary="$STATUS_FILE.tmp" i json policy
    json="{\"updated\":$(date +%s),\"interval\":$TUNNELS_INTERVAL_SECONDS"
    for ((i = 0; i < COUNT; i++)); do
        json="$json,\"${IFACES[$i]}_label\":\"${LABELS[$i]}\",\"${IFACES[$i]}_in\":\"$(eval echo "\$IN_$i")\",\"${IFACES[$i]}_out\":\"$(eval echo "\$OUT_$i")\",\"${IFACES[$i]}_down\":\"$(eval echo "\$DOWN_$i")\",\"${IFACES[$i]}_silent_since\":$(eval echo "\${EPISODE_SINCE_$i:-0}")"
    done
    for policy in $TUNNELS_POLICIES; do json="$json,\"$policy\":\"$(eval echo "\$ACTIVE_$policy")\""; done
    echo "$json,\"pid\":$$}" > "$temporary"
    mv -f "$temporary" "$STATUS_FILE"
    chmod 644 "$STATUS_FILE"
}

# --once takes a single sample and prints the row: for trying from the repo with
# SIGNAL_STATE_DIR, SIGNAL_LOG_DIR and SIGNAL_ROUTER_CONFIG pointed elsewhere.
ONCE=false
[[ "${1:-}" == "--once" ]] && ONCE=true

main() {
    mkdir -p "$STATE_DIR" "$LOG_DIR"
    chmod 755 "$STATE_DIR" "$LOG_DIR"
    if [[ "$ONCE" == true ]]; then
        sample; csv_header; echo "$ROW"; router_logout; return
    fi
    local note="роутер читается"
    router_load_config || note="роутер не читается: нет $ROUTER_CONFIG_FILE или jq"
    log_event "наблюдатель туннелей роутера запущен (pid $$, раз в ${TUNNELS_INTERVAL_SECONDS} с: $TUNNELS_SPEC; $note)"
    trap 'router_logout' EXIT
    while true; do
        local cycle_started
        cycle_started=$(date +%s)
        sample
        append_row "$ROW"
        track_episodes
        track_policies
        write_status
        local elapsed=$(( $(date +%s) - cycle_started ))
        [[ $elapsed -lt $TUNNELS_INTERVAL_SECONDS ]] && sleep $((TUNNELS_INTERVAL_SECONDS - elapsed))
    done
}

main
