#!/bin/bash
# Signal — Outages the heartbeat caught: when, how long, where (ADR-017).
#
# Reads only what the heartbeat writes; measures nothing itself.
#
# Usage: signal pulse [n]     n — сколько последних минут с промахами показать (по умолчанию 15)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/log.sh"
source "$SCRIPT_DIR/../lib/paths.sh"

LIMIT="${1:-15}"

pulse_state() {
    if ! launchctl print "system/$SIGNAL_PULSE_LABEL" >/dev/null 2>&1; then
        echo "не установлен — signal install"
        return
    fi
    local pid
    pid=$(launchctl print "system/$SIGNAL_PULSE_LABEL" 2>/dev/null | awk '/^\tpid = / {print $3; exit}')
    if [[ -n "$pid" ]]; then echo "работает, pid $pid"; else echo "загружен, но процесса нет"; fi
}

log_header "Пульс"
echo "  демон        $(pulse_state)"

file="$SIGNAL_PULSE_STATUS_FILE"
if [[ -f "$file" ]]; then
    now=$(date +%s)
    age=$((now - $(json_value updated "$file")))
    state=$(json_value state "$file")
    if [[ "$state" == "обрыв" ]]; then
        since=$(json_value since "$file")
        log_warn "Сейчас обрыв с $(date -r "$since" '+%H:%M:%S') ($((now - since)) с): $(json_value where "$file")"
    else
        echo "  сейчас       норма   ($age с назад)"
    fi
    last=$(json_value last_outage "$file")
    [[ -n "$last" ]] && echo "  последний    $last"
    [[ $age -gt 30 ]] && log_warn "Статус устарел на $age с — пульс не пишет."
else
    echo "  сейчас       статуса нет"
fi

if [[ -f "$SIGNAL_PULSE_LOG_FILE" ]]; then
    echo
    log_step "Обрывы"
    tail -12 "$SIGNAL_PULSE_LOG_FILE" | sed 's/^/  /'
    log_dim "        Снимки: $SIGNAL_PULSE_SNAPSHOT_DIR/"
fi

# shellcheck disable=SC2086 — the glob is meant to expand
files=$(ls -1 $SIGNAL_PULSE_CSV_GLOB 2>/dev/null)
if [[ -n "$files" ]]; then
    echo
    log_step "Минуты с промахами (из скольких проверок за минуту не прошло)"
    # Entry and exit only locate, and the entry misses ~40% of probes even when
    # idle — a minute is listed for the six real checks only.
    echo "  когда  проверок  роутер:каб wifi  интернет:каб wifi   DNS  HTTPS  вход выход  обрыв"
    cat $files | grep -v '^timestamp' | awk -F, '$3 + $4 + $5 + $6 + $7 + $8 > 0' | tail -"$LIMIT" | \
        while IFS=',' read -r ts cycles gw_cable gw_wifi net_cable net_wifi dns https entry exit outage; do
            local_time=$(date -j -u -f '%Y-%m-%dT%H:%MZ' "$ts" +%s 2>/dev/null | xargs -I{} date -r {} '+%H:%M')
            printf "  %-6s %8s  %10s %4s  %12s %4s  %4s  %5s  %4s %5s  %s\n" "${local_time:-?}" "$cycles" \
                "$gw_cable" "$gw_wifi" "$net_cable" "$net_wifi" "$dns" "$https" "$entry" "$exit" "$([[ $outage == 1 ]] && echo да)"
        done
fi
