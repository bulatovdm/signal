#!/bin/bash
# Signal — What the radio is doing right now and what the keeper has been doing.
#
# Reads the status file the daemon writes; falls back to ifconfig when the
# daemon is not installed, so the command is useful before installation too.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/log.sh"
source "$SCRIPT_DIR/../lib/paths.sh"
source "$SCRIPT_DIR/../lib/awdl.sh"

human_duration() {
    local seconds=$1
    if   [[ $seconds -lt 60 ]];   then echo "${seconds} с"
    elif [[ $seconds -lt 3600 ]]; then echo "$((seconds / 60)) м $((seconds % 60)) с"
    else echo "$((seconds / 3600)) ч $(((seconds % 3600) / 60)) м"
    fi
}

daemon_state() {
    if ! launchctl print "system/$SIGNAL_DAEMON_LABEL" >/dev/null 2>&1; then
        echo "не установлен"
        return
    fi
    local pid
    pid=$(launchctl print "system/$SIGNAL_DAEMON_LABEL" 2>/dev/null | awk '/^\tpid = / {print $3; exit}')
    if [[ -n "$pid" ]]; then echo "работает, pid $pid"; else echo "загружен, но процесса нет"; fi
}

log_header "Signal"

now=$(date +%s)
echo "  сторож       $(daemon_state)"

if [[ -f "$SIGNAL_STATUS_FILE" ]]; then
    state=$(json_value awdl "$SIGNAL_STATUS_FILE")
    since=$(json_value since "$SIGNAL_STATUS_FILE")
    window=$(json_value window_until "$SIGNAL_STATUS_FILE")
    intercepts=$(json_value intercepts_today "$SIGNAL_STATUS_FILE")
    reason=$(json_value reason "$SIGNAL_STATUS_FILE")
    updated=$(json_value updated "$SIGNAL_STATUS_FILE")

    if [[ $((now - ${updated:-0})) -gt 10 ]]; then
        log_warn "Статус устарел на $(human_duration $((now - ${updated:-0}))) — сторож не пишет."
    fi

    if [[ "$state" == "up" ]]; then
        echo "  awdl0        поднят $( [[ ${since:-0} -gt 0 ]] && echo "$(human_duration $((now - since))) назад" ), $reason"
    else
        echo "  awdl0        погашен, $reason"
    fi
    if [[ ${window:-0} -gt $now ]]; then
        echo "  окно         открыто до $(date -r "$window" '+%H:%M:%S'), осталось $((window - now)) с"
    else
        echo "  окно         закрыто"
    fi
    echo "  перехватов   ${intercepts:-0} за сегодня"
else
    echo "  awdl0        $(awdl_state_word)  (сторож не пишет статус)"
fi

echo "  радио        канал $(wifi_channel), RSSI $(wifi_rssi), шум $(wifi_noise), сеть «$(wifi_ssid)»"

if [[ -f "$SIGNAL_LINK_STATUS_FILE" ]]; then
    link_verdict=$(json_value verdict "$SIGNAL_LINK_STATUS_FILE")
    link_cause=$(json_value cause "$SIGNAL_LINK_STATUS_FILE")
    link_age=$((now - $(json_value updated "$SIGNAL_LINK_STATUS_FILE")))
    printf "  канал        %s, p50 %s мс%s%s\n" "$link_verdict" \
        "$(json_value p50 "$SIGNAL_LINK_STATUS_FILE")" "${link_cause:+ — $link_cause}" \
        "$( [[ $link_age -gt 180 ]] && echo " (устарело на $link_age с)" )"
else
    echo "  канал        наблюдатель не пишет — signal install"
fi

if [[ -f "$SIGNAL_LOG_FILE" ]]; then
    echo
    log_step "Последние события"
    tail -5 "$SIGNAL_LOG_FILE" | sed 's/^/  /'
fi

last_csv=$(ls -1 "$REPO_ROOT"/measurements/*.csv 2>/dev/null | tail -1)
if [[ -n "${last_csv:-}" ]]; then
    echo
    log_step "Последний замер"
    tail -1 "$last_csv" | awk -F',' '{
        printf "  %s  max %s мс, stddev %s, потери %s%%, фон %s Мбит/с — %s\n",
               $1, $8, $9, $13, $14, $18
    }'
fi
