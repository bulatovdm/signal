#!/bin/bash
# Signal — Every tunnel of the router as the router sees it: now, events, report (ADR-018).
#
# Reads only what the tunnels watcher writes; measures nothing itself.
#
# Usage: signal tunnels              состояние сейчас и последние события
#        signal tunnels report [дн]  отчёт за n дней (по умолчанию 7)
#        signal tunnels day [дн]     сводка по суткам, строка на день (по умолчанию 7)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/log.sh"
source "$SCRIPT_DIR/../lib/paths.sh"

# Must match the watcher's default; a keeper.conf override is read the same way.
TUNNELS_LOAD_MBIT=20
TUNNELS_INTERVAL_SECONDS=10
[[ -r /usr/local/etc/signal/keeper.conf ]] && source /usr/local/etc/signal/keeper.conf

MODE="${1:-now}"
DAYS="${2:-7}"

watch_state() {
    if ! launchctl print "system/$SIGNAL_TUNNELS_LABEL" >/dev/null 2>&1; then echo "не установлен — signal install"; return; fi
    local pid
    pid=$(launchctl print "system/$SIGNAL_TUNNELS_LABEL" 2>/dev/null | awk '/^\tpid = / {print $3; exit}')
    if [[ -n "$pid" ]]; then echo "работает, pid $pid"; else echo "загружен, но процесса нет"; fi
}

# Rows of the last n days from all monthly files, header first.
rows_since() {
    local since files
    since=$(( $(date +%s) - $1 * 86400 ))
    # shellcheck disable=SC2086 — the glob is meant to expand
    files=$(ls -1 $SIGNAL_TUNNELS_CSV_GLOB 2>/dev/null | grep -v before)
    [[ -n "$files" ]] || return 1
    head -1 $(echo "$files" | tail -1)
    cat $files | grep -v '^timestamp' | awk -F, -v s="$since" '$2 >= s'
}

# p50 and p95 of a column of numbers on stdin; "—" when empty.
percentiles() {
    sort -n | awk '{ v[n++] = $1 } END {
        if (n == 0) { print "— —"; exit }
        printf "%.0f %.0f\n", v[int(n * 0.50)], v[int(n * 0.95) < n ? int(n * 0.95) : n - 1]
    }'
}

column_of() { head -1 "$1" | tr ',' '\n' | grep -n "^$2\$" | cut -d: -f1; }

show_now() {
    log_header "Туннели роутера"
    echo "  наблюдатель  $(watch_state)"
    local file="$SIGNAL_TUNNELS_STATUS_FILE"
    if [[ -f "$file" ]]; then
        local age iface label
        age=$(( $(date +%s) - $(json_value updated "$file") ))
        echo "  обновлено    $age с назад; Policy2 через $(json_value Policy2 "$file"), Policy3 через $(json_value Policy3 "$file")"
        echo
        echo "  туннель                вход, мс   выход, мс   к дому, Мбит/с"
        for iface in Wireguard1 Wireguard2 Wireguard3; do
            label=$(json_value "${iface}_label" "$file")
            printf "  %-22s %8s   %9s   %8s\n" "$label ($iface)" "$(json_value "${iface}_in" "$file")" \
                "$(json_value "${iface}_out" "$file")" "$(json_value "${iface}_down" "$file")"
        done
        log_dim "        «-» — нет ответа за ~200 мс (потеря или ответ медленнее), «?» — запрос к роутеру не прошёл"
        [[ $age -gt 60 ]] && log_warn "Статус устарел на $age с — наблюдатель не пишет."
    fi
    if [[ -f "$SIGNAL_TUNNELS_LOG_FILE" ]]; then
        echo
        log_step "События: молчание туннелей и уходы сторожа"
        tail -12 "$SIGNAL_TUNNELS_LOG_FILE" | sed 's/^/  /'
    fi
}

show_report() {
    local tmp
    tmp=$(mktemp -t signal-tunnels)
    trap 'rm -f "$tmp" "$tmp".*' RETURN
    rows_since "$DAYS" > "$tmp" || { log_warn "Данных нет: $SIGNAL_TUNNELS_CSV_GLOB"; return; }
    local rows
    rows=$(( $(wc -l < "$tmp") - 1 ))
    [[ $rows -gt 0 ]] || { log_warn "За $DAYS дн. строк нет."; return; }

    log_header "Туннели роутера за $DAYS дн."
    local first last hours
    first=$(sed -n 2p "$tmp" | cut -d, -f2); last=$(tail -1 "$tmp" | cut -d, -f2)
    hours=$(awk -v n="$rows" -v i="$TUNNELS_INTERVAL_SECONDS" 'BEGIN { printf "%.1f", n * i / 3600 }')
    echo "  данные с $(date -r "$first" '+%d.%m %H:%M') по $(date -r "$last" '+%d.%m %H:%M'): $rows проб, ~$hours ч покрытия (пишется, пока Mac включён)"
    echo "  под нагрузкой — когда к дому по туннелю ≥ $TUNNELS_LOAD_MBIT Мбит/с"
    echo

    local iface label in_col out_col down_col
    for iface in Wireguard1 Wireguard2 Wireguard3; do
        in_col=$(column_of "$tmp" "${iface}_in"); out_col=$(column_of "$tmp" "${iface}_out"); down_col=$(column_of "$tmp" "${iface}_down")
        [[ -n "$in_col" ]] || continue
        case "$iface" in
            Wireguard1) label="VDSina" ;;
            Wireguard2) label="TimeWeb" ;;
            Wireguard3) label="запасной вход → выход VDSina" ;;
        esac
        # Availability counts only probes that reached the router ("?" excluded).
        awk -F, -v a="$in_col" -v b="$out_col" -v d="$down_col" -v l="$TUNNELS_LOAD_MBIT" -v name="$label ($iface)" 'NR > 1 && $a != "?" && $b != "?" {
            n++; load = ($d != "?" && $d + 0 >= l)
            if (load) nl++
            if ($a != "-") ia++; if ($b != "-") oa++
            if ($a != "-" && $b != "-") both++
            if (load) { if ($b == "-") lo++ } else { if ($b == "-") qo++; if ($a == "-") qi++ }
        } END {
            if (n == 0) { printf "▸ %s: проб нет\n", name; exit }
            printf "▸ %s\n", name
            printf "  доступность (ответили и вход, и выход)  %.2f%%\n", both * 100 / n
            printf "  ответы входа %.2f%%, выхода %.2f%%\n", ia * 100 / n, oa * 100 / n
            printf "  без ответа от выхода: в покое %.2f%% из %d, под нагрузкой %.2f%% из %d\n", (n - nl) ? qo * 100 / (n - nl) : 0, n - nl, nl ? lo * 100 / nl : 0, nl
        }' "$tmp"
        local p
        for p in "in:вход" "out:выход"; do
            local col="${p%%:*}" what="${p#*:}" colno
            [[ "$col" == "in" ]] && colno=$in_col || colno=$out_col
            local quiet loaded
            quiet=$(awk -F, -v c="$colno" -v d="$down_col" -v l="$TUNNELS_LOAD_MBIT" 'NR > 1 && $c != "-" && $c != "?" && !($d != "?" && $d + 0 >= l) {print $c}' "$tmp" | percentiles)
            loaded=$(awk -F, -v c="$colno" -v d="$down_col" -v l="$TUNNELS_LOAD_MBIT" 'NR > 1 && $c != "-" && $c != "?" && ($d != "?" && $d + 0 >= l) {print $c}' "$tmp" | percentiles)
            printf "  RTT до %-6s p50/p95: в покое %s/%s мс, под нагрузкой %s/%s мс\n" "$what" ${quiet% *} ${quiet#* } ${loaded% *} ${loaded#* }
        done
        # Episodes from the event log, inside the window.
        if [[ -f "$SIGNAL_TUNNELS_LOG_FILE" ]]; then
            awk -v since="$(date -r "$first" '+%Y-%m-%d %H:%M:%S')" -v tag="($iface):" '
                ($1 " " $2) >= since && index($0, tag) && /ответ вернулся через/ {
                    n++; s = seconds_after_cherez($0)
                    total += s; if (s > longest) longest = s
                    if (index($0, "вход → дом")) home++; else leg++
                }

                # "… через 1 мин 5 с …" or "… через 45 с …". BSD awk counts bytes
                # and a Cyrillic letter is two, so the text is cut by words, not offsets.
                function seconds_after_cherez(line,   rest, t) {
                    rest = line; sub(/.*через /, "", rest); split(rest, t, " ")
                    return (t[2] == "мин") ? t[1] * 60 + t[3] : t[1] + 0
                }
                END { printf "  молчание ≥ 30 с: %d раз, всего %d с, самое долгое %d с (вход → дом %d, вход → выход %d)\n", n, total, longest, home, leg }
            ' "$SIGNAL_TUNNELS_LOG_FILE"
        fi
        echo
    done

    if [[ -f "$SIGNAL_TUNNELS_LOG_FILE" ]]; then
        awk -v since="$(date -r "$first" '+%Y-%m-%d %H:%M:%S')" '
            ($1 " " $2) >= since && /Policy2: ушла/ { gone++ }
            ($1 " " $2) >= since && /Policy2: вернулась/ {
                back++; away += seconds_after_cherez($0)
            }

                # "… через 1 мин 5 с …" or "… через 45 с …". BSD awk counts bytes
                # and a Cyrillic letter is two, so the text is cut by words, not offsets.
                function seconds_after_cherez(line,   rest, t) {
                    rest = line; sub(/.*через /, "", rest); split(rest, t, " ")
                    return (t[2] == "мин") ? t[1] * 60 + t[3] : t[1] + 0
                }
            END { printf "▸ Сторож (Policy2): уходил на запасной вход %d раз, вернулся %d раз, всего на запасном %d с\n", gone, back, away }
        ' "$SIGNAL_TUNNELS_LOG_FILE"
    fi
    echo
    log_dim "  Со стороны серверов: path-watch на входах (veil ADR-035), сводка за сутки — veil-path-watch.sh summary на ноде."
    log_dim "  RTT выше ~200 мс не виден: такие ответы считаются «без ответа» (ADR-018)."
}

show_days() {
    local tmp
    tmp=$(mktemp -t signal-tunnels)
    trap 'rm -f "$tmp"' RETURN
    rows_since "$DAYS" > "$tmp" || { log_warn "Данных нет."; return; }
    log_header "Туннели роутера по суткам"
    local offset cols=""
    # Days are the Mac's local days: epoch shifted by the current UTC offset.
    offset=$(date +%z | awk '{ s = (substr($0, 1, 1) == "-") ? -1 : 1; print s * (substr($0, 2, 2) * 3600 + substr($0, 4, 2) * 60) }')
    for iface in Wireguard1 Wireguard2 Wireguard3; do cols="$cols $(column_of "$tmp" "${iface}_in"):$(column_of "$tmp" "${iface}_out")"; done
    awk -F, -v off="$offset" -v cols="$cols" -v names="VDSina TimeWeb запасной" 'NR > 1 {
        day = int(($2 + off) / 86400); days[day] = 1; rows[day]++
        split(cols, c, " "); split(names, nm, " ")
        for (k = 1; k <= 3; k++) {
            split(c[k], ab, ":"); a = ab[1]; b = ab[2]
            if ($a == "?" || $b == "?") continue
            n[day, k]++; if ($a != "-" && $b != "-") ok[day, k]++
        }
    } END {
        for (d in days) list[++m] = d
        for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (list[j] < list[i]) { t = list[i]; list[i] = list[j]; list[j] = t }
        for (i = 1; i <= m; i++) {
            d = list[i]; line = sprintf("  %s  %4.1f ч", strftime_fallback(d), rows[d] * 10 / 3600)
            for (k = 1; k <= 3; k++) line = line sprintf("  %s %s", nm[k], n[d, k] ? sprintf("%.2f%%", ok[d, k] * 100 / n[d, k]) : "—")
            print line
        }
    }
    function strftime_fallback(day,   z, era, doe, yoe, y, doy, mp, dd, mm) {
        # Civil date from days since 1970-01-01 (no strftime in BSD awk).
        z = day + 719468; era = int(z / 146097); doe = z - era * 146097
        yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
        y = yoe + era * 400; doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
        mp = int((5 * doy + 2) / 153); dd = doy - int((153 * mp + 2) / 5) + 1
        mm = mp < 10 ? mp + 3 : mp - 9; if (mm <= 2) y++
        return sprintf("%02d.%02d.%04d", dd, mm, y)
    }' "$tmp"
    log_dim "  доля проб за сутки, на которые ответили и вход, и выход туннеля"
}

case "$MODE" in
    now)    show_now ;;
    report) show_report ;;
    day|days) show_days ;;
    *) log_error "Неизвестный режим: $MODE (now | report [дней] | day [дней])"; exit 1 ;;
esac
