#!/bin/bash
# Signal — RTT statistics shared by `signal measure` and the link watcher.
#
# One implementation on purpose: a number from the daemon and a number from a
# manual measurement must mean the same thing, or the history lies (ADR-008).
# Written for /bin/bash 3.2 — the watcher sources this file as root.

# Reads raw ping output on stdin and prints
#   min avg max stddev p50 p95 p99 received
# Percentiles come from the individual replies, not from ping's summary line:
# the summary has no distribution, and the distribution is the whole point.
rtt_stats() {
    awk '
        /time=/ {
            match($0, /time=[0-9.]+/)
            values[n++] = substr($0, RSTART + 5, RLENGTH - 5) + 0
        }
        END {
            if (n == 0) { print "0 0 0 0 0 0 0 0"; exit }
            for (i = 0; i < n - 1; i++)
                for (j = 0; j < n - 1 - i; j++)
                    if (values[j] > values[j+1]) { t = values[j]; values[j] = values[j+1]; values[j+1] = t }
            sum = 0
            for (i = 0; i < n; i++) sum += values[i]
            mean = sum / n
            variance = 0
            for (i = 0; i < n; i++) variance += (values[i] - mean) ^ 2
            stddev = (n > 1) ? sqrt(variance / n) : 0
            p50 = values[int(n * 0.50)]; if (p50 == "") p50 = values[n-1]
            p95 = values[int(n * 0.95)]; if (p95 == "") p95 = values[n-1]
            p99 = values[int(n * 0.99)]; if (p99 == "") p99 = values[n-1]
            printf "%.3f %.3f %.3f %.3f %.3f %.3f %.3f %d\n",
                values[0], mean, values[n-1], stddev, p50, p95, p99, n
        }'
}

# Loss percentage from ping's summary line; 100 when there is no summary at all.
ping_loss_pct() {
    local loss
    loss="$(awk -F'[,%]' '/packet loss/ {gsub(/ /, "", $3); print $3 + 0; exit}')"
    echo "${loss:-100}"
}

# Mbit/s between two cumulative byte counters over a number of seconds, or "?"
# when a counter is missing or went backwards (a reboot resets it).
background_mbit() {
    local before=$1 after=$2 seconds=$3
    [[ $seconds -gt 0 ]] || seconds=1
    if [[ -n "$before" && -n "$after" && "$after" -ge "$before" ]]; then
        awk -v a="$before" -v b="$after" -v s="$seconds" \
            'BEGIN { printf "%.2f", (b - a) * 8 / s / 1000000 }'
    else
        echo "?"
    fi
}
