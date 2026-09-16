#!/bin/bash
# Signal — Filesystem contract shared by the CLI, the daemon and the menu bar app.
#
# The request file is the only channel from user land to the root daemon
# (ADR-005): the CLI and the app write it, the daemon reads it. Its format is
# part of the contract and cannot change without updating the Swift app.

SIGNAL_STATE_DIR="${SIGNAL_STATE_DIR:-/usr/local/var/run/signal}"
SIGNAL_REQUEST_FILE="$SIGNAL_STATE_DIR/request"
SIGNAL_STATUS_FILE="$SIGNAL_STATE_DIR/status"
SIGNAL_LOG_DIR="${SIGNAL_LOG_DIR:-/usr/local/var/log/signal}"
SIGNAL_LOG_FILE="$SIGNAL_LOG_DIR/awdl.log"

SIGNAL_DAEMON_LABEL="com.dima.signal.awdl-keeper"
SIGNAL_DAEMON_PLIST="/Library/LaunchDaemons/${SIGNAL_DAEMON_LABEL}.plist"
SIGNAL_DAEMON_BIN="/usr/local/libexec/signal/awdl-keeper"

SIGNAL_MENU_LABEL="com.dima.signal.menu"
SIGNAL_MENU_PLIST="$HOME/Library/LaunchAgents/${SIGNAL_MENU_LABEL}.plist"
SIGNAL_MENU_APP="$HOME/Applications/Signal Menu.app"
