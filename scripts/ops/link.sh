#!/bin/bash
# Signal — What the link watcher sees now, its bad episodes and recent minutes.
#
# Reads only what the watcher writes (ADR-014); measures nothing itself. For a
# deliberate, labelled measurement there is `signal measure`.
#
# Usage: signal link [n]     n — сколько последних минут показать (по умолчанию 15)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/log.sh"
source "$SCRIPT_DIR/../lib/paths.sh"

LIMIT="${1:-15}"

watch_state() {
    if ! launchctl print "system/$SIGNAL_WATCH_LABEL" >/dev/null 2>&1; then
        echo "не установлен — signal install"
        return
    fi
    local pid
    pid=$(launchctl print "system/$SIGNAL_WATCH_LABEL" 2>/dev/null | awk '/^\tpid = / {print $3; exit}')
    if [[ -n "$pid" ]]; then echo "работает, pid $pid"; else echo "загружен, но процесса нет"; fi
}

log_header "Канал Wi-Fi"
echo "  наблюдатель  $(watch_state)"

file="$SIGNAL_LINK_STATUS_FILE"
if [[ -f "$file" ]]; then
    now=$(date +%s)
    updated=$(json_value updated "$file")
    interval=$(json_value interval "$file")
    verdict=$(json_value verdict "$file")
    age=$((now - ${updated:-0}))

    printf "  сейчас       %s — p50 %s мс, p95 %s, max %s, потери %s%%   (%s с назад)\n" \
        "$verdict" "$(json_value p50 "$file")" "$(json_value p95 "$file")" \
        "$(json_value max "$file")" "$(json_value loss "$file")" "$age"
    printf "  радио        канал %s, RSSI %s, BSSID %s, пир %s\n" \
        "$(json_value channel "$file")" "$(json_value rssi "$file")" \
        "$(json_value bssid "$file")" "$(json_value peer "$file")"
    printf "  контекст     awdl0 %s, фон %s Мбит/с, повторы на приёме %s%%\n" \
        "$(json_value awdl "$file")" "$(json_value background "$file")" "$(json_value rx_retry_pct "$file")"

    cause=$(json_value cause "$file")
    hint=$(json_value hint "$file")
    bad_since=$(json_value bad_since "$file")
    if [[ -n "$cause" ]]; then
        echo
        if [[ ${bad_since:-0} -gt 0 ]]; then
            log_warn "Плохо с $(date -r "$bad_since" '+%H:%M') ($(( (now - bad_since) / 60 )) мин): $cause"
        else
            log_warn "$cause"
        fi
        [[ -n "$hint" ]] && log_dim "        → $hint"
    fi
    if [[ $age -gt $(( ${interval:-60} * 3 )) ]]; then
        log_warn "Статус устарел на $age с — наблюдатель не пишет."
    fi
else
    echo "  сейчас       статуса нет"
fi

if [[ -f "$SIGNAL_LINK_LOG_FILE" ]]; then
    echo
    log_step "События: эпизоды и перезапуски"
    tail -8 "$SIGNAL_LINK_LOG_FILE" | sed 's/^/  /'
fi

# shellcheck disable=SC2086 — the glob is meant to expand
files=$(ls -1 $SIGNAL_LINK_CSV_GLOB 2>/dev/null)
if [[ -n "$files" ]]; then
    echo
    log_step "Последние минуты"
    # Written out by hand: bash printf pads by bytes, and Cyrillic is two per letter.
    echo "  когда       p50    p95     max потер awdl0    фон  повт%  вердикт"
    # Samples are stored in UTC like measurements/; shown in local time.
    cat $files | grep -v '^timestamp' | tail -"$LIMIT" | while IFS=',' read -r ts _ _ _ loss _ _ max _ p50 p95 awdl bg _ _ _ _ _ _ _ rx_retry _ _ verdict cause; do
        local_time=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null | xargs -I{} date -r {} '+%H:%M')
        printf "  %-8s %6s %6s %7s %4s%% %-5s %6s %6s  %s%s\n" \
            "${local_time:-?}" "$p50" "$p95" "$max" "$loss" "$awdl" "$bg" "$rx_retry" "$verdict" "${cause:+ — $cause}"
    done
fi
