#!/bin/bash
# Signal — Read-only client for the Keenetic RCI (ADR-016).
#
# Only GET requests: the tunnel watcher reads the router's state and never
# changes it. Written for /bin/bash 3.2 — the watcher sources this file as root.
#
# The credentials live in a root-only file. The watcher runs under launchd with
# its own PATH, so every tool is called by absolute path.

ROUTER_CONFIG_FILE="${SIGNAL_ROUTER_CONFIG:-/usr/local/etc/signal/router.conf}"
ROUTER_ADDRESS="192.168.1.1"
ROUTER_USER=""
ROUTER_PASSWORD=""
ROUTER_JAR=""
JQ_BIN=""

find_jq() {
    local candidate
    for candidate in /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq; do
        [[ -x "$candidate" ]] && { JQ_BIN="$candidate"; return 0; }
    done
    return 1
}

# Succeeds only when there is something to log in with and something to read
# the answers with; otherwise the watcher writes "?" in the router columns.
router_load_config() {
    [[ -r "$ROUTER_CONFIG_FILE" ]] || return 1
    # shellcheck disable=SC1090
    source "$ROUTER_CONFIG_FILE"
    [[ -n "$ROUTER_USER" && -n "$ROUTER_PASSWORD" ]] && find_jq
}

router_header_value() {
    awk -v want="$2" 'tolower(substr($0, 1, length(want) + 1)) == want ":" {
        sub(/^[^:]*: */, ""); sub(/\r$/, ""); print; exit
    }' <<<"$1"
}

# Keenetic challenge login: sha256(challenge + md5(user:realm:password)).
# The session cookie rotates on every answer, so the jar is read and written
# back on each request.
router_login() {
    router_logout
    ROUTER_JAR=$(mktemp -t signal-rci) || return 1
    chmod 600 "$ROUTER_JAR"

    local headers realm challenge md5 sha body code
    headers=$(/usr/bin/curl -s -m 5 -D - -o /dev/null -c "$ROUTER_JAR" "http://$ROUTER_ADDRESS/auth") || return 1
    realm=$(router_header_value "$headers" "x-ndm-realm")
    challenge=$(router_header_value "$headers" "x-ndm-challenge")
    [[ -n "$realm" && -n "$challenge" ]] || return 1

    md5=$(printf '%s:%s:%s' "$ROUTER_USER" "$realm" "$ROUTER_PASSWORD" | /usr/bin/openssl dgst -md5 -hex | awk '{print $NF}')
    sha=$(printf '%s%s' "$challenge" "$md5" | /usr/bin/openssl dgst -sha256 -hex | awk '{print $NF}')
    body=$("$JQ_BIN" -nc --arg login "$ROUTER_USER" --arg password "$sha" '{login: $login, password: $password}')

    code=$(/usr/bin/curl -s -m 5 -o /dev/null -w '%{http_code}' \
        -b "$ROUTER_JAR" -c "$ROUTER_JAR" -X POST "http://$ROUTER_ADDRESS/auth" \
        -H 'Content-Type: application/json' -d "$body")
    [[ "$code" == "200" ]]
}

# Prints the JSON answer of one RCI path, e.g. /show/system; fails on anything
# but 200.
router_get() {
    [[ -n "$ROUTER_JAR" ]] || return 1
    local response code
    response=$(/usr/bin/curl -s -m 10 -w '\n%{http_code}' \
        -b "$ROUTER_JAR" -c "$ROUTER_JAR" "http://$ROUTER_ADDRESS/rci$1")
    code="${response##*$'\n'}"
    [[ "$code" == "200" ]] || return 1
    printf '%s\n' "${response%$'\n'*}"
}

router_logout() {
    [[ -n "$ROUTER_JAR" ]] && rm -f "$ROUTER_JAR"
    ROUTER_JAR=""
}

# "rx tx" byte counters of a router interface, or nothing.
router_interface_bytes() {
    router_get "/show/interface/stat?name=$1" | "$JQ_BIN" -r '"\(.rxbytes) \(.txbytes)"' 2>/dev/null
}
