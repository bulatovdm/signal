#!/bin/bash
# Signal — The before/after measurement, side by side.
#
# Raises awdl0 through the normal window mechanism (no sudo, ADR-005), measures,
# closes the window, waits for the keeper to shut the interface down, measures
# again, and prints both — max and stddev first, because those are the numbers
# that were being hidden by averages (ADR-008).
#
# Usage: signal compare [--window <sec>] [--count <n>]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/log.sh"
source "$SCRIPT_DIR/../lib/paths.sh"
source "$SCRIPT_DIR/../lib/awdl.sh"

WINDOW=120
COUNT=100

while [[ $# -gt 0 ]]; do
    case "$1" in
        --window) WINDOW="${2:-}"; shift 2 ;;
        --count)  COUNT="${2:-}"; shift 2 ;;
        *) log_error "Неизвестный аргумент: $1"; exit 1 ;;
    esac
done

if [[ ! -w "$SIGNAL_REQUEST_FILE" ]]; then
    log_error "Нужен установленный сторож: signal install"
    exit 1
fi

wait_for_state() {
    local wanted=$1 limit=$2 waited=0
    while [[ $waited -lt $limit ]]; do
        [[ "$(awdl_state_word)" == "$wanted" ]] && return 0
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

read_csv_field() {
    tail -1 "$REPO_ROOT/measurements/$(date +%Y-%m).csv" | awk -F',' -v n="$1" '{print $n}'
}

log_header "Замер до/после"

log_step "1/2 — awdl0 поднят (окно ${WINDOW} с)"
"$SCRIPT_DIR/airdrop.sh" on "${WINDOW}s" >/dev/null
if ! wait_for_state up 10; then
    log_error "Интерфейс не поднялся за 10 секунд — сторож не отвечает на запрос."
    "$SCRIPT_DIR/airdrop.sh" off >/dev/null
    exit 1
fi
# Let AWDL settle into its discovery rhythm: the first second after the
# interface comes up is not representative of what it does to the air.
sleep 3
"$SCRIPT_DIR/measure.sh" --label "compare: awdl0 up" --count "$COUNT"
up_max=$(read_csv_field 8); up_stddev=$(read_csv_field 9)
up_p95=$(read_csv_field 11); up_loss=$(read_csv_field 13); up_avg=$(read_csv_field 7)

log_step "2/2 — окно закрыто, ждём, пока сторож погасит"
"$SCRIPT_DIR/airdrop.sh" off >/dev/null
if ! wait_for_state down 90; then
    log_error "Сторож не погасил интерфейс за 90 секунд — смотреть signal log."
    exit 1
fi
sleep 2
"$SCRIPT_DIR/measure.sh" --label "compare: awdl0 down" --count "$COUNT"
down_max=$(read_csv_field 8); down_stddev=$(read_csv_field 9)
down_p95=$(read_csv_field 11); down_loss=$(read_csv_field 13); down_avg=$(read_csv_field 7)

log_header "Итог"
printf "  %-12s %12s %12s\n" "" "awdl0 up" "awdl0 down"
printf "  %-12s %12s %12s\n" "avg, мс"    "$up_avg"    "$down_avg"
printf "  ${BOLD}%-12s %12s %12s${NC}\n" "max, мс"    "$up_max"    "$down_max"
printf "  ${BOLD}%-12s %12s %12s${NC}\n" "stddev, мс" "$up_stddev" "$down_stddev"
printf "  %-12s %12s %12s\n" "p95, мс"    "$up_p95"    "$down_p95"
printf "  %-12s %12s %12s\n" "потери, %%"  "$up_loss"   "$down_loss"
echo
awk -v um="$up_max" -v dm="$down_max" -v us="$up_stddev" -v ds="$down_stddev" 'BEGIN {
    if (dm > 0 && ds > 0)
        printf "  Гашение снижает max в %.1f раза, stddev в %.1f раза.\n", um / dm, us / ds
}'
log_dim "        Обе строки записаны в measurements/$(date +%Y-%m).csv"
