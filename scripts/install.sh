#!/bin/bash
# Signal — Install the keeper daemon and the `signal` command.
#
# Root is needed once, here: the daemon owns awdl0 (ADR-003) and everyday use
# goes through the request file without sudo (ADR-005).
#
# Usage: ./scripts/install.sh [--uninstall]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/paths.sh"

CONFIG_DIR=/usr/local/etc/signal
CONFIG_FILE="$CONFIG_DIR/keeper.conf"

pick_bin_dir() {
    local candidate
    for candidate in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
        [[ -d "$candidate" ]] && { echo "$candidate"; return; }
    done
    echo "$HOME/.local/bin"
}

install_command() {
    local bin_dir target
    bin_dir="$(pick_bin_dir)"
    target="$bin_dir/signal"
    mkdir -p "$bin_dir"
    if [[ -e "$target" && ! -L "$target" ]]; then
        log_warn "В $target уже лежит не наш файл — команда не ставится."
        return
    fi
    ln -sf "$REPO_ROOT/scripts/signal.sh" "$target"
    log_ok "Команда: $target → scripts/signal.sh"
}

write_default_config() {
    sudo mkdir -p "$CONFIG_DIR"
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "Конфиг уже есть, не трогаю: $CONFIG_FILE"
        return
    fi
    sudo tee "$CONFIG_FILE" >/dev/null <<'CONFIG'
# Signal — keeper policy (ADR-004). Values in seconds and bytes.
# После правки: sudo launchctl kickstart -k system/com.dima.signal.awdl-keeper

# Сколько интерфейс живёт после подъёма, не спрашивая ни о чём.
# Это окно, в которое отправитель должен увидеть Mac и начать передачу.
GRACE_SECONDS=45

# Сколько можно простаивать после последнего трафика, прежде чем гасим.
IDLE_SECONDS=20

# Сколько байт между тиками считается настоящей передачей, а не discovery.
ACTIVE_BYTES=131072

# Шаг цикла.
TICK_SECONDS=2
CONFIG
    log_ok "Конфиг политики: $CONFIG_FILE"
}

install_daemon() {
    sudo mkdir -p "$(dirname "$SIGNAL_DAEMON_BIN")"
    sudo install -m 755 -o root -g wheel "$SCRIPT_DIR/daemon/awdl-keeper.sh" "$SIGNAL_DAEMON_BIN"
    sudo install -m 644 -o root -g wheel "$SCRIPT_DIR/daemon/$(basename "$SIGNAL_DAEMON_PLIST")" "$SIGNAL_DAEMON_PLIST"
    log_ok "Демон: $SIGNAL_DAEMON_BIN"

    if launchctl print "system/$SIGNAL_DAEMON_LABEL" >/dev/null 2>&1; then
        sudo launchctl bootout "system/$SIGNAL_DAEMON_LABEL" 2>/dev/null || true
        sleep 1
    fi
    sudo launchctl bootstrap system "$SIGNAL_DAEMON_PLIST"
    log_ok "Сторож загружен в launchd (переживает перезагрузку и сон)"
}

uninstall_daemon() {
    if launchctl print "system/$SIGNAL_DAEMON_LABEL" >/dev/null 2>&1; then
        sudo launchctl bootout "system/$SIGNAL_DAEMON_LABEL" 2>/dev/null || true
        log_ok "Сторож выгружен"
    fi
    sudo rm -f "$SIGNAL_DAEMON_PLIST" "$SIGNAL_DAEMON_BIN"
    # Leaving the radio down after uninstalling would be a silent side effect:
    # put the machine back the way macOS expects it.
    sudo ifconfig awdl0 up 2>/dev/null || true
    log_ok "awdl0 поднят обратно, система в исходном состоянии"
    log_dim "        Логи и замеры не тронуты: $SIGNAL_LOG_DIR, measurements/"
}

if [[ "${1:-}" == "--uninstall" ]]; then
    log_header "Удаление"
    uninstall_daemon
    exit 0
fi

log_header "Установка"
log_info "Понадобится пароль sudo — один раз, для демона."
install_command
write_default_config
install_daemon

sleep 3
"$SCRIPT_DIR/ops/status.sh"
