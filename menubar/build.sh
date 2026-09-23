#!/bin/bash
# Signal — Build and install the menu bar app.
#
# No Xcode project: one Swift file, swiftc, a hand-made bundle and an ad-hoc
# signature. Installs into ~/Applications so that nothing here needs root.
#
# Usage: signal menu [install|uninstall|build]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/scripts/lib/log.sh"
source "$REPO_ROOT/scripts/lib/paths.sh"

APP_NAME="Signal Menu"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

build_app() {
    log_step "Сборка"
    rm -rf "$APP_BUNDLE"
    mkdir -p "$APP_BUNDLE/Contents/MacOS"

    cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$SIGNAL_MENU_LABEL</string>
    <key>CFBundleExecutable</key><string>SignalMenu</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

    swiftc -O -target arm64-apple-macos12.0 \
        -framework Cocoa \
        -o "$APP_BUNDLE/Contents/MacOS/SignalMenu" \
        "$SCRIPT_DIR/main.swift"

    codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || log_warn "Подпись не легла — приложение всё равно запустится локально"
    log_ok "Собрано: ${APP_BUNDLE/#$HOME/~}"
}

install_agent() {
    mkdir -p "$HOME/Applications"
    rm -rf "$SIGNAL_MENU_APP"
    cp -R "$APP_BUNDLE" "$SIGNAL_MENU_APP"

    mkdir -p "$(dirname "$SIGNAL_MENU_PLIST")"
    cat > "$SIGNAL_MENU_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$SIGNAL_MENU_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SIGNAL_MENU_APP/Contents/MacOS/SignalMenu</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
PLIST

    # bootout returns before the job is gone; bootstrapping straight after it
    # fails with "5: Input/output error" when the agent was already running.
    if launchctl bootout "gui/$(id -u)/$SIGNAL_MENU_LABEL" 2>/dev/null; then
        local attempt
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            launchctl print "gui/$(id -u)/$SIGNAL_MENU_LABEL" >/dev/null 2>&1 || break
            sleep 0.5
        done
    fi
    launchctl bootstrap "gui/$(id -u)" "$SIGNAL_MENU_PLIST"
    log_ok "Значок в строке меню запущен и переживёт перезагрузку"
}

uninstall_agent() {
    launchctl bootout "gui/$(id -u)/$SIGNAL_MENU_LABEL" 2>/dev/null || true
    rm -f "$SIGNAL_MENU_PLIST"
    rm -rf "$SIGNAL_MENU_APP"
    log_ok "Значок убран"
}

case "${1:-install}" in
    build)     build_app ;;
    install)   build_app; install_agent ;;
    uninstall) uninstall_agent ;;
    *) echo "Usage: signal menu [install|uninstall|build]"; exit 1 ;;
esac
