#!/bin/bash

source "$(dirname "$0")/base-test.sh"

require_command jq
require_command python3

# probe_limits reaches Anthropic, so the reader that interprets its answer is
# exercised on its own: the collector loads as a module, and a recorded payload
# stands in for the response.
read_limits() {
  COLLECTOR="$ROOT/bin/omarchy-agent-usage-claude" PAYLOAD="$1" python3 - <<'PY'
import importlib.machinery, importlib.util, io, json, os

loader = importlib.machinery.SourceFileLoader("collector", os.environ["COLLECTOR"])
spec = importlib.util.spec_from_loader(loader.name, loader)
collector = importlib.util.module_from_spec(spec)
loader.exec_module(collector)

collector.urllib.request.urlopen = lambda request, timeout=None: io.BytesIO(os.environ["PAYLOAD"].encode())

print(json.dumps(collector.probe_limits("token")))
PY
}

# The two flat buckets, then every scoped shape that matters: a model's weekly
# window, a second window for that same model, a model that names only an id,
# and — dropped — a repeat of a window already read, a blank name, and a
# percent that will not parse.
limits=$(read_limits '{
  "five_hour": { "utilization": 78.0 },
  "seven_day": { "utilization": 12.0 },
  "seven_day_opus": null,
  "limits": [
    { "kind": "session", "percent": 78, "scope": null },
    { "kind": "weekly_all", "percent": 12, "scope": null },
    { "kind": "weekly_scoped", "percent": 17, "resets_at": "2026-08-15T03:00:00+00:00",
      "scope": { "model": { "id": "claude-fable-5", "display_name": "Fable" }, "surface": null } },
    { "kind": "weekly_scoped", "percent": 99, "scope": { "model": { "display_name": "Fable" } } },
    { "kind": "five_hour_scoped", "percent": 95, "scope": { "model": { "display_name": "Fable" } } },
    { "kind": "weekly_scoped", "percent": 42, "scope": { "model": { "id": "claude-opus-5", "display_name": null } } },
    { "kind": "weekly_scoped", "percent": 5, "scope": { "model": { "display_name": "  " } } },
    { "kind": "weekly_scoped", "percent": "unknown", "scope": { "model": { "display_name": "Opus" } } }
  ]
}')

expected='[{"label":"Session (5-hour)","percent":0.78,"resetsAt":""},{"label":"Weekly (7-day)","percent":0.12,"resetsAt":""},{"label":"Fable Weekly","title":"Fable Weekly","percent":0.17,"resetsAt":"2026-08-15T03:00:00+00:00"},{"label":"Fable Session","title":"Fable Session","percent":0.95,"resetsAt":""},{"label":"claude-opus-5 Weekly","title":"claude-opus-5 Weekly","percent":0.42,"resetsAt":""}]'
[[ $(jq -c '.limits' <<<"$limits") == "$expected" ]] ||
  fail "Claude collector reads every model-scoped window once and drops unusable entries" "$limits"
pass "Claude collector reads every model-scoped window once and drops unusable entries"

# A payload that speaks fractions says so in its buckets, and the scoped
# entries are read on the same scale rather than assuming percentages.
fractions=$(read_limits '{
  "five_hour": { "utilization": 0.78 },
  "limits": [
    { "kind": "session", "percent": 0.78, "scope": null },
    { "kind": "weekly_scoped", "percent": 0.42, "scope": { "model": { "display_name": "Fable" } } }
  ]
}')

[[ $(jq -c '[.limits[].percent]' <<<"$fractions") == "[0.78,0.42]" ]] ||
  fail "Claude collector reads scoped percentages on the payload's own scale" "$fractions"
pass "Claude collector reads scoped percentages on the payload's own scale"

# An account with no model-scoped allowance, and an endpoint that never grew
# the array, both keep the session and weekly windows they always had.
for payload in '{"five_hour":{"utilization":78.0},"limits":[{"kind":"session","percent":78,"scope":null}]}' \
  '{"five_hour":{"utilization":78.0},"seven_day":{"utilization":12.0}}'; do
  [[ $(jq -c '[.limits[].label]' <<<"$(read_limits "$payload")") != *" Weekly"* ]] ||
    fail "Claude collector adds no limit when the payload scopes none" "$payload"
done
pass "Claude collector adds no limit when the payload scopes none"

# The saved login carries two plan facts: the subscription and the rate-limit
# tier it runs under. Read the label off a planted credential store so the
# whole path is exercised, not just the formatter.
plan_label() {
  COLLECTOR="$ROOT/bin/omarchy-agent-usage-claude" TIER="$1" SUBSCRIPTION="$2" python3 - <<'PY'
import importlib.machinery, importlib.util, json, os, pathlib, tempfile

loader = importlib.machinery.SourceFileLoader("collector", os.environ["COLLECTOR"])
spec = importlib.util.spec_from_loader(loader.name, loader)
collector = importlib.util.module_from_spec(spec)
loader.exec_module(collector)

claude_dir = pathlib.Path(tempfile.mkdtemp())
(claude_dir / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {
  "accessToken": "token", "expiresAt": 1,
  "rateLimitTier": os.environ["TIER"], "subscriptionType": os.environ["SUBSCRIPTION"],
}}), encoding="utf-8")
print(collector.oauth_login(claude_dir)[-1])
PY
}

# A Team premium seat runs on the Max 5x rate-limit tier, and the tier alone
# used to label it "Max 5x" — the plan the seat is not on.
[[ $(plan_label default_claude_max_5x team) == "Team 5x" ]] ||
  fail "Claude collector labels a Team seat by its subscription, not its rate-limit tier" "$(plan_label default_claude_max_5x team)"
pass "Claude collector labels a Team seat by its subscription, not its rate-limit tier"

# Max keeps its multiplier, with or without a subscription type alongside the
# tier, and a plan whose tier names no multiplier is just the plan.
[[ $(plan_label default_claude_max_20x max) == "Max 20x" && $(plan_label default_claude_max_5x "") == "Max 5x" ]] ||
  fail "Claude collector still labels Max by its multiplier" "$(plan_label default_claude_max_20x max) / $(plan_label default_claude_max_5x "")"
[[ $(plan_label default_claude_pro pro) == "Pro" && $(plan_label "" team) == "Team" ]] ||
  fail "Claude collector labels a plan without a multiplier by its subscription alone" "$(plan_label default_claude_pro pro) / $(plan_label "" team)"
pass "Claude collector keeps Max multipliers and plain plan names"

# Only the Claude Code CLI refreshes the saved tokens, so between its runs the
# collector can find the access token lapsed while the refresh token behind it
# is still good. Drive collect_limits over a planted cache with the network
# unreachable, so nothing but the credential state decides the answer.
CACHE_HOME=$(mktemp -d)
trap 'rm -rf "$CACHE_HOME"' EXIT

collect_limits() {
  COLLECTOR="$ROOT/bin/omarchy-agent-usage-claude" TOKEN="$1" EXPIRES_AT="$2" \
    REFRESH_EXPIRES_AT="$3" CACHED="$4" CACHE_MTIME_OFFSET="${5:-0}" \
    XDG_CACHE_HOME="$CACHE_HOME" python3 - <<'PY'
import importlib.machinery, importlib.util, json, os, pathlib, time

loader = importlib.machinery.SourceFileLoader("collector", os.environ["COLLECTOR"])
spec = importlib.util.spec_from_loader(loader.name, loader)
collector = importlib.util.module_from_spec(spec)
loader.exec_module(collector)

cache = collector.cache_root() / "claude-limits.json"
cached = os.environ["CACHED"]
if cached:
  cache.write_text(cached, encoding="utf-8")
  offset = float(os.environ["CACHE_MTIME_OFFSET"])
  if offset:
    timestamp = time.time() + offset
    os.utime(cache, (timestamp, timestamp))
elif cache.exists():
  cache.unlink()

def unreachable(request, timeout=None):
  raise OSError("no route to host")

collector.urllib.request.urlopen = unreachable
print(json.dumps(collector.collect_limits(
  os.environ["TOKEN"],
  int(os.environ["EXPIRES_AT"]),
  int(os.environ["REFRESH_EXPIRES_AT"]),
  False,
)))
PY
}

# An open window and one that already reset, cached long enough ago that a live
# token would re-probe rather than reuse them.
open_at=$(python3 -c 'import datetime as dt; print((dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=3)).isoformat())')
past_at=$(python3 -c 'import datetime as dt; print((dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=3)).isoformat())')
cache=$(jq -nc --arg open "$open_at" --arg past "$past_at" '{
  fetchedAtMs: 1,
  limits: [
    { label: "Session (5-hour)", percent: 0.31, resetsAt: $past },
    { label: "Weekly (7-day)", percent: 0.11, resetsAt: $open }
  ]
}')

# Both tokens lapsed is a genuine sign-out. It used to return an empty limits
# list and no status at all, which hides the panel's whole limits section
# without saying why.
expired=$(collect_limits "token" 1000 1000 "$cache")
[[ $(jq -r '.usageStatusText' <<<"$expired") == "Sign-in expired" ]] ||
  fail "Claude collector reports an expired sign-in" "$expired"
[[ $(jq -r '.authHelpText' <<<"$expired") == *"claude auth login"* ]] ||
  fail "Claude collector says how to refresh an expired sign-in" "$expired"
pass "Claude collector reports an expired sign-in instead of hiding the section"

# The elapsed session resets to zero while the weekly usage stays intact.
[[ $(jq -c '[.limits[].label]' <<<"$expired") == '["Session (5-hour)","Weekly (7-day)"]' ]] ||
  fail "Claude collector keeps cached windows and resets elapsed ones" "$expired"
[[ $(jq '[.limits[].percent] == [0,0.11]' <<<"$expired") == "true" && $(jq -r '.limits[0].resetsAt' <<<"$expired") == "" ]] ||
  fail "Claude collector resets just the elapsed window" "$expired"
pass "Claude collector keeps cached windows and resets elapsed ones"

# A wholly reset cache still shows the empty allowance.
stale=$(collect_limits "token" 1000 1000 "$(jq -c '.limits |= [.[0]]' <<<"$cache")")
[[ $(jq '.limits | map(.percent) == [0]' <<<"$stale") == "true" && $(jq -r '.usageStatusText' <<<"$stale") == "Sign-in expired" ]] ||
  fail "Claude collector resets a wholly elapsed cache to zero" "$stale"
[[ $(jq -r '.authHelpText' <<<"$stale") == *"last known"* ]] ||
  fail "Claude collector keeps the timestamp and guidance for a reset cache" "$stale"
pass "Claude collector resets a wholly elapsed cache to zero"

# The access token lives about eight hours; the refresh token behind it lives
# about thirty days, and the CLI mints a new access token from it on its next
# run. A machine left overnight finds the first lapsed and the second fine --
# routine, and nothing a person fixes by signing in again.
live_refresh=$(python3 -c 'import time; print(round((time.time() + 30 * 86400) * 1000))')
paused=$(collect_limits "token" 1000 "$live_refresh" "$cache")
[[ $(jq -r '.usageStatusText' <<<"$paused") == "Limits paused" ]] ||
  fail "Claude collector calls a lapsed access token paused, not signed out" "$paused"
[[ $(jq -r '.authHelpText' <<<"$paused") != *"claude auth login"* ]] ||
  fail "Claude collector does not send a signed-in machine back through login" "$paused"
[[ $(jq -c '[.limits[].label]' <<<"$paused") == '["Session (5-hour)","Weekly (7-day)"]' ]] ||
  fail "Claude collector keeps open cached windows while the access token is stale" "$paused"
pass "Claude collector calls a lapsed access token paused, not signed out"

# A signed-out machine says so, and still shows what it last knew.
signed_out=$(collect_limits "" 0 0 "$cache")
[[ $(jq -r '.usageStatusText' <<<"$signed_out") == "Waiting for auth" ]] ||
  fail "Claude collector still reports a missing token" "$signed_out"
[[ $(jq -c '[.limits[].label]' <<<"$signed_out") == '["Session (5-hour)","Weekly (7-day)"]' ]] ||
  fail "Claude collector serves open cached windows without a token" "$signed_out"
pass "Claude collector serves open cached windows without a token"

# The limits cache is a last-known fallback governed by each window's reset
# time, not by the file's age. A backwards clock correction must not discard
# an otherwise open fallback when no token is available to replace it.
future_fallback=$(collect_limits "" 0 0 "$cache" 3600)
[[ $(jq -c '[.limits[].label]' <<<"$future_fallback") == '["Session (5-hour)","Weekly (7-day)"]' ]] ||
  fail "Claude collector keeps open fallback limits after a backwards clock correction" "$future_fallback"
pass "Claude collector keeps open fallback limits after a backwards clock correction"

# A live token that cannot reach the endpoint keeps the old contract: the open
# window stands in, and the shell is asked to retry sooner than its interval.
unreachable=$(collect_limits "token" 0 0 "$cache")
[[ $(jq -c '[.limits[].label]' <<<"$unreachable") == '["Session (5-hour)","Weekly (7-day)"]' ]] ||
  fail "Claude collector falls back to cache when the probe cannot connect" "$unreachable"
[[ $(jq -r '.retryAdvised' <<<"$unreachable") == "true" ]] ||
  fail "Claude collector advises a retry after a transport failure" "$unreachable"
pass "Claude collector falls back to cache when the probe cannot connect"

# Reuse and --force are decided against a cache that is fresh by the clock, so
# the probe is answered rather than refused: what matters is whether it ran.
probe_with_cache() {
  COLLECTOR="$ROOT/bin/omarchy-agent-usage-claude" FORCE="$1" CACHED="$2" PAYLOAD="$3" CACHE_MTIME_OFFSET="${4:-0}" \
    XDG_CACHE_HOME="$CACHE_HOME" python3 - <<'PY'
import importlib.machinery, importlib.util, io, json, os, time

loader = importlib.machinery.SourceFileLoader("collector", os.environ["COLLECTOR"])
spec = importlib.util.spec_from_loader(loader.name, loader)
collector = importlib.util.module_from_spec(spec)
loader.exec_module(collector)

cache = collector.cache_root() / "claude-limits.json"
cache.write_text(os.environ["CACHED"], encoding="utf-8")
offset = float(os.environ["CACHE_MTIME_OFFSET"])
if offset:
  timestamp = time.time() + offset
  os.utime(cache, (timestamp, timestamp))

probes = []

def urlopen(request, timeout=None):
  probes.append(1)
  return io.BytesIO(os.environ["PAYLOAD"].encode())

collector.urllib.request.urlopen = urlopen
result = collector.collect_limits("token", 0, 0, os.environ["FORCE"] == "true")
print(json.dumps({
  "result": result,
  "probes": len(probes),
  "cached": json.loads(cache.read_text(encoding="utf-8")),
}))
PY
}

fresh=$(jq -nc --arg open "$open_at" --argjson now "$(python3 -c 'import time; print(round(time.time() * 1000))')" '{
  fetchedAtMs: $now,
  limits: [{ label: "Weekly (7-day)", percent: 0.11, resetsAt: $open }]
}')
payload='{"five_hour":{"utilization":44.0}}'

# Repeated panel opens share one answer rather than one request apiece.
reused=$(probe_with_cache false "$fresh" "$payload")
[[ $(jq -r '.probes' <<<"$reused") == "0" && $(jq -c '[.result.limits[].percent]' <<<"$reused") == "[0.11]" ]] ||
  fail "Claude collector reuses a cache younger than the probe interval" "$reused"
[[ $(jq -r '.result.authHelpText' <<<"$reused") == "" ]] ||
  fail "Claude collector clears login guidance when reusing authenticated limits" "$reused"
pass "Claude collector reuses a cache younger than the probe interval"

# An early boot probe can be stamped ahead of corrected wall time when NTP
# moves the clock backwards. That cache must not suppress live probes until
# the clock catches up.
future=$(jq -nc --arg open "$open_at" --argjson future "$(python3 -c 'import time; print(round((time.time() + 3600) * 1000))')" '{
  fetchedAtMs: $future,
  limits: [{ label: "Weekly (7-day)", percent: 0.11, resetsAt: $open }]
}')

# If the clock correction makes a probe necessary but that probe cannot
# connect, the cache remains the last-known answer. Its reset time, rather than
# its future mtime, decides whether the fallback is still usable.
future_unreachable=$(collect_limits "token" 0 0 "$future" 3600)
[[ $(jq -c '[.limits[].percent]' <<<"$future_unreachable") == "[0.11]" && $(jq -r '.retryAdvised' <<<"$future_unreachable") == "true" ]] ||
  fail "Claude collector keeps future-dated fallback when the re-probe fails" "$future_unreachable"
pass "Claude collector keeps future-dated fallback when the re-probe fails"

# Numbers stamped in the future have no age to trust, so a kept fallback is
# reported as stale rather than as measured just now.
[[ $(jq -r '.live' <<<"$future_unreachable") == "false" ]] ||
  fail "Claude collector marks a future-dated fallback stale" "$future_unreachable"
pass "Claude collector marks a future-dated fallback stale"

corrected=$(probe_with_cache false "$future" "$payload" 3600)
[[ $(jq -r '.probes' <<<"$corrected") == "1" && $(jq -c '[.result.limits[].percent]' <<<"$corrected") == "[0.44]" ]] ||
  fail "Claude collector re-probes after a backwards clock correction" "$corrected"
pass "Claude collector re-probes after a backwards clock correction"

# Inside the reuse window the cache is the answer the last probe gave, credit
# window and all. Only a fallback leaves the money out.
fresh_credits=$(jq -c --arg open "$open_at" '.limits += [{
  label: "Usage credits", title: "Usage credits", percent: 0.92, resetsAt: $open,
  spend: { used: 458.2, limit: 500.0, currency: "EUR" }
}]' <<<"$fresh")
reused_credits=$(probe_with_cache false "$fresh_credits" "$payload")
[[ $(jq -r '.probes' <<<"$reused_credits") == "0" && $(jq -c '[.result.limits[].label]' <<<"$reused_credits") == '["Weekly (7-day)","Usage credits"]' ]] ||
  fail "Claude collector reuses a fresh cache with its credit window" "$reused_credits"
pass "Claude collector reuses a fresh cache with its credit window"

# --force is someone pressing refresh, and its help text promises the caches are
# ignored — so the reuse window must not outrank it.
forced=$(probe_with_cache true "$fresh" "$payload")
[[ $(jq -r '.probes' <<<"$forced") == "1" ]] ||
  fail "Claude collector re-probes on --force despite a fresh cache" "$forced"
[[ $(jq -c '[.result.limits[].percent]' <<<"$forced") == "[0.44]" ]] ||
  fail "Claude collector returns the forced probe's numbers" "$forced"
[[ $(jq -r '.result.authHelpText' <<<"$forced") == "" ]] ||
  fail "Claude collector clears login guidance after a successful probe" "$forced"
pass "Claude collector re-probes on --force despite a fresh cache"

# A probe that lands becomes the next run's fallback.
[[ $(jq -c '[.cached.limits[].percent]' <<<"$forced") == "[0.44]" ]] ||
  fail "Claude collector caches a successful probe" "$forced"
pass "Claude collector caches a successful probe"

# The monetary credit allowance rides in the same payload and is read as one
# more window: a percentage of the cap, the amounts behind it, and a reset on
# the first of the coming month.
credits=$(read_limits '{
  "five_hour": { "utilization": 0.0 },
  "spend": {
    "enabled": true,
    "used": { "amount_minor": 45820, "currency": "EUR", "exponent": 2 },
    "limit": { "amount_minor": 50000, "currency": "EUR", "exponent": 2 }
  }
}')

[[ $(jq -c '.limits[-1] | del(.resetsAt)' <<<"$credits") == '{"label":"Usage credits","title":"Usage credits","percent":0.9164,"spend":{"used":458.2,"limit":500.0,"currency":"EUR"}}' ]] ||
  fail "Claude collector reads the usage-credit allowance as a limit window" "$credits"
pass "Claude collector reads the usage-credit allowance as a limit window"

[[ $(jq -r '.limits[-1].resetsAt' <<<"$credits") == *-01T00:00:00* ]] ||
  fail "Claude collector resets the credit window on the first of the coming month" "$credits"
pass "Claude collector resets the credit window on the first of the coming month"

# Spending past the cap is possible; a meter past full is not.
over=$(read_limits '{
  "five_hour": { "utilization": 0.0 },
  "spend": {
    "enabled": true,
    "used": { "amount_minor": 60000, "currency": "EUR", "exponent": 2 },
    "limit": { "amount_minor": 50000, "currency": "EUR", "exponent": 2 }
  }
}')

[[ $(jq -c '.limits[-1].percent' <<<"$over") == "1.0" ]] ||
  fail "Claude collector holds the credit window at full when spending passes the cap" "$over"
pass "Claude collector holds the credit window at full when spending passes the cap"

# Accounts without credits: a plan that never had them says nothing at all,
# one with them switched off says so, and a prepaid ledger names credits
# rather than a cap. None of them earn a window, and none of them may cost
# the account the rate limit windows it does have.
for payload in \
  '{"five_hour":{"utilization":0.0}}' \
  '{"five_hour":{"utilization":0.0},"spend":null}' \
  '{"five_hour":{"utilization":0.0},"spend":{"enabled":false,"used":{"amount_minor":0,"currency":"USD","exponent":2},"limit":{"amount_minor":50000,"currency":"USD","exponent":2}}}' \
  '{"five_hour":{"utilization":0.0},"spend":{"enabled":true,"used":{"amount_minor":100,"currency":"USD","exponent":2},"limit":null}}' \
  '{"five_hour":{"utilization":0.0},"spend":{"enabled":true,"used":{"amount_minor":100,"currency":"USD","exponent":2},"limit":{"amount_minor":0,"currency":"USD","exponent":2}}}' \
  '{"five_hour":{"utilization":0.0},"spend":{"enabled":true,"used":{"amount_minor":100,"currency":"USD","exponent":2},"limit":{"amount_minor":50000,"currency":"EUR","exponent":2}}}' \
  '{"five_hour":{"utilization":0.0},"spend":{"enabled":true,"used":{"amount_minor":100,"currency":"USD"},"limit":{"amount_minor":50000,"currency":"USD","exponent":2}}}' \
  '{"five_hour":{"utilization":0.0},"spend":{"enabled":true,"used":{"amount_minor":"100","currency":"USD","exponent":2},"limit":{"amount_minor":50000,"currency":"USD","exponent":2}}}' \
  '{"five_hour":{"utilization":0.0},"spend":{"enabled":true,"used":{"amount_minor":NaN,"currency":"USD","exponent":2},"limit":{"amount_minor":50000,"currency":"USD","exponent":2}}}'; do
  without=$(read_limits "$payload")
  [[ $(jq -c '[.limits[].label]' <<<"$without") == '["Session (5-hour)"]' ]] ||
    fail "Claude collector adds no credit window to an account without credits" "$payload -> $without"
done
pass "Claude collector adds no credit window to an account without credits"

# A refund can carry the spend below zero. That is an empty meter, not a
# missing window: the panel drops any window whose percent reads negative.
refund=$(read_limits '{
  "five_hour": { "utilization": 0.0 },
  "spend": {
    "enabled": true,
    "used": { "amount_minor": -500, "currency": "EUR", "exponent": 2 },
    "limit": { "amount_minor": 50000, "currency": "EUR", "exponent": 2 }
  }
}')

[[ $(jq -c '.limits[-1] | [.label, .percent]' <<<"$refund") == '["Usage credits",0.0]' ]] ||
  fail "Claude collector empties the credit meter on a refund rather than dropping it" "$refund"
pass "Claude collector empties the credit meter on a refund rather than dropping it"

# A zero-decimal currency states exponent 0 and must not be read as cents.
yen=$(read_limits '{
  "five_hour": { "utilization": 0.0 },
  "spend": {
    "enabled": true,
    "used": { "amount_minor": 25000, "currency": "JPY", "exponent": 0 },
    "limit": { "amount_minor": 50000, "currency": "JPY", "exponent": 0 }
  }
}')

[[ $(jq -c '.limits[-1].spend' <<<"$yen") == '{"used":25000.0,"limit":50000.0,"currency":"JPY"}' ]] ||
  fail "Claude collector reads money in the exponent the payload states" "$yen"
pass "Claude collector reads money in the exponent the payload states"

# The money is only true at the moment it was read, and its window stands for a
# month. A refused re-check of money measured minutes ago still describes the
# account, the same as the rate limit windows. Past CURRENT_ENOUGH_SECONDS
# (900) a cache replayed for weeks would report spending the account has long
# since passed, so the credit window waits for a probe that reaches the
# endpoint while the rate limit windows still come back.
credit_cache() {
  jq -nc --arg open "$open_at" --argjson fetched "$(python3 -c \
    "import time; print(round((time.time() - $1) * 1000))")" '{
    fetchedAtMs: $fetched,
    limits: [
      { label: "Weekly (7-day)", percent: 0.11, resetsAt: $open },
      { label: "Usage credits", title: "Usage credits", percent: 0.92,
        resetsAt: $open,
        spend: { used: 458.2, limit: 500.0, currency: "EUR" } }
    ]
  }'
}

keeps='["Weekly (7-day)","Usage credits"]'
drops='["Weekly (7-day)"]'
# Token, access expiry and refresh expiry for each path that falls back, then
# the cache age in seconds and the windows that come back.
for fallback in \
  "token 1000 1000 60 keeps expired sign-in" \
  "token 1000 1000 1800 drops expired sign-in" \
  "_ 0 0 60 keeps no sign-in" \
  "_ 0 0 1800 drops no sign-in" \
  "token 0 0 60 keeps unreachable endpoint" \
  "token 0 0 890 keeps unreachable endpoint" \
  "token 0 0 910 drops unreachable endpoint" \
  "token 0 0 1800 drops unreachable endpoint"; do
  read -r token expires refresh age outcome name <<<"$fallback"
  [[ $token == "_" ]] && token=""
  expected=${!outcome}
  cached_credits=$(collect_limits "$token" "$expires" "$refresh" \
    "$(credit_cache "$age")")
  label="Claude collector $outcome cached credits ${age}s old: $name"
  [[ $(jq -c '[.limits[].label]' <<<"$cached_credits") == "$expected" ]] ||
    fail "$label" "$cached_credits"
  pass "$label"
done

# A month that ended inside the reuse interval leaves an empty credit window,
# without the money spent in the month before.
elapsed_credits=$(jq -c --arg gone "$past_at" '.limits += [{
  label: "Usage credits", title: "Usage credits", percent: 0.92,
  resetsAt: $gone, spend: { used: 458.2, limit: 500.0, currency: "EUR" }
}]' <<<"$fresh")
reused_elapsed=$(probe_with_cache false "$elapsed_credits" "$payload")
[[ $(jq -c '.result.limits[-1] | [.percent, has("spend")]' \
  <<<"$reused_elapsed") == "[0.0,false]" ]] ||
  fail "Claude collector drops the money of a credit window that has reset" \
    "$reused_elapsed"
pass "Claude collector drops the money of a credit window that has reset"

# next_month_start is a pure function of the month it is given, so its branches
# are driven directly rather than through whatever month the suite runs in.
month_start() {
  COLLECTOR="$ROOT/bin/omarchy-agent-usage-claude" WHEN="$1" TZ="${2:-UTC}" python3 - <<'PY'
import datetime as dt, importlib.machinery, importlib.util, os

loader = importlib.machinery.SourceFileLoader("collector", os.environ["COLLECTOR"])
spec = importlib.util.spec_from_loader(loader.name, loader)
collector = importlib.util.module_from_spec(spec)
loader.exec_module(collector)

print(collector.next_month_start(dt.datetime.fromisoformat(os.environ["WHEN"])))
PY
}

# Mid-month, the last day of a month, and December, which is the only month
# that has to carry the year with it. A December that rolled over to month 13
# would raise out of the collector and cost the record every other number in
# it, not just this window.
while read -r when expected; do
  [[ $(month_start "$when") == "$expected"* ]] ||
    fail "Claude collector resets credits on the first of the coming month ($when)" "$(month_start "$when")"
done <<'CASES'
2026-09-17T10:30:00 2026-10-01T00:00:00
2026-09-01T00:00:00 2026-10-01T00:00:00
2026-01-31T12:00:00 2026-02-01T00:00:00
2026-12-31T23:59:00 2027-01-01T00:00:00
2026-12-01T00:00:00 2027-01-01T00:00:00
CASES
pass "Claude collector resets credits on the first of the coming month"

# The reset can land on the far side of a daylight-saving change. Carrying
# today's offset onto it puts the countdown an hour out and closes the cached
# window an hour early.
[[ $(month_start "2026-10-15T12:00:00" "Europe/Stockholm") == "2026-11-01T00:00:00+01:00" ]] ||
  fail "Claude collector dates the credit reset in the offset of the day it lands on" \
    "$(month_start "2026-10-15T12:00:00" "Europe/Stockholm")"
pass "Claude collector dates the credit reset in the offset of the day it lands on"

# The panel reads a window out of a label, and that guess cannot survive a
# model name — "Opus 5 (1M context)" parses as a one-minute window. A collector
# that states the title outright is taken at its word.
run_node_test <<'JS'
const fs = require('fs')
const source = fs.readFileSync(root + '/shell/plugins/agents/Panel.qml', 'utf8')
const panelRoot = { nowMs: Date.now() }
const start = source.indexOf('function windowIsLong')
const end = source.indexOf('// The window that decides')
assert(start > 0 && end > start, 'agents panel exposes its limit-window helpers')
eval(source.slice(start, end).replaceAll('root.nowMs', 'panelRoot.nowMs'))
eval(source.slice(source.indexOf('function needsSignIn'), source.indexOf('// Sign an account')))

const paused = { usageStatusText: 'Limits paused', limits: [] }
assertEqual(pausedWithoutLimits(paused), true, 'paused usage without a cache shows a recovery placeholder')
assertEqual(otherTrouble(paused), '', 'paused usage never puts the confusing status in the header')
assertEqual(pausedWithoutLimits({ ...paused, limits: [{ label: 'Session (5-hour)', percent: 0, resetsAt: '' }] }), false, 'cached usage replaces the recovery placeholder')
assertEqual(pausedWithoutLimits({ usageStatusText: 'Sign-in expired', limits: [] }), false, 'expired sign-ins retain their sign-in action')
assertEqual(pausedWithoutLimits(null), false, 'missing records do not show a paused-usage placeholder')

assertDeepEqual(
  limitWindows({ limits: [
    { label: 'Session (5-hour)', percent: 0.78, resetsAt: '' },
    { label: 'Opus 5 (1M context) Weekly', title: 'Opus 5 (1M context) Weekly', percent: 0.42, resetsAt: '' }
  ] }),
  [
    { title: 'Session', percent: 0.78, resetAt: '' },
    { title: 'Opus 5 (1M context) Weekly', percent: 0.42, resetAt: '' }
  ],
  'agents panel titles a limit off the collector when it states one'
)

assertDeepEqual(
  limitWindows({ limits: [{ label: 'Weekly (7-day)', percent: 0.12, resetsAt: '' }] }),
  [{ title: 'Weekly', percent: 0.12, resetAt: '' }],
  'agents panel still reads a window out of a label that carries no title'
)

const resetAt = new Date(panelRoot.nowMs + 1000).toISOString()
const measured = { limits: [{ label: 'Session (5-hour)', percent: 0.78, resetsAt: resetAt }] }
assertEqual(limitWindows(measured)[0].percent, 0.78, 'usage remains until the reset time')
panelRoot.nowMs += 1000
assertDeepEqual(limitWindows(measured), [{ title: 'Session', percent: 0, resetAt: '' }], 'usage resets at the deadline while the panel stays open')
assertEqual(measured.limits[0].percent, 0.78, 'display reset leaves the measured record intact')

// A model's weekly allowance rides under the Weekly row; one whose window has
// no row of its own keeps a row.
assertDeepEqual(
  displayWindows({ limits: [
    { label: 'Session (5-hour)', percent: 0.94, resetsAt: '' },
    { label: 'Weekly (7-day)', percent: 0.25, resetsAt: 'w' },
    { label: 'Fable Weekly', title: 'Fable Weekly', percent: 0.09, resetsAt: 'w' },
    { label: 'Opus Monthly', title: 'Opus Monthly', percent: 0.5, resetsAt: '' }
  ] }),
  [
    { title: 'Session', percent: 0.94, resetAt: '', scoped: [] },
    { title: 'Weekly', percent: 0.25, resetAt: 'w', scoped: [{ title: 'Fable', percent: 0.09, resetAt: 'w' }] },
    { title: 'Opus Monthly', percent: 0.5, resetAt: '', scoped: [] }
  ],
  'agents panel shows a model-scoped window under the window it runs on'
)
JS

# Anthropic rate-limits its usage endpoint readily. A refused re-check of
# numbers measured minutes ago still describes the account; only older numbers
# count as stale, and either way the record says when they were measured.
rate_limited() {
  COLLECTOR="$ROOT/bin/omarchy-agent-usage-claude" FETCHED_AGO="$1" XDG_CACHE_HOME="$CACHE_HOME" python3 - <<'PY'
import datetime as dt, importlib.machinery, importlib.util, json, os, time, urllib.error

loader = importlib.machinery.SourceFileLoader("collector", os.environ["COLLECTOR"])
spec = importlib.util.spec_from_loader(loader.name, loader)
collector = importlib.util.module_from_spec(spec)
loader.exec_module(collector)

reset = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=3)).isoformat()
fetched = round((time.time() - float(os.environ["FETCHED_AGO"])) * 1000)
(collector.cache_root() / "claude-limits-rate.json").write_text(json.dumps(
  {"fetchedAtMs": fetched, "limits": [{"label": "Session (5-hour)", "percent": 0.4, "resetsAt": reset}]}))

def refused(request, timeout=None):
  raise urllib.error.HTTPError(request.full_url, 429, "Too Many Requests", {}, None)

collector.urllib.request.urlopen = refused
result = collector.collect_limits("token", int((time.time() + 3600) * 1000), 0, True, "claude-limits-rate.json")
print(json.dumps({"live": result["live"], "percent": result["limits"][0]["percent"], "fetched": result["fetchedAtMs"] == fetched}))
PY
}

[[ $(rate_limited 60) == '{"live": true, "percent": 0.4, "fetched": true}' ]] ||
  fail "a refused re-check of numbers a minute old still counts as current" "$(rate_limited 60)"
[[ $(rate_limited 1800) == '{"live": false, "percent": 0.4, "fetched": true}' ]] ||
  fail "a refused re-check of half-hour-old numbers counts as stale" "$(rate_limited 1800)"
pass "a rate-limited check only goes stale once the numbers are old"

# The faster limit checks exist to catch an account crossing its switch
# threshold. A credit allowance never switches an account, so it does not
# start them.
run_node_test <<'JS'
const fs = require('fs')
const source = fs.readFileSync(root + '/shell/plugins/agents/Main.qml', 'utf8')
const start = source.indexOf('readonly property bool nearLimit: {')
const end = source.indexOf('\n  }\n', start)
assert(start > 0 && end > start, 'agents main exposes its near-limit check')
const body = source.slice(source.indexOf('{', start) + 1, end)
const nearLimit = (limits) =>
  new Function('agents', 'dataRevision', body)([{
    record: { accounts: [{}, {}], limits }
  }], 0)

const cases = [
  [[{ percent: 0.79 }], false, 'a session under 80%'],
  [[{ percent: 0.8 }], true, 'a session at 80%'],
  [[{ percent: 0.1 }, { percent: 0.99, spend: { used: 495, limit: 500 } }],
    false, 'a full credit allowance'],
]
for (const [limits, expected, name] of cases)
  assertEqual(nearLimit(limits), expected, 'near-limit check: ' + name)
JS

# The panel formats the amounts; the collector only carries them. A window
# with no allowance behind it renders no money line at all.
run_node_test <<'JS'
const fs = require('fs')
const source = fs.readFileSync(root + '/shell/plugins/agents/Panel.qml', 'utf8')
const start = source.indexOf('function currencyPrefix')
const end = source.indexOf('// ---------------------------------------------------------------- summary')
assert(start > 0 && end > start, 'agents panel exposes its money helpers')
eval(source.slice(start, end))

assertEqual(
  spendDetailText({ used: 458.2, limit: 500, currency: 'EUR' }),
  '€458.20 / €500.00 spent',
  'agents panel writes the credit allowance as money spent of a cap'
)

assertEqual(spendDetailText(null), '', 'agents panel writes no money line for a rate limit window')

assertEqual(
  spendDetailText({ used: -5, limit: 500, currency: 'EUR' }),
  '-€5.00 / €500.00 spent',
  'agents panel writes a refund as a signed amount'
)
JS

run_node_test <<'JS'
const fs = require('fs')
const source = fs.readFileSync(root + '/shell/plugins/agents/Panel.qml', 'utf8')
const start = source.indexOf('function windowIsLong')
const end = source.indexOf('// The window that decides')
assert(start > 0 && end > start, 'agents panel exposes its limit-window helpers')
eval(source.slice(start, end))

assertDeepEqual(
  limitWindows({ limits: [{
    label: 'Usage credits', title: 'Usage credits', percent: 0.92, resetsAt: '',
    spend: { used: 458.2, limit: 500, currency: 'EUR' }
  }] }),
  [{ title: 'Usage credits', percent: 0.92, resetAt: '', spend: { used: 458.2, limit: 500, currency: 'EUR' } }],
  'agents panel carries a credit allowance through to its window'
)

// Nothing usable behind the amounts is the same as no allowance: a window
// that cannot say what it cost says nothing rather than "$0.00 / $0.00".
for (const spend of [null, {}, { used: 10 }, { used: 10, limit: 0 }]) {
  assertEqual(
    limitWindows({ limits: [{ label: 'Usage credits', percent: 0.92, resetsAt: '', spend }] })[0].spend,
    undefined,
    'agents panel drops an allowance it cannot read: ' + JSON.stringify(spend)
  )
}

assertDeepEqual(
  limitWindows({ limits: [{ label: 'Usage credits', percent: 0, resetsAt: '', spend: { used: -5, limit: 500, currency: 'EUR' } }] })[0].spend,
  { used: -5, limit: 500, currency: 'EUR' },
  'agents panel keeps the money of a refund'
)
JS

# The bar icon's alarm answers "what stops the next prompt". Credits do not:
# running them down returns the account to its rate limit windows, and the
# credit window would otherwise hold the alarm lit until the month rolled over.
run_node_test <<'JS'
const fs = require('fs')
const source = fs.readFileSync(root + '/shell/plugins/agents/Panel.qml', 'utf8')
const start = source.indexOf('function windowIsLong')
const end = source.indexOf('// ---------------------------------------------------------------- summary')
assert(start > 0 && end > start, 'agents panel exposes its window and money helpers')
const panelRoot = { nowMs: Date.now() }
eval(source.slice(start, end).replaceAll('root.nowMs', 'panelRoot.nowMs'))

const credits = {
  label: 'Usage credits', title: 'Usage credits', percent: 0.92, resetsAt: '',
  spend: { used: 458.2, limit: 500, currency: 'EUR' }
}

assertEqual(
  bindingWindow({ limits: [{ label: 'Weekly (7-day)', percent: 0.11, resetsAt: '' }, credits] }).title,
  'Weekly',
  'agents panel binds the bar to a rate limit window, not the fuller credit window'
)

assertEqual(
  bindingWindow({ limits: [credits] }),
  null,
  'agents panel binds the bar to nothing when only credits are known'
)

// Last month's money says nothing about a month that has started.
const lastMonth = new Date(panelRoot.nowMs - 1000).toISOString()
assertEqual(
  limitWindows({ limits: [{ ...credits, resetsAt: lastMonth }] })[0].spend,
  undefined,
  'agents panel drops the money of a credit window that has reset'
)
JS
