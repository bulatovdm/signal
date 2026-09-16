#!/usr/bin/env bash
# Blocks a commit that leaves no trace in today's journal.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/journal-common.sh"

read_command() {
  jq -r '.tool_input.command // ""' 2>/dev/null
}

# The body of a heredoc is data, not a command: a file that merely mentions
# `git commit` in its text must not be mistaken for a commit.
strip_heredocs() {
  awk '
    inside == 1 { if ($0 == delimiter) { inside = 0 }; next }
    {
      if (match($0, /<<-?[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
        delimiter = substr($0, RSTART, RLENGTH)
        sub(/^<<-?/, "", delimiter)
        gsub(/[\047"]/, "", delimiter)
        inside = 1
      }
      print
    }
  '
}

is_git_commit() {
  local runnable
  runnable=$(strip_heredocs <<<"$1")
  [[ "$runnable" == *"git commit"* ]]
}

journal_untouched_since_last_commit() {
  local journal=$1
  git -C "$(repository_root)" rev-parse HEAD >/dev/null 2>&1 || return 1
  git -C "$(repository_root)" ls-files --error-unmatch "$journal" >/dev/null 2>&1 || return 1
  git -C "$(repository_root)" diff --quiet HEAD -- "$journal"
}

refuse() {
  echo "$1" >&2
  exit 2
}

main() {
  local command journal relative
  command=$(read_command)
  is_git_commit "$command" || exit 0
  inside_git_repository || exit 0

  journal=$(journal_path_for_today)
  relative="${journal#$(repository_root)/}"

  if journal_is_unfilled "$journal"; then
    refuse "Коммит заблокирован: журнал $relative не заполнен. Записать, что сделано и почему, снять маркер НЕ ЗАПОЛНЕН и повторить. Если за изменениями стоит выбор политики, механизма или структуры — сначала ADR в knowledge/decisions.md."
  fi

  if journal_untouched_since_last_commit "$journal"; then
    refuse "Коммит заблокирован: $relative не менялся с прошлого коммита. Каждый коммит сопровождается строкой в журнале."
  fi
}

main
