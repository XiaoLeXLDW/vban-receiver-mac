#!/bin/bash
set -euo pipefail
export LC_ALL=C

app_path="${1:-dist/VBAN Receiver.app}"
binary_path="$app_path/Contents/MacOS/VBANReceiver"
sample_count="${IDLE_CPU_SAMPLES:-10}"
warmup_seconds="${IDLE_CPU_WARMUP_SECONDS:-3}"
median_limit="${IDLE_CPU_MEDIAN_LIMIT:-1.0}"
spike_limit="${IDLE_CPU_SPIKE_LIMIT:-3.0}"
spike_streak_limit="${IDLE_CPU_SPIKE_STREAK:-3}"

fail() {
    echo "Idle CPU check configuration error: $*" >&2
    exit 2
}

require_positive_integer() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]] ||
        ! awk -v value="$value" 'BEGIN { exit !(value > 0 && value == int(value)) }'; then
        fail "$name must be a positive integer (received '$value')."
    fi
}

require_positive_number() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] ||
        ! awk -v value="$value" 'BEGIN { exit !(value > 0) }'; then
        fail "$name must be a positive number (received '$value')."
    fi
}

require_positive_integer "IDLE_CPU_SAMPLES" "$sample_count"
require_positive_number "IDLE_CPU_WARMUP_SECONDS" "$warmup_seconds"
require_positive_number "IDLE_CPU_MEDIAN_LIMIT" "$median_limit"
require_positive_number "IDLE_CPU_SPIKE_LIMIT" "$spike_limit"
require_positive_integer "IDLE_CPU_SPIKE_STREAK" "$spike_streak_limit"

if ! awk -v streak="$spike_streak_limit" -v samples="$sample_count" \
    'BEGIN { exit !(streak <= samples) }'; then
    fail "IDLE_CPU_SPIKE_STREAK must not exceed IDLE_CPU_SAMPLES."
fi

if [[ ! -x "$binary_path" ]]; then
    echo "Missing app executable: $binary_path" >&2
    exit 2
fi

if pgrep -x VBANReceiver >/dev/null 2>&1; then
    echo "VBANReceiver is already running; quit it before measuring idle CPU." >&2
    exit 2
fi

raw_file="$(mktemp -t vban-idle-top)"
cpu_file="$(mktemp -t vban-idle-cpu)"
sorted_file="$(mktemp -t vban-idle-sorted)"
app_pid=""

cleanup() {
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" >/dev/null 2>&1; then
        kill "$app_pid" >/dev/null 2>&1 || true
        wait "$app_pid" >/dev/null 2>&1 || true
    fi
    rm -f "$raw_file" "$cpu_file" "$sorted_file"
}
trap cleanup EXIT INT TERM

"$binary_path" >/dev/null 2>&1 &
app_pid=$!
sleep "$warmup_seconds"

top -l "$((sample_count + 1))" -s 1 -pid "$app_pid" -stats pid,cpu > "$raw_file"
awk -v pid="$app_pid" '$1 == pid { seen++; if (seen > 1) print $2 }' "$raw_file" > "$cpu_file"

actual_count="$(wc -l < "$cpu_file" | tr -d ' ')"
if [[ "$actual_count" -ne "$sample_count" ]]; then
    echo "Expected $sample_count CPU samples, received $actual_count." >&2
    exit 2
fi
if [[ ! -s "$cpu_file" ]]; then
    echo "Idle CPU measurement produced no samples." >&2
    exit 2
fi
if ! awk 'NF != 1 || $1 !~ /^[0-9]+([.][0-9]+)?$/ { exit 1 }' "$cpu_file"; then
    echo "Idle CPU measurement produced a non-numeric sample." >&2
    exit 2
fi

sort -n "$cpu_file" > "$sorted_file"
median="$(awk '{ values[NR] = $1 } END { if (NR % 2) print values[(NR + 1) / 2]; else printf "%.3f", (values[NR / 2] + values[NR / 2 + 1]) / 2 }' "$sorted_file")"
if [[ -z "$median" ]] || [[ ! "$median" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "Idle CPU measurement did not produce a valid median." >&2
    exit 2
fi
samples="$(awk 'BEGIN { first = 1 } { if (!first) printf ", "; printf "%s", $1; first = 0 } END { print "" }' "$cpu_file")"
median_ok="$(awk -v value="$median" -v limit="$median_limit" 'BEGIN { print (value < limit ? 1 : 0) }')"
streak_failed="$(awk -v limit="$spike_limit" -v required="$spike_streak_limit" '$1 > limit { streak++; if (streak >= required) failed = 1; next } { streak = 0 } END { print failed ? 1 : 0 }' "$cpu_file")"

echo "Idle CPU samples (%): $samples"
echo "Median: $median% (required: <$median_limit%)"
echo "Sustained spike rule: fewer than $spike_streak_limit consecutive samples above $spike_limit%"

if [[ "$median_ok" -ne 1 || "$streak_failed" -eq 1 ]]; then
    echo "Idle CPU check failed." >&2
    exit 1
fi

echo "Idle CPU check passed."
