#!/bin/bash
# Signal — Recent measurements, as a table rather than raw CSV.
#
# Usage: signal history [n]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/log.sh"

LIMIT="${1:-15}"

files=$(ls -1 "$REPO_ROOT"/measurements/*.csv 2>/dev/null)
if [[ -z "$files" ]]; then
    log_warn "Замеров ещё нет: signal measure"
    exit 0
fi

log_header "Журнал замеров"
printf "  %-17s %-7s %7s %7s %7s %6s %7s  %s\n" "когда" "awdl0" "avg" "max" "stddev" "потер" "фон" "вердикт"
cat $files | grep -v '^timestamp' | tail -"$LIMIT" | awk -F',' '{
    when = $1
    gsub(/T/, " ", when); gsub(/Z/, "", when)
    printf "  %-17s %-7s %7s %7s %7s %5s%% %6s  %s\n",
           substr(when, 6, 14), $5, $7, $8, $9, $13, $14, $18
}'
