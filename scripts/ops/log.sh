#!/bin/bash
# Signal — What the keeper has been doing.
#
# Usage: signal log [n]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/log.sh"
source "$SCRIPT_DIR/../lib/paths.sh"

LIMIT="${1:-20}"

if [[ ! -f "$SIGNAL_LOG_FILE" ]]; then
    log_warn "Журнала сторожа нет: $SIGNAL_LOG_FILE (сторож не установлен?)"
    exit 0
fi

log_header "События сторожа"
tail -"$LIMIT" "$SIGNAL_LOG_FILE" | sed 's/^/  /'

today=$(date '+%Y-%m-%d')
intercepts=$(grep -c "^$today.*перехват" "$SIGNAL_LOG_FILE" 2>/dev/null || echo 0)
echo
log_dim "        Перехватов за сегодня: $intercepts"
