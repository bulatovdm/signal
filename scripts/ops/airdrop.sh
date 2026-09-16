#!/bin/bash
# Signal — Open or close the AirDrop window by hand.
#
# Writes the request file the daemon reads (ADR-005). No sudo: the file belongs
# to the console user, and asking for a window grants no privilege the user did
# not already have by opening the share sheet.
#
# Usage: signal airdrop [on [duration]] | off | status
#   duration — 5m (default), 30s, 2h; bare number means minutes

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/log.sh"
source "$SCRIPT_DIR/../lib/paths.sh"
source "$SCRIPT_DIR/../lib/awdl.sh"

DEFAULT_WINDOW=5m

parse_duration() {
    local value=$1 number unit
    number="${value%[smh]}"
    unit="${value#$number}"
    [[ "$number" =~ ^[0-9]+$ ]] || return 1
    case "$unit" in
        s)  echo "$number" ;;
        h)  echo $((number * 3600)) ;;
        m|"") echo $((number * 60)) ;;
        *)  return 1 ;;
    esac
}

require_daemon() {
    if [[ ! -f "$SIGNAL_REQUEST_FILE" ]]; then
        log_error "Сторож не установлен: нет $SIGNAL_REQUEST_FILE"
        log_dim "        Поставить: signal install"
        exit 1
    fi
    if [[ ! -w "$SIGNAL_REQUEST_FILE" ]]; then
        log_error "Нет прав на запись в $SIGNAL_REQUEST_FILE (владелец: $(stat -f '%Su' "$SIGNAL_REQUEST_FILE"))"
        exit 1
    fi
}

window_until() {
    head -1 "$SIGNAL_REQUEST_FILE" 2>/dev/null | tr -cd '0-9'
}

show_status() {
    local until now
    until=$(window_until); until=${until:-0}
    now=$(date +%s)
    echo "  awdl0        $(awdl_state_word)"
    if [[ ${until:-0} -gt $now ]]; then
        echo "  окно         открыто до $(date -r "$until" '+%H:%M:%S') (осталось $((until - now)) с)"
    else
        echo "  окно         закрыто"
    fi
}

case "${1:-status}" in
    on)
        require_daemon
        seconds=$(parse_duration "${2:-$DEFAULT_WINDOW}") || { log_error "Не понял длительность: ${2:-}"; exit 1; }
        until=$(( $(date +%s) + seconds ))
        echo "$until" > "$SIGNAL_REQUEST_FILE"
        log_ok "AirDrop открыт до $(date -r "$until" '+%H:%M:%S') — интерфейс поднимется в течение пары секунд."
        ;;
    off)
        require_daemon
        echo 0 > "$SIGNAL_REQUEST_FILE"
        log_ok "Окно закрыто. Сторож погасит интерфейс, как только тот перестанет передавать."
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: signal airdrop [on [5m]] | off | status"
        exit 1
        ;;
esac
