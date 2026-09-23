#!/usr/bin/env bash
# Opens the session journal before any work happens, and puts the state of the
# machine — not just of the repository — into context: this project is about a
# running daemon, and a session that starts without knowing whether it is alive
# will guess.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/journal-common.sh"

create_journal_if_missing() {
  local path=$1
  [ -f "$path" ] && return 0
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'TEMPLATE'
# ЗАГОЛОВОК

<!-- НЕ ЗАПОЛНЕН -->
<!-- Удалить строку выше при первой записи. Пока она на месте, харнес считает журнал пустым и блокирует коммит и завершение сессии. -->

**Цель.**

**Состояние на входе.**

## Ход

## Итог

**Точка входа для следующей сессии.**
TEMPLATE
  local name
  name=$(basename "$path" .md)
  sed -i '' "s|^# ЗАГОЛОВОК|# $name|" "$path"
}

print_journal_pointer() {
  local path=$1
  echo "ЖУРНАЛ ЭТОЙ СЕССИИ: ${path#$(repository_root)/}"
  if journal_is_unfilled "$path"; then
    echo "Статус: создан харнесом, ещё не заполнен. Записывать по ходу, а не в конце."
  else
    echo "Статус: уже заполняется (сессия за сегодня продолжается)."
  fi
}

print_previous_journals() {
  local current=$1 previous
  previous=$(find "$(journal_directory)" -maxdepth 1 -name '*.md' 2>/dev/null | grep -v "^$current$" | sort | tail -3)
  [ -z "$previous" ] && return 0
  echo
  echo "ПРЕДЫДУЩИЕ ЖУРНАЛЫ (прочитать перед работой):"
  while read -r file; do
    [ -z "$file" ] && continue
    echo "  ${file#$(repository_root)/}"
  done <<< "$previous"
}

print_decisions_index() {
  local decisions="$(repository_root)/knowledge/decisions.md"
  [ -f "$decisions" ] || return 0
  echo
  echo "ПРИНЯТЫЕ РЕШЕНИЯ (knowledge/decisions.md):"
  grep -E '^## ADR-' "$decisions" | sed 's/^## /  /'
}

# The subject of this project is a live daemon; its actual state is a fact of
# the session, not something to be recalled from the last journal.
print_keeper_state() {
  echo
  echo "СОСТОЯНИЕ МАШИНЫ СЕЙЧАС:"
  if launchctl print system/com.dima.signal.awdl-keeper >/dev/null 2>&1; then
    echo "  сторож: загружен в launchd"
  else
    echo "  сторож: НЕ установлен (signal install)"
  fi
  echo "  awdl0:  $(ifconfig awdl0 2>/dev/null | head -1 | grep -q '<UP,' && echo 'поднят' || echo 'погашен')"
  # The watcher's episodes answer "was it bad while nobody was looking" — the
  # question every complaint starts with (ADR-014).
  local link_status=/usr/local/var/run/signal/link link_log=/usr/local/var/log/signal/link.log
  if [ -f "$link_status" ]; then
    echo "  канал:  $(sed -n 's/.*"verdict":"\([^"]*\)".*"p50":\([0-9.]*\).*/\1, p50 \2 мс/p' "$link_status")"
    if [ -f "$link_log" ] && grep -qv 'наблюдатель запущен' "$link_log"; then
      echo "  последние эпизоды канала:"
      grep -v 'наблюдатель запущен' "$link_log" | tail -3 | sed 's/^/    /'
    fi
  else
    echo "  канал:  наблюдатель не пишет (signal install)"
  fi
  local last_measurement
  last_measurement=$(ls -1 "$(repository_root)"/measurements/*.csv 2>/dev/null | tail -1)
  if [ -n "$last_measurement" ]; then
    echo "  последний замер: $(tail -1 "$last_measurement" | awk -F',' '{printf "max %s мс, stddev %s, фон %s Мбит/с — %s", $8, $9, $14, $18}')"
  fi
}

print_protocol_reminder() {
  cat <<'REMINDER'

ПРОТОКОЛ (проверяется харнесом, не памятью):
  - Выбран инструмент, политика, структура или отвергнут вариант -> ADR в knowledge/decisions.md в том же ответе.
  - Любое число о задержке или скорости -> сначала signal measure, потом утверждение. Замер пишется в measurements/.
  - Каждый значимый шаг -> строка в журнал сразу, а не в конце.
  - Коммит без записи в журнал за сегодня блокируется хуком.
REMINDER
}

main() {
  local journal
  journal=$(journal_path_for_today)
  create_journal_if_missing "$journal"
  print_journal_pointer "$journal"
  print_previous_journals "$journal"
  print_decisions_index
  print_keeper_state
  print_protocol_reminder
}

main
