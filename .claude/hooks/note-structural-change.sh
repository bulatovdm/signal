#!/usr/bin/env bash
# Two reminders, both about things this project has already got wrong once:
# a policy change that leaves no ADR, and a number written without a measurement.

set -uo pipefail

read_file_path() {
  jq -r '.tool_response.filePath // .tool_input.file_path // ""' 2>/dev/null
}

emit() {
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}' "$1"
}

main() {
  local path
  path=$(read_file_path)
  [ -z "$path" ] && exit 0

  case "$path" in
    */scripts/daemon/*|*/keeper.conf|*/scripts/lib/paths.sh|*.plist|*/menubar/main.swift)
      emit "Изменено поведение сторожа или контракт файлов состояния. Если за правкой стоит выбор (политика гашения, grace, порог трафика, способ управления) — ADR в knowledge/decisions.md в этом же ответе. Изменение контракта request/status задевает и меню на Swift."
      exit 0 ;;
    */knowledge/*.md|*/docs/*.md|*/README.md)
      emit "Правка документа проекта. Любое число о задержке, потерях или скорости должно приходить из signal measure и иметь строку в measurements/ — утверждение без замера здесь не имеет силы (ADR-008)."
      exit 0 ;;
  esac
  exit 0
}

main
