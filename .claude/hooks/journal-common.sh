#!/usr/bin/env bash
# Shared helpers for the session hooks. Paths are derived from this file's own
# location, so the repository can move without breaking the harness (ADR-010).

readonly JOURNAL_TEMPLATE_MARKER='<!-- НЕ ЗАПОЛНЕН -->'

repository_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

journal_directory() {
  echo "$(repository_root)/knowledge/journal"
}

journal_path_for_today() {
  local today existing
  today=$(date +%F)
  existing=$(find "$(journal_directory)" -maxdepth 1 -name "$today-*.md" 2>/dev/null | sort | tail -1)
  if [ -n "$existing" ]; then
    echo "$existing"
  else
    echo "$(journal_directory)/$today-01.md"
  fi
}

journal_is_unfilled() {
  local path=$1
  [ ! -f "$path" ] && return 0
  grep -qF "$JOURNAL_TEMPLATE_MARKER" "$path"
}

inside_git_repository() {
  git -C "$(repository_root)" rev-parse --is-inside-work-tree >/dev/null 2>&1
}
