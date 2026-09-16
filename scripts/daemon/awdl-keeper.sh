#!/bin/bash
# Signal — Keep the AWDL radio off the air unless it is actually carrying a transfer.
#
# Runs as root under launchd (ADR-003). The policy is idle-based, not
# timer-based (ADR-004): an interface that just came up is left alone for a
# grace period, and after that it is shut down only if nothing is flowing
# through it. AirDrop discovery starts over Bluetooth LE, so macOS raises awdl0
# by itself when a nearby device opens the share sheet — the keeper only has to
# stay out of the way long enough for a real transfer to begin.
#
# The only channel from user land is the request file (ADR-005): a unix
# timestamp until which the interface must be left up, or 0 for "close now".
#
# Written for /bin/bash 3.2 — no associative arrays, no mapfile.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_DIR="${SIGNAL_STATE_DIR:-/usr/local/var/run/signal}"
REQUEST_FILE="$STATE_DIR/request"
STATUS_FILE="$STATE_DIR/status"
COUNTER_FILE="$STATE_DIR/counters"
LOG_DIR="${SIGNAL_LOG_DIR:-/usr/local/var/log/signal}"
LOG_FILE="$LOG_DIR/awdl.log"
CONFIG_FILE="${SIGNAL_CONFIG_FILE:-/usr/local/etc/signal/keeper.conf}"

INTERFACE="awdl0"
TICK_SECONDS=2
# How long a freshly raised interface is left alone: long enough for the sender
# to see this Mac in the share sheet and start pushing bytes.
GRACE_SECONDS=45
# How long the interface may stay idle after the last real traffic before it
# goes down again.
IDLE_SECONDS=20
# Bytes between two ticks that count as a real transfer. AWDL discovery chatter
# is hundreds of bytes per tick; an actual AirDrop moves megabytes.
ACTIVE_BYTES=131072
LOG_MAX_BYTES=524288

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log_line() {
    local message="$1"
    mkdir -p "$LOG_DIR"
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        [[ "$size" -gt "$LOG_MAX_BYTES" ]] && mv -f "$LOG_FILE" "${LOG_FILE}.1"
    fi
    echo "$(timestamp) $message" >> "$LOG_FILE"
}

interface_is_up() {
    ifconfig "$INTERFACE" 2>/dev/null | head -1 | grep -q '<UP,'
}

interface_bytes() {
    netstat -ib -I "$INTERFACE" 2>/dev/null | awk -v iface="$INTERFACE" '
        ($1 == iface || $1 == iface"*") && /<Link#/ { print $7 + $10; exit }'
}

bring_down() { ifconfig "$INTERFACE" down 2>/dev/null; }
bring_up()   { ifconfig "$INTERFACE" up 2>/dev/null; }

human_duration() {
    local seconds=$1
    if   [[ $seconds -lt 60 ]];   then echo "${seconds}с"
    elif [[ $seconds -lt 3600 ]]; then echo "$((seconds / 60))м $((seconds % 60))с"
    else echo "$((seconds / 3600))ч $(((seconds % 3600) / 60))м"
    fi
}

human_bytes() {
    awk -v b="$1" 'BEGIN {
        if (b < 1024) { printf "%d Б", b }
        else if (b < 1048576) { printf "%.1f КБ", b / 1024 }
        else { printf "%.1f МБ", b / 1048576 }
    }'
}

# The request file belongs to whoever is at the keyboard: the CLI and the menu
# bar app write it without sudo, and this is the only privilege boundary the
# design has (ADR-005).
ensure_state_files() {
    mkdir -p "$STATE_DIR" "$LOG_DIR"
    chmod 755 "$STATE_DIR"
    if [[ ! -f "$REQUEST_FILE" ]]; then
        echo 0 > "$REQUEST_FILE"
    fi
    local console_user
    console_user=$(stat -f '%Su' /dev/console 2>/dev/null)
    if [[ -n "$console_user" && "$console_user" != "root" ]]; then
        chown "$console_user" "$REQUEST_FILE" 2>/dev/null
    fi
    chmod 644 "$REQUEST_FILE"
}

read_request_until() {
    local value
    value=$(head -1 "$REQUEST_FILE" 2>/dev/null | tr -cd '0-9')
    [[ -n "$value" ]] || value=0
    echo "$value"
}

today_key() { date '+%Y-%m-%d'; }

load_counter() {
    local day count
    if [[ -f "$COUNTER_FILE" ]]; then
        day=$(awk 'NR==1{print $1}' "$COUNTER_FILE")
        count=$(awk 'NR==1{print $2}' "$COUNTER_FILE")
    fi
    if [[ "${day:-}" != "$(today_key)" ]]; then
        echo 0
    else
        echo "${count:-0}"
    fi
}

save_counter() { echo "$(today_key) $1" > "$COUNTER_FILE"; }

write_status() {
    local state=$1 since=$2 window_until=$3 intercepts=$4 last_intercept=$5 transferred=$6 reason=$7
    local temporary="$STATUS_FILE.tmp"
    cat > "$temporary" <<STATUS
{"updated":$(date +%s),"awdl":"$state","since":$since,"window_until":$window_until,"intercepts_today":$intercepts,"last_intercept":$last_intercept,"transferred_bytes":$transferred,"reason":"$reason","grace":$GRACE_SECONDS,"idle":$IDLE_SECONDS,"pid":$$}
STATUS
    mv -f "$temporary" "$STATUS_FILE"
    chmod 644 "$STATUS_FILE"
}

main() {
    ensure_state_files
    log_line "сторож запущен (pid $$, grace ${GRACE_SECONDS}с, простой ${IDLE_SECONDS}с, тик ${TICK_SECONDS}с)"

    local up_since=0 last_active=0 bytes_mark=0 transferred=0
    local window_logged=0 down_since=$(date +%s)
    local intercepts
    intercepts=$(load_counter)

    while true; do
        local now window_until state reason
        now=$(date +%s)
        window_until=$(read_request_until)
        reason=""

        if interface_is_up; then
            local bytes delta
            bytes=$(interface_bytes)
            [[ -n "$bytes" ]] || bytes=$bytes_mark

            if [[ $up_since -eq 0 ]]; then
                up_since=$now
                last_active=$now
                bytes_mark=$bytes
                transferred=0
                log_line "поднялся системой после $(human_duration $((now - down_since))) покоя"
            else
                delta=$((bytes - bytes_mark))
                # A reboot or an interface reset rewinds the counter; treat that
                # as no traffic rather than as a huge negative transfer.
                [[ $delta -lt 0 ]] && delta=0
                if [[ $delta -ge $ACTIVE_BYTES ]]; then
                    last_active=$now
                    transferred=$((transferred + delta))
                fi
                bytes_mark=$bytes
            fi

            if [[ $window_until -gt $now ]]; then
                reason="окно до $(date -r "$window_until" '+%H:%M:%S')"
                if [[ $window_logged -ne $window_until ]]; then
                    log_line "окно открыто пользователем до $(date -r "$window_until" '+%H:%M:%S')"
                    window_logged=$window_until
                fi
            elif [[ $((now - up_since)) -lt $GRACE_SECONDS ]]; then
                reason="grace $((GRACE_SECONDS - (now - up_since)))с"
            elif [[ $((now - last_active)) -lt $IDLE_SECONDS ]]; then
                reason="идёт передача"
            else
                bring_down
                intercepts=$((intercepts + 1))
                save_counter "$intercepts"
                if [[ $transferred -ge $ACTIVE_BYTES ]]; then
                    log_line "погашен после передачи $(human_bytes $transferred), интерфейс жил $(human_duration $((now - up_since)))"
                else
                    log_line "погашен: простоял $(human_duration $((now - up_since))) без трафика (перехват №$intercepts за сегодня)"
                fi
                up_since=0
                down_since=$now
                transferred=0
                reason="погашен"
            fi
        else
            if [[ $up_since -ne 0 ]]; then
                log_line "опустился сам, прожив $(human_duration $((now - up_since)))"
                up_since=0
                down_since=$now
                transferred=0
            fi
            # A window that outlives the interface means the owner asked to be
            # visible: raise it, otherwise nobody can send anything to this Mac.
            if [[ $window_until -gt $now ]]; then
                bring_up
                reason="окно до $(date -r "$window_until" '+%H:%M:%S')"
                if [[ $window_logged -ne $window_until ]]; then
                    log_line "окно открыто пользователем до $(date -r "$window_until" '+%H:%M:%S'), интерфейс поднят"
                    window_logged=$window_until
                fi
            else
                reason="держим погашенным"
            fi
        fi

        if interface_is_up; then state="up"; else state="down"; fi
        local last_intercept=0
        [[ -f "$COUNTER_FILE" ]] && last_intercept=$(stat -f%m "$COUNTER_FILE" 2>/dev/null || echo 0)
        write_status "$state" "$up_since" "$window_until" "$intercepts" "$last_intercept" "$transferred" "$reason"

        sleep "$TICK_SECONDS"
    done
}

main
