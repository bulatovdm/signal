#!/bin/bash
# Signal — Shared knowledge about the local radio.
#
# Everything here is read-only: the daemon is the only writer of awdl0 state
# (ADR-003). Written for /bin/bash 3.2 — no associative arrays, no mapfile.

WIFI_INTERFACE="${SIGNAL_WIFI_INTERFACE:-en1}"
AWDL_INTERFACE="${SIGNAL_AWDL_INTERFACE:-awdl0}"
GATEWAY_FALLBACK="192.168.1.1"

AIRPORT_BIN=/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport

awdl_is_up() {
    ifconfig "$AWDL_INTERFACE" 2>/dev/null | head -1 | grep -q '<UP,'
}

awdl_state_word() {
    if awdl_is_up; then echo "up"; else echo "down"; fi
}

# Cumulative byte counter of an interface (in + out). Survives the interface
# going down, but is reset by a reboot — callers must treat a decrease as a
# reset, not as negative traffic.
interface_bytes() {
    local interface=$1
    netstat -ib -I "$interface" 2>/dev/null | awk -v iface="$interface" '
        $1 == iface || $1 == iface"*" {
            if ($0 ~ /<Link#/) { print $7 + $10; exit }
        }'
}

default_gateway() {
    local gateway
    gateway=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2; exit}')
    echo "${gateway:-$GATEWAY_FALLBACK}"
}

wifi_channel() {
    [[ -x "$AIRPORT_BIN" ]] || { echo "?"; return; }
    "$AIRPORT_BIN" -I 2>/dev/null | awk -F': ' '/^ *channel/ {gsub(/ /,"",$2); print $2; exit}'
}

wifi_rssi() {
    [[ -x "$AIRPORT_BIN" ]] || { echo "?"; return; }
    "$AIRPORT_BIN" -I 2>/dev/null | awk -F': ' '/agrCtlRSSI/ {gsub(/ /,"",$2); print $2; exit}'
}

wifi_noise() {
    [[ -x "$AIRPORT_BIN" ]] || { echo "?"; return; }
    "$AIRPORT_BIN" -I 2>/dev/null | awk -F': ' '/agrCtlNoise/ {gsub(/ /,"",$2); print $2; exit}'
}

wifi_ssid() {
    [[ -x "$AIRPORT_BIN" ]] || { echo "?"; return; }
    "$AIRPORT_BIN" -I 2>/dev/null | awk -F': ' '/ SSID/ {gsub(/^ +/,"",$2); print $2; exit}'
}
