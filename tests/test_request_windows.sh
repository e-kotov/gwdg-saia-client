#!/usr/bin/env bash
# Regression: request-scoped headers must render quota, including 10-second windows.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/saia-request-windows.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"
cat > "$scratch/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'HTTP/1.1 429 Too Many Requests\r\n'
printf 'x-ratelimit-limit-requests-10s: 2\r\n'
printf 'x-ratelimit-remaining-requests-10s: 2\r\n'
printf 'x-ratelimit-reset-requests-10s: 0\r\n'
printf 'x-ratelimit-limit-requests-hour: 400\r\n'
printf 'x-ratelimit-remaining-requests-hour: 400\r\n'
printf 'x-ratelimit-reset-requests-hour: 0\r\n'
printf 'x-ratelimit-limit-requests-day: 800\r\n'
printf 'x-ratelimit-remaining-requests-day: 0\r\n'
printf 'x-ratelimit-reset-requests-day: 47011\r\n'
printf 'x-ratelimit-limit-requests-month: 3000\r\n'
printf 'x-ratelimit-remaining-requests-month: 2139\r\n'
printf 'x-ratelimit-reset-requests-month: 2379811\r\n'
printf 'x-ratelimit-scope: user\r\n\r\n{}'
MOCK
chmod +x "$scratch/bin/curl"
output=$(cd "$scratch" && PATH="$scratch/bin:$PATH" SAIA_API_KEY=test bash "$root/saia.sh" limits)
printf '%s\n' "$output" | rg -q '10s: +2 / 2 +remaining'
printf '%s\n' "$output" | rg -q 'Hour: +400 / 400 +remaining'
printf '%s\n' "$output" | rg -q 'Day: +0 / 800 +remaining.*resets in'
printf '%s\n' "$output" | rg -q 'Month: +2139 / 3000 +remaining.*resets in'
if printf '%s\n' "$output" | rg -q 'headers are not available'; then exit 1; fi
echo 'Request-window quota regression passed'
