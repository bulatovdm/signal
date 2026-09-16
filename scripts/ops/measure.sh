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

# Percentiles come from the individual replies, not from ping's summary line:
# the summary has no distribution, and the distribution is the whole point.
stats="$(awk '
    /time=/ {
        match($0, /time=[0-9.]+/)
        values[n++] = substr($0, RSTART + 5, RLENGTH - 5) + 0
    }
    END {
        if (n == 0) { print "0 0 0 0 0 0 0 0"; exit }
        for (i = 0; i < n - 1; i++)
            for (j = 0; j < n - 1 - i; j++)
                if (values[j] > values[j+1]) { t = values[j]; values[j] = values[j+1]; values[j+1] = t }
        sum = 0
        for (i = 0; i < n; i++) sum += values[i]
        mean = sum / n
        variance = 0
        for (i = 0; i < n; i++) variance += (values[i] - mean) ^ 2
        stddev = (n > 1) ? sqrt(variance / n) : 0
        p50 = values[int(n * 0.50)]; if (p50 == "") p50 = values[n-1]
        p95 = values[int(n * 0.95)]; if (p95 == "") p95 = values[n-1]
        p99 = values[int(n * 0.99)]; if (p99 == "") p99 = values[n-1]
        printf "%.3f %.3f %.3f %.3f %.3f %.3f %.3f %d\n",
            values[0], mean, values[n-1], stddev, p50, p95, p99, n
    }' <<<"$ping_output")"

read -r MIN AVG MAX STDDEV P50 P95 P99 RECEIVED <<<"$stats"

LOSS="$(awk -F'[,%]' '/packet loss/ {gsub(/ /, "", $3); print $3 + 0; exit}' <<<"$ping_output")"
[[ -n "${LOSS:-}" ]] || LOSS=100

duration=$(( finished_at - started_at ))
[[ $duration -gt 0 ]] || duration=1
if [[ -n "${bytes_before:-}" && -n "${bytes_after:-}" && "$bytes_after" -ge "${bytes_before:-0}" ]]; then
    BACKGROUND_MBIT="$(awk -v a="$bytes_before" -v b="$bytes_after" -v s="$duration" \
        'BEGIN { printf "%.2f", (b - a) * 8 / s / 1000000 }')"
else
    BACKGROUND_MBIT="?"
fi

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
