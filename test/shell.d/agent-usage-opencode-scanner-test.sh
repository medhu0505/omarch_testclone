#!/bin/bash

# The OpenCode collector's local stats: pi, omp and opencode usage on the Zen
# and Go providers only, with the thinking suffix stripped from model names.
# How pi and opencode stores are read (roots, forks, both opencode stores,
# OPENCODE_DB, untrusted values) is held centrally by the shared and
# partition tests, the unused-machine record by the partition test, and the
# scan cache by the contract check. The limits are agent-usage-opencode-limits-test.sh's.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$SHELL_TEST_DIR/agent-usage-helpers.sh"

agent_sandbox

python3 - <<'PY'
from agent_usage_fixtures import *


def opencode(*args):
  with FakeHttp():
    return collect("opencode", *(args or ("--force",)))


def sessions():
  return home() / ".pi" / "agent" / "sessions"


# ------------------------------------------------------------- pi and omp

# pi and omp can spend an OpenCode subscription without opencode's CLI ever
# running, so its own database cannot be the only source. A custom
# "opencode-local" gateway is somewhere else, and a user line is no reply.
sandbox()
write_pi_session(sessions() / "project" / "pi.jsonl", [
  pi_reply("opencode", id="pi-1", model="deepseek-v4.1-flash:high", usage={"input": 100, "output": 10, "reasoning": 5, "cacheRead": 20, "cacheWrite": 3}),
  pi_reply("opencode-local", id="pi-2", model="gpt-nope", usage={"input": 999, "output": 999}),
  {"type": "message", "id": "pi-3", "timestamp": iso_in(0), "message": {"role": "user", "provider": "opencode", "model": "deepseek-v4.1-flash", "usage": {"input": 999, "output": 999}}},
])
write_pi_session(home() / ".omp" / "agent" / "sessions" / "project" / "omp.jsonl", [
  pi_reply("opencode-go", id="omp-1", model="minimax-m3", usage={"input": 50, "output": 4, "reasoning": 1, "cacheRead": 5, "cacheWrite": 0}),
  pi_reply("openai-codex", id="other-1", model="gpt-nope", usage={"input": 999, "output": 999}),
])
record = opencode()
expect("OpenCode counts its Zen and Go usage from pi and omp, folding reasoning into output and stripping the thinking suffix", {
  "name": record["name"], "today": record["todayTotalTokens"], "models": record["modelUsage"],
}, {
  "name": "OpenCode", "today": 198, "models": {
    "deepseek-v4.1-flash": {"inputTokens": 100, "outputTokens": 15, "cacheReadInputTokens": 20, "cacheCreationInputTokens": 3},
    "minimax-m3": {"inputTokens": 50, "outputTokens": 5, "cacheReadInputTokens": 5, "cacheCreationInputTokens": 0},
  },
}, record)

# ---------------------------------------------------------------- opencode

# A subscription burned entirely through opencode has no pi session files;
# usage comes from opencode's own database, filtered to its providers.
sandbox()
db = opencode_db(tables=("message",), message=[
  ("msg_1", "ses_1", oc_v1("opencode", {"input": 80, "output": 40, "reasoning": 5, "cache": {"read": 30, "write": 0}}, model="deepseek-v4-flash")),
  ("msg_2", "ses_1", oc_v1("opencode-go", {"input": 10, "output": 2}, model="minimax-m3")),
  ("msg_3", "ses_1", oc_v1("anthropic", {"input": 999, "output": 999}, model="claude-opus-5")),
  ("msg_7", "ses_1", oc_v1("openai", {"input": 999, "output": 999}, model="gpt-5.5")),
  ("msg_4", "ses_1", oc_v1("opencode-local", {"input": 999, "output": 999}, model="gpt-nope")),
  ("msg_5", "ses_1", oc_v1("opencode", {"input": 999, "output": 999}, model="deepseek-v4-flash", role="user")),
  ("msg_6", "ses_1", '["not","an","object"]'),
])
record = opencode()
expect("OpenCode counts opencode's own rows on its providers, leaving Anthropic, OpenAI, look-alike gateways, prompts and malformed rows out", {
  "today": record["todayTotalTokens"], "sessions": record["totalSessions"], "models": record["modelUsage"],
}, {
  "today": 167, "sessions": 1, "models": {
    "deepseek-v4-flash": {"inputTokens": 80, "outputTokens": 45, "cacheReadInputTokens": 30, "cacheCreationInputTokens": 0},
    "minimax-m3": {"inputTokens": 10, "outputTokens": 2, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0},
  },
}, record)

# A V1 fork, and a V1 fork migrated into V2, copy their source's messages
# under new ids with the original creation times and no fork mark.
V1FORK_HOME=$(mktemp -d)
trap 'rm -rf "$PI_HOME" "$NOID_HOME" "$OPENCODE_HOME" "$CACHE_HOME" "$SESSION_HOME" "$V2_HOME" "$V1FORK_HOME"' EXIT
python3 - "$V1FORK_HOME/.local/share/opencode/opencode.db" <<'PY'
import json
import sqlite3
import sys
import time
from pathlib import Path

db = Path(sys.argv[1])
db.parent.mkdir(parents=True, exist_ok=True)
conn = sqlite3.connect(db)
conn.execute("CREATE TABLE session (id text PRIMARY KEY, parent_id text, time_created integer NOT NULL, time_updated integer NOT NULL)")
conn.execute("CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)")
conn.execute("CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL, time_created integer NOT NULL, data text NOT NULL)")
conn.execute("CREATE TABLE session_v2 (id text PRIMARY KEY, fork_session_id text, time_created integer NOT NULL)")
now_ms = int(time.time() * 1000)

def data(input, created):
  return json.dumps({
    "role": "assistant", "providerID": "opencode-go", "modelID": "kimi-k3",
    "tokens": {"input": input, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
    "time": {"created": created},
  })

def v2data(input, created):
  return json.dumps({
    "model": {"providerID": "opencode-go", "id": "kimi-k3"},
    "tokens": {"input": input, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
    "time": {"created": created},
  })

# ses_a ran two turns; ses_b forked it, copying both, then ran one of its own.
conn.executemany("INSERT INTO session VALUES (?, NULL, ?, ?)", [("ses_a", now_ms - 9000, now_ms), ("ses_b", now_ms - 3000, now_ms)])
for id, session, input, created in [
  ("msg_a1", "ses_a", 100, now_ms - 8000), ("msg_a2", "ses_a", 10, now_ms - 7000),
  ("msg_b1", "ses_b", 100, now_ms - 8000), ("msg_b2", "ses_b", 10, now_ms - 7000),
  ("msg_b3", "ses_b", 1, now_ms - 2000),
]:
  conn.execute("INSERT INTO message VALUES (?, ?, ?, ?, ?)", (id, session, created, created, data(input, created)))
# ses_c was such a fork, migrated into V2 without a fork mark.
conn.execute("INSERT INTO session_v2 VALUES ('ses_c', NULL, ?)", (now_ms - 3000,))
for id, input, created in [("msg_c1", 100, now_ms - 8000), ("msg_c2", 1000, now_ms - 2000)]:
  conn.execute("INSERT INTO session_message VALUES (?, 'ses_c', 'assistant', ?, ?)", (id, created, v2data(input, created)))
conn.commit()
conn.close()
PY

result=$(HOME="$V1FORK_HOME" XDG_CACHE_HOME="$V1FORK_HOME/.cache" XDG_DATA_HOME="$V1FORK_HOME/.local/share" \
  "$ROOT/bin/omarchy-agent-usage-opencode")
[[ $(jq -r '.todayTotalTokens' <<<"$result") == 1111 ]] ||
  fail "OpenCode collector leaves out the copies V1 and migrated forks make" "$result"
pass "OpenCode collector leaves out the copies V1 and migrated forks make"

# Valid JSON with a nested field of the wrong shape (a numeric time, a list of
# tokens or of cache counts, a list for a pi message or its usage) costs that
# field or that row, never the record.
sandbox()
write_pi_session(sessions() / "project" / "pi.jsonl", [
  {"type": "message", "id": "pi-odd", "timestamp": iso_in(0), "message": ["provider", "opencode"]},
  {"type": "message", "id": "pi-usage", "timestamp": iso_in(0), "message": {"role": "assistant", "provider": "opencode", "model": "kimi-k3", "usage": [1, 2]}},
])
odd_db = data_home() / "opencode" / "opencode.db"
odd_db.parent.mkdir(parents=True)
conn = sqlite3.connect(odd_db)
conn.execute("CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, data text NOT NULL)")
conn.executemany("INSERT INTO message VALUES (?, 'ses_odd', ?)", [(row_id, json.dumps(data)) for row_id, data in (
  ("odd_time", {"role": "assistant", "providerID": "opencode", "modelID": "kimi-k3", "tokens": {"input": 40, "output": 0}, "time": 12345}),
  ("odd_tokens", {"role": "assistant", "providerID": "opencode", "modelID": "kimi-k3", "tokens": [1, 2], "time": {"created": ms_in(0)}}),
  ("odd_cache", {"role": "assistant", "providerID": "opencode", "modelID": "kimi-k3", "tokens": {"input": 2, "cache": [9]}, "time": {"created": ms_in(0)}}),
)])
conn.commit()
conn.close()
record = opencode()
expect("OpenCode survives malformed nested fields", [record["totalPrompts"], record["modelUsage"]["kimi-k3"]["inputTokens"]], [2, 42], record)

# ---------------------------------------------------------------- contract

sandbox()


def add_reply():
  add_reply.count = getattr(add_reply, "count", 0) + 1
  write_pi_session(sessions() / "grown" / f"{add_reply.count}.jsonl", [pi_reply("opencode-go", 5, id=f"grown-{add_reply.count}")])


check_scan_cache(Adapter("opencode", grow=add_reply, pi_root=sessions))
PY
