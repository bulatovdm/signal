#!/bin/bash
# Signal — Mark the moment it feels slow; the tunnel watcher measures right away.
#
# Writes "epoch text" into the mark file, which belongs to the user like the
# keeper's request file (ADR-005, ADR-016). No sudo, no direct measurement: the
# watcher is the one that measures, so marked and scheduled samples match.
#
# Usage: signal mark [текст]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/log.sh"
source "$SCRIPT_DIR/../lib/paths.sh"

if [[ ! -w "$SIGNAL_TUNNEL_MARK_FILE" ]]; then
    log_error "Наблюдатель туннеля не установлен или файл отметок не ваш: $SIGNAL_TUNNEL_MARK_FILE"
    exit 1
fi

# The text ends up in a CSV column and a flat JSON value: no commas, quotes or
# line breaks.
text="$(printf '%s' "$*" | tr -d ',"\\' | tr '\n\r' '  ' | cut -c1-80)"
text="${text:-медленно}"

echo "$(date +%s) $text" > "$SIGNAL_TUNNEL_MARK_FILE"
log_ok "Отметка «$text» принята — замер начнётся в ближайшие ~10 с и займёт около минуты."
log_dim "        Результат: signal tunnel"
