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

# The link watcher (ADR-014): a flat JSON status, a log of bad episodes and a
# CSV of one sample a minute, one file per month.
SIGNAL_LINK_STATUS_FILE="$SIGNAL_STATE_DIR/link"
SIGNAL_LINK_LOG_FILE="$SIGNAL_LOG_DIR/link.log"
SIGNAL_LINK_CSV_GLOB="$SIGNAL_LOG_DIR/link-*.csv"

SIGNAL_DAEMON_LABEL="com.dima.signal.awdl-keeper"
SIGNAL_DAEMON_PLIST="/Library/LaunchDaemons/${SIGNAL_DAEMON_LABEL}.plist"
SIGNAL_DAEMON_BIN="/usr/local/libexec/signal/awdl-keeper"

SIGNAL_LIBEXEC_DIR="/usr/local/libexec/signal"
SIGNAL_WATCH_LABEL="com.dima.signal.link-watch"
SIGNAL_WATCH_PLIST="/Library/LaunchDaemons/${SIGNAL_WATCH_LABEL}.plist"
SIGNAL_WATCH_BIN="$SIGNAL_LIBEXEC_DIR/link-watch"

SIGNAL_MENU_LABEL="com.dima.signal.menu"
SIGNAL_MENU_PLIST="$HOME/Library/LaunchAgents/${SIGNAL_MENU_LABEL}.plist"
SIGNAL_MENU_APP="$HOME/Applications/Signal Menu.app"

# Status files are flat JSON written by our own daemons and never nested, and
# their string values never contain commas or quotes — which is what lets a
# sed one-liner read them without jq (ADR-005).
json_value() {
    local key=$1 file=$2
    sed -n "s/.*\"$key\":\"\{0,1\}\([^,\"}]*\)\"\{0,1\}.*/\1/p" "$file" 2>/dev/null | head -1
}
