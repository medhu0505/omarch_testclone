#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The speed test asks Fast.com for a list of download targets and hands them
# to curl. The answer comes from the network, so the transfer is bounded and
# only https targets are used: a response that never ends must not fill
# memory, and a hijacked or malformed answer must not point the transfer
# somewhere else.

stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

log="$stub_dir/calls"

cat >"$stub_dir/ip" <<'SH'
#!/bin/bash
echo "1.1.1.1 via 192.0.2.1 dev lo src 1.1.1.1"
SH

cat >"$stub_dir/omarchy-cmd-present" <<'SH'
#!/bin/bash
exit 0
SH

# The endpoint answer is what a hostile or hijacked response looks like: a
# target that is not https, far more targets than the script asked for, and a
# body that keeps going. The download fails once the worker has walked its
# whole target list, so every target the script chose is exercised.
cat >"$stub_dir/curl" <<SH
#!/bin/bash
printf 'curl %s\n' "\$*" >>"$log"
for argument in "\$@"; do
  case "\$argument" in
    *api.fast.com*)
      printf '{"targets":[{"url":"file:///etc/shadow"},{"url":"http://192.0.2.1/payload"}'
      for number in \$(seq 1 200); do
        printf ',{"url":"https://192.0.2.1/target-%s"}' "\$number"
      done
      printf ']}'
      exit 0
      ;;
  esac
done
# Each worker walks the list it was given, so the download fails only after
# that many targets. The counter is per worker, keyed by the parent process.
counter="\$CURL_COUNTS/\$PPID"
calls=\$(cat "\$counter" 2>/dev/null || echo 0)
calls=\$((calls + 1))
echo "\$calls" >"\$counter"
[[ \$calls -gt 3 ]] && exit 1
exit 0
SH

chmod +x "$stub_dir/ip" "$stub_dir/curl" "$stub_dir/omarchy-cmd-present"

mkdir -p "$stub_dir/counts"
PATH="$stub_dir:$PATH" OMARCHY_PATH="$ROOT" CURL_COUNTS="$stub_dir/counts" bash "$ROOT/bin/omarchy-network-speedtest" down >/dev/null 2>&1 || true

# The endpoint fetch carries a bound, so an answer that never ends cannot hold
# the transfer open indefinitely.
grep -q 'curl .*--max-time' "$log" || fail "the endpoint fetch is bounded in time" "$(cat "$log")"
pass "the endpoint fetch is bounded in time"

# Only https targets are transferred, and no target outside the scheme the
# script asked for is ever handed to curl.
grep -q 'file:///etc/shadow' "$log" && fail "a non-https target is never transferred" "$(cat "$log")"
grep -q 'http://192.0.2.1/payload' "$log" && fail "a plain http target is never transferred" "$(cat "$log")"
pass "only https targets are transferred"

# The script asked the endpoint for three targets, and it transfers those
# three: a response that names hundreds does not turn into hundreds of
# transfers, and a script that kept only the first target would fail here.
targets=$(grep -o 'https://192\.0\.2\.1/target-[0-9]*' "$log" | sort -u)
[[ $(wc -l <<<"$targets") == 3 ]] ||
  fail "the targets the script asked for are the ones it transfers" "$(cat "$log")"
for number in 1 2 3; do
  grep -qx "https://192.0.2.1/target-$number" <<<"$targets" ||
    fail "the targets the script asked for are the ones it transfers" "$(cat "$log")"
done
pass "the targets the script asked for are the ones it transfers"
