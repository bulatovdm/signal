#!/bin/bash
# Signal — Logging utilities.
#
# Colors are disabled when stdout is not a terminal, so CSV pipelines and
# launchd logs stay clean.

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    BLUE='\033[0;34m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; DIM=''; BOLD=''; NC=''
fi

log_info()   { echo -e "${BLUE}[info]${NC}  $*"; }
log_ok()     { echo -e "${GREEN}[ok]${NC}    $*"; }
log_warn()   { echo -e "${YELLOW}[warn]${NC}  $*"; }
log_error()  { echo -e "${RED}[error]${NC} $*" >&2; }
log_step()   { echo -e "${BOLD}▸ $*${NC}"; }
log_dim()    { echo -e "${DIM}$*${NC}"; }
log_header() { echo -e "\n${BOLD}════ $* ════${NC}\n"; }

confirm() {
    local prompt="${1:-Продолжить?}"
    read -p "$(echo -e "${YELLOW}${prompt} [y/N]${NC} ")" -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}
