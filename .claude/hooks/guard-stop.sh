#!/usr/bin/env bash
# Does not let a session end with work on disk and an empty journal. Once.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/journal-common.sh"

read_session_id() {
  jq -r '.session_id // "unknown"' 2>/dev/null
}

has_uncommitted_work() {
  local changed
  changed=$(git -C "$(repository_root)" status --porcelain 2>/dev/null | grep -v 'knowledge/journal/' | head -1)
  [ -n "$changed" ]
}

main() {
  local session marker journal
  session=$(read_session_id)
  marker="${TMPDIR:-/tmp}/signal-journal-guard-$session"
  [ -f "$marker" ] && exit 0

  inside_git_repository || exit 0
  journal=$(journal_path_for_today)
  journal_is_unfilled "$journal" || exit 0
  has_uncommitted_work || exit 0

  touch "$marker"
  echo "Сессия не закрыта: на диске есть изменения, а журнал ${journal#$(repository_root)/} пуст. Записать цель, ход, итог и точку входа для следующей сессии; проверить, не осталось ли решений без ADR." >&2
  exit 2
}

main
