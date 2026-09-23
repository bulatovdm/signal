#!/bin/bash
# Signal — Measure the first hop and say what the numbers mean.
#
# Prints max, stddev and percentiles alongside the average, plus the context
# that decides whether two measurements are comparable at all: awdl0 state and
# background traffic on the Wi-Fi interface (ADR-008). Averages alone hid this
# very problem for half a year.
#
# Usage: signal measure [--label <text>] [--host <ip>] [--count <n>]
#                       [--interval <sec>] [--quiet] [--no-log]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/log.sh"
source "$SCRIPT_DIR/../lib/awdl.sh"
source "$SCRIPT_DIR/../lib/stats.sh"

LABEL=""
HOST=""
COUNT=100
INTERVAL=0.1
QUIET=false
WRITE_LOG=true

# Acceptance criteria from the task: idle radio must stay under these.
MAX_LIMIT=10.0
STDDEV_LIMIT=1.5
# Background traffic is judged in three steps rather than one: a busy uplink
# raises RTT evenly and looks nothing like AWDL's spikes, but a trickle changes
# nothing. Below the first number the measurement is clean, between the two it
# is usable for a rough comparison but not as a reference, above the second it
# says nothing at all.
BACKGROUND_CLEAN_MBIT=2.0
BACKGROUND_INVALID_MBIT=10.0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label)    LABEL="${2:-}"; shift 2 ;;
        --host)     HOST="${2:-}"; shift 2 ;;
        --count)    COUNT="${2:-}"; shift 2 ;;
        --interval) INTERVAL="${2:-}"; shift 2 ;;
        --quiet)    QUIET=true; shift ;;
        --no-log)   WRITE_LOG=false; shift ;;
        *) log_error "Неизвестный аргумент: $1"; exit 1 ;;
    esac
done

[[ -n "$HOST" ]] || HOST="$(default_gateway)"

awdl_before="$(awdl_state_word)"
bytes_before="$(interface_bytes "$WIFI_INTERFACE")"
started_at="$(date +%s)"

ping_output="$(ping -c "$COUNT" -i "$INTERVAL" "$HOST" 2>&1)"
ping_status=$?

finished_at="$(date +%s)"
bytes_after="$(interface_bytes "$WIFI_INTERFACE")"
awdl_after="$(awdl_state_word)"

if [[ $ping_status -ne 0 && -z "$(grep -c 'packets transmitted' <<<"$ping_output")" ]]; then
    log_error "ping до $HOST не выполнился:"
    echo "$ping_output" >&2
    exit 1
fi

stats="$(rtt_stats <<<"$ping_output")"

read -r MIN AVG MAX STDDEV P50 P95 P99 RECEIVED <<<"$stats"

LOSS="$(ping_loss_pct <<<"$ping_output")"

duration=$(( finished_at - started_at ))
[[ $duration -gt 0 ]] || duration=1
BACKGROUND_MBIT="$(background_mbit "${bytes_before:-}" "${bytes_after:-}" "$duration")"

CHANNEL="$(wifi_channel)"; RSSI="$(wifi_rssi)"; NOISE="$(wifi_noise)"
# Commas are the column separator, and the channel arrives as "149,80": keep
# every field comma-free so the CSV survives being read with awk -F','.
CHANNEL_CSV="$(tr ',' '/' <<<"$CHANNEL")"
LABEL_CSV="$(tr ',' ';' <<<"$LABEL")"

awdl_state="$awdl_before"
[[ "$awdl_before" == "$awdl_after" ]] || awdl_state="${awdl_before}→${awdl_after}"

passes_limits="$(awk -v max="$MAX" -v sd="$STDDEV" -v loss="$LOSS" \
    -v maxlim="$MAX_LIMIT" -v sdlim="$STDDEV_LIMIT" \
    'BEGIN { print (max < maxlim && sd < sdlim && loss == 0) ? "yes" : "no" }')"
background_grade="$(awk -v bg="$BACKGROUND_MBIT" -v clean="$BACKGROUND_CLEAN_MBIT" \
    -v invalid="$BACKGROUND_INVALID_MBIT" 'BEGIN {
        if (bg == "?") { print "unknown"; exit }
        if (bg + 0 <= clean) { print "clean"; exit }
        if (bg + 0 < invalid) { print "noisy"; exit }
        print "invalid"
    }')"

if [[ "$background_grade" == "invalid" ]]; then
    VERDICT="недействителен"
elif [[ "$passes_limits" == "yes" && "$background_grade" == "clean" ]]; then
    VERDICT="норма"
elif [[ "$passes_limits" == "yes" ]]; then
    VERDICT="норма с фоном"
else
    VERDICT="не проходит"
fi

if [[ "$QUIET" == false ]]; then
    log_header "Замер до $HOST${LABEL:+ — $LABEL}"
    printf "  пакетов     %s из %s, потери %s%%\n" "$RECEIVED" "$COUNT" "$LOSS"
    printf "  min/avg     %s / %s мс\n" "$MIN" "$AVG"
    printf "  ${BOLD}max         %s мс${NC}   (предел %s)\n" "$MAX" "$MAX_LIMIT"
    printf "  ${BOLD}stddev      %s мс${NC}   (предел %s)\n" "$STDDEV" "$STDDEV_LIMIT"
    printf "  p50/p95/p99 %s / %s / %s мс\n" "$P50" "$P95" "$P99"
    echo
    printf "  awdl0       %s\n" "$awdl_state"
    printf "  фон на %-4s %s Мбит/с за %s с\n" "$WIFI_INTERFACE" "$BACKGROUND_MBIT" "$duration"
    printf "  радио       канал %s, RSSI %s, шум %s\n" "$CHANNEL" "$RSSI" "$NOISE"
    echo
    case "$VERDICT" in
        норма)
            log_ok "Норма: max < $MAX_LIMIT, stddev < $STDDEV_LIMIT, потерь нет." ;;
        "норма с фоном")
            log_ok "Пороги пройдены, но фон $BACKGROUND_MBIT Мбит/с — для эталона повторить на тихом канале." ;;
        "не проходит")
            log_warn "Не проходит порог покоя — max $MAX, stddev $STDDEV, потери $LOSS%."
            if [[ "$awdl_state" != "down" ]]; then
                log_dim "        awdl0 поднят: это ожидаемая картина всплесков, а не поломка канала."
            fi
            if [[ "$background_grade" == "noisy" ]]; then
                log_dim "        Фон $BACKGROUND_MBIT Мбит/с — часть задержки может быть его."
            fi ;;
        недействителен)
            log_warn "Недействителен для сравнения: фон $BACKGROUND_MBIT Мбит/с (предел $BACKGROUND_INVALID_MBIT)."
            log_dim "        Занятый аплинк поднимает RTT ровно, AWDL даёт всплески при низком среднем."
            log_dim "        Остановить фоновую закачку и повторить." ;;
    esac
fi

if [[ "$WRITE_LOG" == true ]]; then
    csv="$REPO_ROOT/measurements/$(date +%Y-%m).csv"
    if [[ ! -f "$csv" ]]; then
        mkdir -p "$(dirname "$csv")"
        echo "timestamp,label,host,count,awdl,min,avg,max,stddev,p50,p95,p99,loss_pct,background_mbit,channel,rssi,noise,verdict" > "$csv"
    fi
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LABEL_CSV" "$HOST" "$COUNT" "$awdl_state" \
        "$MIN" "$AVG" "$MAX" "$STDDEV" "$P50" "$P95" "$P99" "$LOSS" \
        "$BACKGROUND_MBIT" "$CHANNEL_CSV" "$RSSI" "$NOISE" "$VERDICT" >> "$csv"
    [[ "$QUIET" == false ]] && log_dim "        записано в measurements/$(basename "$csv")"
fi

[[ "$VERDICT" == "норма" || "$VERDICT" == "норма с фоном" ]]
