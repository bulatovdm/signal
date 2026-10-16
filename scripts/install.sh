#!/bin/bash
# Signal — Install the keeper, the watchers, the heartbeat and the `signal` command.
#
# Root is needed once, here: the daemon owns awdl0 (ADR-003) and everyday use
# goes through the request file without sudo (ADR-005).
#
# The privileged half runs as a separate invocation (--root-steps) so that it
# can be raised either by sudo in a terminal or by the system authorization
# dialog when there is no terminal to type a password into.
#
# Usage: ./scripts/install.sh [--uninstall]
#        ./scripts/install.sh --root-steps | --root-uninstall   (must be root)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/paths.sh"

CONFIG_DIR=/usr/local/etc/signal
CONFIG_FILE="$CONFIG_DIR/keeper.conf"

# Empty when we are already root: the privileged half is invoked as a whole,
# not command by command.
SUDO=sudo
[[ $(id -u) -eq 0 ]] && SUDO=""

# Asks for the password the way the system does it, because a hook-driven or
# non-interactive session has no terminal for sudo to read from.
raise_privileges() {
    if [[ -t 0 ]]; then
        sudo "$SCRIPT_DIR/install.sh" "$@"
    else
        # AppleScript hands back the output with carriage returns; without this
        # the whole privileged half arrives as one unreadable line.
        osascript -e "do shell script \"'$SCRIPT_DIR/install.sh' $*\" with administrator privileges" | tr '\r' '\n' 
    fi
}

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
    $SUDO mkdir -p "$CONFIG_DIR"
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "Конфиг уже есть, не трогаю: $CONFIG_FILE"
        return
    fi
    $SUDO tee "$CONFIG_FILE" >/dev/null <<'CONFIG'
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
    $SUDO mkdir -p "$(dirname "$SIGNAL_DAEMON_BIN")"
    $SUDO install -m 755 -o root -g wheel "$SCRIPT_DIR/daemon/awdl-keeper.sh" "$SIGNAL_DAEMON_BIN"
    $SUDO install -m 644 -o root -g wheel "$SCRIPT_DIR/daemon/$(basename "$SIGNAL_DAEMON_PLIST")" "$SIGNAL_DAEMON_PLIST"
    log_ok "Демон: $SIGNAL_DAEMON_BIN"

    if launchctl print "system/$SIGNAL_DAEMON_LABEL" >/dev/null 2>&1; then
        $SUDO launchctl bootout "system/$SIGNAL_DAEMON_LABEL" 2>/dev/null || true
        sleep 1
    fi
    $SUDO launchctl bootstrap system "$SIGNAL_DAEMON_PLIST"
    log_ok "Сторож загружен в launchd (переживает перезагрузку и сон)"
}

# The watcher sources its lib at run time, so the lib is installed next to it:
# a root daemon must not read code from a user-writable checkout.
install_watch() {
    $SUDO mkdir -p "$SIGNAL_LIBEXEC_DIR/lib"
    $SUDO install -m 644 -o root -g wheel "$SCRIPT_DIR/lib/awdl.sh" "$SCRIPT_DIR/lib/stats.sh" "$SIGNAL_LIBEXEC_DIR/lib/"
    $SUDO install -m 755 -o root -g wheel "$SCRIPT_DIR/daemon/link-watch.sh" "$SIGNAL_WATCH_BIN"
    $SUDO install -m 644 -o root -g wheel "$SCRIPT_DIR/daemon/$(basename "$SIGNAL_WATCH_PLIST")" "$SIGNAL_WATCH_PLIST"
    log_ok "Наблюдатель: $SIGNAL_WATCH_BIN"

    if launchctl print "system/$SIGNAL_WATCH_LABEL" >/dev/null 2>&1; then
        $SUDO launchctl bootout "system/$SIGNAL_WATCH_LABEL" 2>/dev/null || true
        sleep 1
    fi
    $SUDO launchctl bootstrap system "$SIGNAL_WATCH_PLIST"
    log_ok "Наблюдатель загружен в launchd: раз в минуту пишет состояние канала"
}

# The tunnel watcher reads the router through RCI, so it needs the router's
# login. It is asked for here, in the user half, and handed to the root half in
# a 600 temporary file: the root half may run under the authorization dialog,
# where there is no terminal to type into. ROUTER_CREDENTIALS_FILE skips the
# question when a file in the same format is already at hand.
ROUTER_CREDENTIALS_TEMP=""
prepare_router_credentials() {
    if [[ -f "$SIGNAL_ROUTER_CONF" ]]; then
        log_info "Доступ к роутеру уже настроен, не трогаю: $SIGNAL_ROUTER_CONF"
        return
    fi
    ROUTER_CREDENTIALS_TEMP=$(mktemp -t signal-router)
    chmod 600 "$ROUTER_CREDENTIALS_TEMP"
    if [[ -n "${ROUTER_CREDENTIALS_FILE:-}" && -r "$ROUTER_CREDENTIALS_FILE" ]]; then
        cat "$ROUTER_CREDENTIALS_FILE" > "$ROUTER_CREDENTIALS_TEMP"
        return
    fi
    if [[ ! -t 0 ]]; then
        log_warn "Нет терминала, чтобы спросить логин роутера — наблюдатель туннеля будет писать «?» в колонках роутера."
        log_dim "        Позже: ROUTER_CREDENTIALS_FILE=<файл> signal install, формат — как $SIGNAL_ROUTER_CONF"
        rm -f "$ROUTER_CREDENTIALS_TEMP"; ROUTER_CREDENTIALS_TEMP=""
        return
    fi
    local user password
    log_info "Наблюдателю туннеля нужен доступ к роутеру на чтение (лучше отдельный пользователь Keenetic)."
    read -r -p "  Логин роутера: " user
    read -r -s -p "  Пароль: " password; echo
    if [[ -z "$user" || -z "$password" ]]; then
        log_warn "Пусто — колонки роутера будут «?»."
        rm -f "$ROUTER_CREDENTIALS_TEMP"; ROUTER_CREDENTIALS_TEMP=""
        return
    fi
    {
        echo "# Signal — доступ наблюдателя туннеля к RCI роутера (ADR-016). root:wheel 600."
        printf 'ROUTER_ADDRESS=%q\n' "$GATEWAY_FOR_ROUTER"
        printf 'ROUTER_USER=%q\n' "$user"
        printf 'ROUTER_PASSWORD=%q\n' "$password"
    } > "$ROUTER_CREDENTIALS_TEMP"
}
GATEWAY_FOR_ROUTER="$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2; exit}')"
GATEWAY_FOR_ROUTER="${GATEWAY_FOR_ROUTER:-192.168.1.1}"

install_router_credentials() {
    local source_file=${1:-}
    [[ -n "$source_file" && -f "$source_file" ]] || return 0
    $SUDO mkdir -p "$CONFIG_DIR"
    $SUDO install -m 600 -o root -g wheel "$source_file" "$SIGNAL_ROUTER_CONF"
    log_ok "Доступ к роутеру: $SIGNAL_ROUTER_CONF (только root)"
}

install_tunnel_watch() {
    $SUDO mkdir -p "$SIGNAL_LIBEXEC_DIR/lib"
    $SUDO install -m 644 -o root -g wheel "$SCRIPT_DIR/lib/router.sh" "$SIGNAL_LIBEXEC_DIR/lib/"
    $SUDO install -m 755 -o root -g wheel "$SCRIPT_DIR/daemon/tunnel-watch.sh" "$SIGNAL_TUNNEL_BIN"
    $SUDO install -m 644 -o root -g wheel "$SCRIPT_DIR/daemon/$(basename "$SIGNAL_TUNNEL_PLIST")" "$SIGNAL_TUNNEL_PLIST"
    log_ok "Наблюдатель туннеля: $SIGNAL_TUNNEL_BIN"
    [[ -x /opt/homebrew/bin/jq || -x /usr/local/bin/jq ]] || log_warn "jq не найден (brew install jq) — без него колонки роутера будут «?»."

    if launchctl print "system/$SIGNAL_TUNNEL_LABEL" >/dev/null 2>&1; then
        $SUDO launchctl bootout "system/$SIGNAL_TUNNEL_LABEL" 2>/dev/null || true
        # bootout is asynchronous: bootstrap right after it fails with
        # "5: Input/output error" while launchd still sees the job.
        local waited=0
        while launchctl print "system/$SIGNAL_TUNNEL_LABEL" >/dev/null 2>&1 && [[ $waited -lt 10 ]]; do
            sleep 1; waited=$((waited + 1))
        done
    fi
    $SUDO launchctl bootstrap system "$SIGNAL_TUNNEL_PLIST"
    log_ok "Наблюдатель туннеля загружен в launchd: при запуске, раз в 15 мин и по signal mark"
}

install_pulse_watch() {
    $SUDO install -m 755 -o root -g wheel "$SCRIPT_DIR/daemon/pulse-watch.sh" "$SIGNAL_PULSE_BIN"
    $SUDO install -m 644 -o root -g wheel "$SCRIPT_DIR/daemon/$(basename "$SIGNAL_PULSE_PLIST")" "$SIGNAL_PULSE_PLIST"
    log_ok "Пульс: $SIGNAL_PULSE_BIN"
    if launchctl print "system/$SIGNAL_PULSE_LABEL" >/dev/null 2>&1; then
        $SUDO launchctl bootout "system/$SIGNAL_PULSE_LABEL" 2>/dev/null || true
        local waited=0
        while launchctl print "system/$SIGNAL_PULSE_LABEL" >/dev/null 2>&1 && [[ $waited -lt 10 ]]; do
            sleep 1; waited=$((waited + 1))
        done
    fi
    $SUDO launchctl bootstrap system "$SIGNAL_PULSE_PLIST"
    log_ok "Пульс загружен в launchd: раз в 5 с, при обрыве — снимок роутера"
}

install_tunnels_watch() {
    $SUDO install -m 755 -o root -g wheel "$SCRIPT_DIR/daemon/tunnels-watch.sh" "$SIGNAL_TUNNELS_BIN"
    $SUDO install -m 644 -o root -g wheel "$SCRIPT_DIR/daemon/$(basename "$SIGNAL_TUNNELS_PLIST")" "$SIGNAL_TUNNELS_PLIST"
    log_ok "Наблюдатель туннелей роутера: $SIGNAL_TUNNELS_BIN"
    if launchctl print "system/$SIGNAL_TUNNELS_LABEL" >/dev/null 2>&1; then
        $SUDO launchctl bootout "system/$SIGNAL_TUNNELS_LABEL" 2>/dev/null || true
        local waited=0
        while launchctl print "system/$SIGNAL_TUNNELS_LABEL" >/dev/null 2>&1 && [[ $waited -lt 10 ]]; do
            sleep 1; waited=$((waited + 1))
        done
    fi
    $SUDO launchctl bootstrap system "$SIGNAL_TUNNELS_PLIST"
    log_ok "Наблюдатель туннелей роутера загружен в launchd: раз в 10 с, все туннели"
}

uninstall_tunnels_watch() {
    if launchctl print "system/$SIGNAL_TUNNELS_LABEL" >/dev/null 2>&1; then
        $SUDO launchctl bootout "system/$SIGNAL_TUNNELS_LABEL" 2>/dev/null || true
        log_ok "Наблюдатель туннелей роутера выгружен"
    fi
    $SUDO rm -f "$SIGNAL_TUNNELS_PLIST" "$SIGNAL_TUNNELS_BIN"
}

uninstall_pulse_watch() {
    if launchctl print "system/$SIGNAL_PULSE_LABEL" >/dev/null 2>&1; then
        $SUDO launchctl bootout "system/$SIGNAL_PULSE_LABEL" 2>/dev/null || true
        log_ok "Пульс выгружен"
    fi
    $SUDO rm -f "$SIGNAL_PULSE_PLIST" "$SIGNAL_PULSE_BIN"
}

uninstall_tunnel_watch() {
    if launchctl print "system/$SIGNAL_TUNNEL_LABEL" >/dev/null 2>&1; then
        $SUDO launchctl bootout "system/$SIGNAL_TUNNEL_LABEL" 2>/dev/null || true
        log_ok "Наблюдатель туннеля выгружен"
    fi
    $SUDO rm -f "$SIGNAL_TUNNEL_PLIST" "$SIGNAL_TUNNEL_BIN" "$SIGNAL_ROUTER_CONF"
}

uninstall_watch() {
    if launchctl print "system/$SIGNAL_WATCH_LABEL" >/dev/null 2>&1; then
        $SUDO launchctl bootout "system/$SIGNAL_WATCH_LABEL" 2>/dev/null || true
        log_ok "Наблюдатель выгружен"
    fi
    $SUDO rm -f "$SIGNAL_WATCH_PLIST" "$SIGNAL_WATCH_BIN"
    $SUDO rm -rf "$SIGNAL_LIBEXEC_DIR/lib"
}

uninstall_daemon() {
    if launchctl print "system/$SIGNAL_DAEMON_LABEL" >/dev/null 2>&1; then
        $SUDO launchctl bootout "system/$SIGNAL_DAEMON_LABEL" 2>/dev/null || true
        log_ok "Сторож выгружен"
    fi
    $SUDO rm -f "$SIGNAL_DAEMON_PLIST" "$SIGNAL_DAEMON_BIN"
    # Leaving the radio down after uninstalling would be a silent side effect:
    # put the machine back the way macOS expects it.
    $SUDO ifconfig awdl0 up 2>/dev/null || true
    log_ok "awdl0 поднят обратно, система в исходном состоянии"
    log_dim "        Логи и замеры не тронуты: $SIGNAL_LOG_DIR, measurements/"
}

case "${1:-}" in
    --root-steps)
        [[ $(id -u) -eq 0 ]] || { log_error "--root-steps запускается только от root"; exit 1; }
        write_default_config
        install_daemon
        install_watch
        install_router_credentials "${2:-}"
        install_tunnel_watch
        install_pulse_watch
        install_tunnels_watch
        exit 0 ;;
    --root-uninstall)
        [[ $(id -u) -eq 0 ]] || { log_error "--root-uninstall запускается только от root"; exit 1; }
        uninstall_tunnels_watch
        uninstall_pulse_watch
        uninstall_tunnel_watch
        uninstall_watch
        uninstall_daemon
        exit 0 ;;
    --uninstall)
        log_header "Удаление"
        raise_privileges --root-uninstall
        exit 0 ;;
esac

log_header "Установка"
log_info "Система спросит пароль администратора — один раз, ради демона."
install_command
prepare_router_credentials
raise_privileges --root-steps ${ROUTER_CREDENTIALS_TEMP:+"$ROUTER_CREDENTIALS_TEMP"}
[[ -n "$ROUTER_CREDENTIALS_TEMP" ]] && rm -f "$ROUTER_CREDENTIALS_TEMP"

sleep 3
"$SCRIPT_DIR/ops/status.sh"
