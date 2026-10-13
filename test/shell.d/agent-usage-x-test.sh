#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq
require_command python3

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

export HOME="$test_tmp/home"
export XDG_CONFIG_HOME="$test_tmp/config"
export XDG_CACHE_HOME="$test_tmp/cache"
export XDG_STATE_HOME="$test_tmp/state"

mkdir -p "$HOME" "$XDG_CONFIG_HOME/cursor" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

billing_end_ms=$(python3 -c 'import datetime as dt; print(int((dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=12)).timestamp() * 1000))')

signed_in() {
  jq -nc --arg token "$1" '{accessToken: $token}' >"$XDG_CONFIG_HOME/cursor/auth.json"
}

collect() {
  COLLECTOR="$ROOT/bin/omarchy-agent-usage-x" BILLING_END_MS="$billing_end_ms" python3 - "$@" <<'PY'
import importlib.machinery, importlib.util, io, json, os, sys, urllib.error

loader = importlib.machinery.SourceFileLoader("collector", os.environ["COLLECTOR"])
spec = importlib.util.spec_from_loader(loader.name, loader)
collector = importlib.util.module_from_spec(spec)
loader.exec_module(collector)

end = int(os.environ["BILLING_END_MS"])
responses = {
  "aiserver.v1.DashboardService/GetPlanInfo": {
    "planInfo": {
      "planName": "Pro",
      "price": "$20/mo",
      "includedUsagePeriod": "INCLUDED_USAGE_PERIOD_MONTHLY",
    }
  },
  "aiserver.v1.DashboardService/GetCurrentPeriodUsage": {
    "billingCycleEnd": end,
    "planUsage": {
      "autoPercentUsed": 37.5,
      "apiPercentUsed": 0,
      "totalPercentUsed": 37.5,
    },
  },
}

def urlopen(request, timeout=None):
  method = request.full_url.split("://", 1)[-1].split("/", 1)[-1]
  if os.environ.get("X_FAIL_USAGE") == "1" and method.endswith("GetCurrentPeriodUsage"):
    raise urllib.error.HTTPError(request.full_url, 401, "Unauthorized", hdrs=None, fp=None)
  if method not in responses:
    raise AssertionError(f"unexpected method {method}")
  auth = request.get_header("Authorization") or request.get_header("authorization")
  assert auth.split(" ", 1)[1] == "token-main"
  # urlopen returns a context-manager response in modern Python; BytesIO alone
  # lacks __enter__. Mimic a minimal response.
  class Resp(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *a): return False
  return Resp(json.dumps(responses[method]).encode())

collector.urllib.request.urlopen = urlopen
sys.argv = ["omarchy-agent-usage-x"] + (os.environ.get("COLLECT_ARGS") or "--force").split()
collector.main()
PY
}

record=$(collect)
[[ $(jq -c '{ready, tierLabel, limits, usageStatusText}' <<<"$record") == '{"ready":false,"tierLabel":"","limits":[],"usageStatusText":"Cursor auth missing"}' ]] ||
  fail "without Cursor auth the X Subscription record stays empty" "$record"
pass "without Cursor auth the X Subscription record stays empty"

signed_in token-main
record=$(collect)
[[ $(jq -c '{ready, id, name, tierLabel, stale: .limitsStale, label: .limits[0].label, percent: .limits[0].percent}' <<<"$record") == '{"ready":true,"id":"x","name":"X Subscription","tierLabel":"Pro · $20/mo · shared monthly pool","stale":false,"label":"Included pool (Cursor + Grok)","percent":0.375}' ]] ||
  fail "X Subscription plan and shared pool come from Cursor dashboard APIs" "$record"
[[ -n $(jq -r '.limits[0].resetsAt' <<<"$record") ]] || fail "the billing window says when the period ends" "$record"
[[ $(jq -r '.authHelpText' <<<"$record") == "" ]] || fail "a successful probe drops the login hint" "$record"
pass "X Subscription plan and shared pool come from Cursor dashboard APIs"

# Reused limits keep the login hint off.
record=$(COLLECT_ARGS="" collect)
[[ $(jq -c '{percent: .limits[0].percent, help: .authHelpText, stale: .limitsStale}' <<<"$record") == '{"percent":0.375,"help":"","stale":false}' ]] ||
  fail "reused X Subscription limits drop the login hint" "$record"
pass "reused X Subscription limits drop the login hint"

# A failed probe keeps the last numbers and says so.
record=$(collect)
record=$(X_FAIL_USAGE=1 COLLECT_ARGS="--force" collect)
[[ $(jq -c '{usageStatusText, first: .limits[0].percent, stale: .limitsStale}' <<<"$record") == '{"usageStatusText":"Waiting for auth","first":0.375,"stale":true}' ]] ||
  fail "a failed probe keeps the last shared-pool numbers" "$record"
pass "a failed probe keeps the last shared-pool numbers"

# Local Cursor transcripts become prompt/session stats.
projects="$HOME/.cursor/projects/demo/agent-transcripts"
mkdir -p "$projects"
now=$(date +%s)
cat >"$projects/session-a.jsonl" <<'JSONL'
{"role":"user","content":"hello"}
{"role":"assistant","content":"hi"}
{"role":"user","content":"again"}
JSONL
cat >"$projects/session-b.jsonl" <<'JSONL'
{"type":"human","content":"other"}
JSONL
touch -d "@$now" "$projects/session-a.jsonl" "$projects/session-b.jsonl"
rm -f "$XDG_CACHE_HOME"/omarchy/agent-usage/x-scan.json
record=$(COLLECT_ARGS="--force" collect)
[[ $(jq -c '{hasLocalStats, todayPrompts, todaySessions, totalPrompts, totalSessions}' <<<"$record") == '{"hasLocalStats":true,"todayPrompts":3,"todaySessions":2,"totalPrompts":3,"totalSessions":2}' ]] ||
  fail "X Subscription counts prompts from Cursor agent transcripts" "$record"
pass "X Subscription counts prompts from Cursor agent transcripts"

# limits-only reuses the transcript scan.
mkdir -p "$projects/extra"
printf '%s\n' '{"role":"user","content":"later"}' >"$projects/extra/session-c.jsonl"
touch -d "@$now" "$projects/extra/session-c.jsonl"
record=$(COLLECT_ARGS="--limits-only" collect)
[[ $(jq -r '.totalSessions' <<<"$record") == 2 ]] || fail "a limits-only refresh reuses the transcript scan" "$record"
pass "a limits-only refresh reuses the transcript scan"
