#!/bin/bash
# Signal — Keep this Mac's radio clean, and prove it with numbers.

SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
    SOURCE="$(readlink "$SOURCE")"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"

show_help() {
    cat <<'HELP'
════ Signal ════

Usage: signal <команда> [аргументы]

Состояние:
  status                  Что с радио, сторожем и окном прямо сейчас
  log [n]                 Последние n событий сторожа (по умолчанию 20)

AirDrop:
  airdrop on [5m]         Открыть окно: поднять awdl0 и не гасить заданное время
  airdrop off             Закрыть окно досрочно
  airdrop status          Коротко: состояние интерфейса и окна

Замеры:
  measure [--label текст] [--host ip] [--count n]
                          Замер первого хопа: max, stddev, перцентили, фон
  compare [--window сек]  Замер «до/после»: с поднятым awdl0 и без него
  history [n]             Последние n строк журнала замеров

Установка:
  install                 Поставить сторожа (нужен sudo один раз)
  uninstall               Убрать сторожа и вернуть awdl0 системе
  menu install            Собрать и поставить значок в строке меню
  menu uninstall          Убрать значок

HELP
}

case "${1:-help}" in
    status|st)      "${SCRIPT_DIR}/ops/status.sh" ;;
    airdrop|air|a)  "${SCRIPT_DIR}/ops/airdrop.sh" "${@:2}" ;;
    measure|m)      "${SCRIPT_DIR}/ops/measure.sh" "${@:2}" ;;
    compare|cmp)    "${SCRIPT_DIR}/ops/compare.sh" "${@:2}" ;;
    history|hist)   "${SCRIPT_DIR}/ops/history.sh" "${@:2}" ;;
    log)            "${SCRIPT_DIR}/ops/log.sh" "${@:2}" ;;
    install)        "${SCRIPT_DIR}/install.sh" ;;
    uninstall)      "${SCRIPT_DIR}/install.sh" --uninstall ;;
    menu)           "${SCRIPT_DIR}/../menubar/build.sh" "${@:2}" ;;
    help|-h|--help) show_help ;;
    *)
        echo "Неизвестная команда: $1"
        echo
        show_help
        exit 1
        ;;
esac
