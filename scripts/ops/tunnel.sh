#!/bin/bash
# Signal — What the tunnel watcher sees now, its events and recent samples.
#
# Reads only what the watcher writes (ADR-016); measures nothing itself.
#
# Usage: signal tunnel [n]     n — сколько последних замеров показать (по умолчанию 12)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/log.sh"
source "$SCRIPT_DIR/../lib/paths.sh"

LIMIT="${1:-12}"

watch_state() {
    if ! launchctl print "system/$SIGNAL_TUNNEL_LABEL" >/dev/null 2>&1; then
        echo "не установлен — signal install"
        return
    fi
    local pid
    pid=$(launchctl print "system/$SIGNAL_TUNNEL_LABEL" 2>/dev/null | awk '/^\tpid = / {print $3; exit}')
    if [[ -n "$pid" ]]; then echo "работает, pid $pid"; else echo "загружен, но процесса нет"; fi
}

log_header "Туннель роутера"
echo "  наблюдатель  $(watch_state)"

file="$SIGNAL_TUNNEL_STATUS_FILE"
if [[ -f "$file" ]]; then
    now=$(date +%s)
    updated=$(json_value updated "$file")
    interval=$(json_value interval "$file")
    age=$((now - ${updated:-0}))

    printf "  сейчас       %s — Cloudflare %s, OVH %s Мбит/с; ping p50 %s, max %s, потери %s%%   (%s мин назад)\n" \
        "$(json_value verdict "$file")" "$(json_value cloudflare "$file")" "$(json_value ovh "$file")" \
        "$(json_value ping_p50 "$file")" "$(json_value ping_max "$file")" "$(json_value ping_loss "$file")" "$((age / 60))"
    printf "  туннель      %s (политика %s), порт %s, рукопожатие %s с назад\n" \
        "$(json_value tunnel "$file")" "$(json_value policy "$file")" \
        "$(json_value port "$file")" "$(json_value handshake "$file")"
    printf "  контекст     роутер работает %s с, процессор %s%%; в туннеле до замера %s Мбит/с, у Mac %s\n" \
        "$(json_value router_uptime "$file")" "$(json_value cpuload "$file")" \
        "$(json_value tunnel_down "$file")" "$(json_value mac_mbit "$file")"
    if [[ $age -gt $(( ${interval:-900} * 2 )) ]]; then
        log_warn "Статус устарел на $((age / 60)) мин — наблюдатель не пишет."
    fi
else
    echo "  сейчас       статуса нет"
fi

if [[ -f "$SIGNAL_TUNNEL_LOG_FILE" ]]; then
    echo
    log_step "События: перезагрузки роутера, смены порта, эпизоды, отметки"
    tail -10 "$SIGNAL_TUNNEL_LOG_FILE" | sed 's/^/  /'
fi

# shellcheck disable=SC2086 — the glob is meant to expand
files=$(ls -1 $SIGNAL_TUNNEL_CSV_GLOB 2>/dev/null)
if [[ -n "$files" ]]; then
    echo
    log_step "Последние замеры"
    # Written out by hand: bash printf pads by bytes, and Cyrillic is two per letter.
    echo "  когда   туннель      порт    cf    ovh   p50   max пот  в туннеле  вердикт"
    cat $files | grep -v '^timestamp' | tail -"$LIMIT" | \
        while IFS=',' read -r ts mark verdict _ _ tunnel port _ _ _ down _ _ loss p50 _ max _ _ _ cf ovh; do
            local_time=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null | xargs -I{} date -r {} '+%H:%M')
            printf "  %-6s %-11s %6s %5s %6s %5s %5s %3s%% %8s   %s%s\n" \
                "${local_time:-?}" "$tunnel" "$port" "$cf" "$ovh" "$p50" "$max" "$loss" "$down" "$verdict" "${mark:+ — $mark}"
        done
fi
