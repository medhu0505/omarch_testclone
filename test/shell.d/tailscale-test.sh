#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const tailscale = requireFromRoot('shell/plugins/panels/tailscale/Model.js')
const panelSource = fs.readFileSync(root + '/shell/plugins/panels/tailscale/Panel.qml', 'utf8')

assert(/function toggleTailscale\(\): string \{ tailscale\.toggleTailscale\(\); return "ok" \}/.test(panelSource), 'tailscale exposes the connection toggle over IPC')

assertDeepEqual(
  tailscale.receiverStatusCommand(),
  ['systemctl', '--user', 'is-active', 'omarchy-tailscale-receive.service'],
  'tailscale asks the user manager whether the receiver is running'
)
assertDeepEqual(tailscale.receiverState(0), { active: true, available: true }, 'tailscale shows a running receiver as on')
assertDeepEqual(tailscale.receiverState(3), { active: false, available: true }, 'tailscale shows a stopped receiver as off but switchable')
assertDeepEqual(tailscale.receiverState(4), { active: false, available: false }, 'tailscale hides the switch when the receiver unit is missing')
for (const code of [1, 2, 5, 127, -1, null, undefined]) {
  assertDeepEqual(tailscale.receiverState(code), { active: false, available: false }, `tailscale hides the switch when the user manager cannot answer (${code})`)
}

assert(tailscale.receiverVisible(true, true), 'tailscale shows the receiver switch with the CLI and the unit present')
assert(!tailscale.receiverVisible(false, true), 'tailscale hides the receiver switch without the CLI even though the unit reports inactive')
assert(!tailscale.receiverVisible(true, false), 'tailscale hides the receiver switch without the unit')
assert(tailscale.canToggleReceiver(true, true, false), 'tailscale toggles an idle receiver')
assert(!tailscale.canToggleReceiver(false, true, false), 'tailscale refuses to toggle the receiver without the CLI')
assert(!tailscale.canToggleReceiver(true, false, false), 'tailscale refuses to toggle a receiver unit that is not there')
assert(!tailscale.canToggleReceiver(true, true, true), 'tailscale refuses to toggle the receiver while a toggle or status check is running')

assertDeepEqual(
  tailscale.receiverToggleCommand(false),
  ['systemctl', '--user', 'enable', '--now', 'omarchy-tailscale-receive.service'],
  'tailscale enables and starts a stopped receiver'
)
assertDeepEqual(
  tailscale.receiverToggleCommand(true),
  ['systemctl', '--user', 'disable', '--now', 'omarchy-tailscale-receive.service'],
  'tailscale stops and disables a running receiver'
)
assertEqual(tailscale.receiverPendingStatus(true), 'Turning automatic file receiving on...', 'tailscale announces the receiver turning on')
assertEqual(tailscale.receiverPendingStatus(false), 'Turning automatic file receiving off...', 'tailscale announces the receiver turning off')

assertDeepEqual(tailscale.receiverToggleResult(0, true, 'ignored', 'ignored'), { ok: true, message: 'Automatic file receiving turned on' }, 'tailscale reports the receiver turned on')
assertDeepEqual(tailscale.receiverToggleResult(0, false, '', ''), { ok: true, message: 'Automatic file receiving turned off' }, 'tailscale reports the receiver turned off')
assertDeepEqual(tailscale.receiverToggleResult(1, true, 'stdout detail', ' stderr detail\n'), { ok: false, message: 'stderr detail' }, 'tailscale prefers stderr when a receiver toggle fails')
assertDeepEqual(tailscale.receiverToggleResult(1, true, 'stdout detail\n', ' \n'), { ok: false, message: 'stdout detail' }, 'tailscale falls back to stdout when a receiver toggle fails quietly on stderr')
assertDeepEqual(tailscale.receiverToggleResult(4, false, '', ''), { ok: false, message: 'Could not change automatic file receiving' }, 'tailscale falls back to a generic receiver failure')

assertEqual(tailscale.receiverConfirmation(true, 0), '', 'tailscale accepts a receiver that started')
assertEqual(tailscale.receiverConfirmation(false, 3), '', 'tailscale accepts a receiver that stopped')
assertEqual(tailscale.receiverConfirmation(true, 3), 'Automatic file receiving did not start', 'tailscale reports a receiver start that systemd skipped')
assertEqual(tailscale.receiverConfirmation(false, 0), 'Automatic file receiving did not stop', 'tailscale reports a receiver that kept running')
for (const target of [true, false]) {
  for (const code of [1, 4, 5, null]) {
    assertEqual(tailscale.receiverConfirmation(target, code), 'Could not verify automatic file receiving', `tailscale reports an unanswered follow-up check as unverified (${target ? 'on' : 'off'}, ${code})`)
  }
}

assertDeepEqual(
  tailscale.filterIPv4(['100.64.0.1', 'fd7a:115c:a1e0::1', '192.168.1.2']),
  ['100.64.0.1'],
  'tailscale keeps only Tailscale IPv4 addresses'
)
assertDeepEqual(
  tailscale.filterIPv6(['100.64.0.1', 'fd7a:115c:a1e0::1', 'fe80::1']),
  ['fd7a:115c:a1e0::1'],
  'tailscale keeps only Tailscale IPv6 addresses'
)

assertEqual(tailscale.cleanDnsName('work.tailnet.ts.net.'), 'work.tailnet.ts.net', 'tailscale strips trailing DNS dot')
assertEqual(tailscale.displayHostName('localhost', 'work.tailnet.ts.net.'), 'work', 'tailscale falls back from localhost to short DNS name')

const status = tailscale.parseStatus(JSON.stringify({
  BackendState: 'Running',
  AuthURL: '',
  TailscaleIPs: ['100.74.97.73', 'fd7a:115c:a1e0::ff32:6149'],
  Self: {
    HostName: 'dhh-fd',
    DNSName: 'dhh-fd.tail32f559.ts.net.',
    TailscaleIPs: ['100.74.97.73'],
    UserID: 1001,
    CapMap: { 'https://tailscale.com/cap/file-sharing': null }
  },
  Peer: {
    onlineB: {
      HostName: 'zed',
      DNSName: 'zed.tail32f559.ts.net.',
      TailscaleIPs: ['100.1.1.2'],
      Online: true,
      OS: 'linux',
      ExitNodeOption: true,
      ExitNode: true,
      UserID: 1002,
      TaildropTarget: 5
    },
    offline: {
      HostName: 'offline',
      DNSName: 'offline.tail32f559.ts.net.',
      TailscaleIPs: ['100.1.1.3'],
      Online: false,
      OS: 'linux'
    },
    offlineExit: {
      HostName: 'mbu-ser9',
      DNSName: 'mbu-ser9.tail32f559.ts.net.',
      TailscaleIPs: ['100.125.28.77', 'fd7a:115c:a1e0::1037:1c4d'],
      Online: false,
      OS: 'linux',
      ExitNodeOption: true,
      ExitNode: false
    },
    onlineA: {
      HostName: 'alpha',
      DNSName: 'alpha.tail32f559.ts.net.',
      TailscaleIPs: ['100.1.1.1', 'fd7a:115c:a1e0::1901:334b'],
      Online: true,
      OS: 'macos',
      UserID: 1001,
      TaildropTarget: 1
    },
    mullvadExit: {
      HostName: 'al-tia-wg-003',
      DNSName: 'al-tia-wg-003.mullvad.ts.net.',
      TailscaleIPs: ['100.95.87.11'],
      Online: true,
      OS: 'linux',
      ExitNodeOption: true,
      ExitNode: false
    }
  }
}))

assert(status.ok && status.running, 'tailscale parses running status')
assertEqual(status.selfIp, '100.74.97.73', 'tailscale parses self IP')
assertDeepEqual(status.peers.map(peer => peer.HostName), ['alpha', 'zed'], 'tailscale filters offline and Mullvad peers and sorts online peers')
assertDeepEqual(status.peers[0].TailscaleIPv6, ['fd7a:115c:a1e0::1901:334b'], 'tailscale preserves peer IPv6 addresses for copy menu')
assert(status.peers[1].ExitNodeOption && status.peers[1].ExitNode, 'tailscale preserves exit node flags')
assertDeepEqual(status.exitNodes.map(peer => peer.HostName), ['zed'], 'tailscale lists only online tailnet exit nodes')
assert(tailscale.isMullvadPeer({ HostName: 'al-tia-wg-003', DNSName: 'al-tia-wg-003.mullvad.ts.net.' }), 'tailscale detects Mullvad status peers')

assert(status.fileSharing, 'tailscale reads Taildrop capability from the status capability map')
assertEqual(status.selfUserId, '1001', 'tailscale records the owning user of this machine')
assertDeepEqual(status.peers.map(peer => peer.UserID), ['1001', '1002'], 'tailscale records the owning user of each peer')
assert(
  tailscale.hasFileSharing({ Capabilities: ['https://tailscale.com/cap/file-sharing'] }),
  'tailscale reads Taildrop capability from the legacy capability list'
)
assert(!tailscale.hasFileSharing({ CapMap: { funnel: null } }), 'tailscale reports no Taildrop without the capability')
assertDeepEqual(status.peers.map(peer => peer.TaildropTarget), [1, 5], 'tailscale records how Tailscale grades each Taildrop target')
assert(tailscale.isTaildropTarget({ TaildropTarget: 1, UserID: '1001' }, '2002'), 'tailscale trusts an available Taildrop target')
assert(!tailscale.isTaildropTarget({ TaildropTarget: 7, UserID: '1001' }, '1001'), 'tailscale skips peers Tailscale rules out')
assert(tailscale.isTaildropTarget({ UserID: '1001' }, '1001'), 'tailscale falls back to same-owner peers without a grade')
assert(!tailscale.isTaildropTarget({ UserID: '1002' }, '1001'), 'tailscale skips other owners without a grade')

const mullvadNodes = tailscale.parseExitNodeList(`
 IP                  HOSTNAME                         COUNTRY            CITY                   STATUS
 100.65.216.13       au-adl-wg-301.mullvad.ts.net     Australia          Any                    -
 100.65.216.13       au-adl-wg-301.mullvad.ts.net     Australia          Adelaide               -
 100.70.240.117      au-bne-wg-301.mullvad.ts.net     Australia          Brisbane               -
 100.66.11.119       dk-cph-wg-001.mullvad.ts.net     Denmark            Copenhagen             -
 100.101.10.10       us-chi-wg-001.mullvad.ts.net     United States      Chicago                -
 100.102.10.10       us-nyc-wg-001.mullvad.ts.net     United States      New York               -
 100.1.2.3           office.tailnet.ts.net             Denmark            Office                 -

# To use an exit node, use tailscale set --exit-node=
`)

assertDeepEqual(
  mullvadNodes.map(node => node.DisplayName),
  ['Adelaide, Australia', 'Brisbane, Australia', 'Copenhagen, Denmark', 'Chicago, United States', 'New York, United States'],
  'tailscale parses Mullvad exit nodes and skips duplicate country rows'
)
assertEqual(mullvadNodes[2].DNSName, 'dk-cph-wg-001.mullvad.ts.net', 'tailscale preserves Mullvad hostname as exit node target')
assertDeepEqual(mullvadNodes[2].TailscaleIPs, ['100.66.11.119'], 'tailscale preserves Mullvad exit node IP')
assert(mullvadNodes.every(node => node.Mullvad === true && node.ExitNodeOption === true), 'tailscale marks Mullvad rows as exit nodes')

const mullvadRegions = tailscale.mullvadRegionOptions(mullvadNodes)
assertDeepEqual(
  mullvadRegions.map(node => node.DisplayName),
  ['Adelaide, Australia', 'Brisbane, Australia', 'Copenhagen, Denmark', 'Chicago, United States', 'New York, United States'],
  'tailscale groups Mullvad exit nodes by unique city region'
)
assertDeepEqual(
  mullvadRegions.filter(node => node.Country === 'United States').map(node => node.City),
  ['Chicago', 'New York'],
  'tailscale keeps multiple Mullvad cities within a country'
)
assertEqual(mullvadRegions[0].DNSName, 'au-adl-wg-301.mullvad.ts.net', 'tailscale uses a concrete city endpoint for grouped regions')
assertEqual(mullvadRegions[2].DNSName, 'dk-cph-wg-001.mullvad.ts.net', 'tailscale preserves first available city endpoint')

const stopped = tailscale.parseStatus(JSON.stringify({
  BackendState: 'Stopped',
  Peer: {
    online: {
      HostName: 'alpha',
      DNSName: 'alpha.tail32f559.ts.net.',
      TailscaleIPs: ['100.1.1.1'],
      Online: true,
      OS: 'macos'
    }
  }
}))

assert(stopped.ok && !stopped.running, 'tailscale parses stopped status')

const accounts = tailscale.parseAccounts(JSON.stringify([
  {
    id: 'db1b',
    nickname: 'Home',
    tailnet: 'dhh.github',
    account: 'dhh@github',
    selected: true
  },
  {
    id: '1785',
    nickname: 'Work',
    tailnet: '37signals.com',
    account: 'david@37signals.com',
    selected: false
  }
]))

assertEqual(accounts.accounts.length, 2, 'tailscale parses multiple connections')
assertEqual(accounts.selectedAccountId, 'db1b', 'tailscale records selected connection id')
assertEqual(accounts.selectedAccountLabel, 'Home', 'tailscale labels connections by nickname')
assertDeepEqual(
  accounts.accounts.map(account => account.nickname),
  ['Home', 'Work'],
  'tailscale preserves connection nicknames'
)
assertEqual(
  tailscale.accountLabel({ nickname: '', tailnet: 'tailnet.example', account: 'user@example', id: 'abcd' }),
  'tailnet.example',
  'tailscale labels connections by tailnet when nickname is missing'
)

assertDeepEqual(
  tailscale.loginPlan(true, 'https://login.tailscale.com/a/existing'),
  { authUrl: 'https://login.tailscale.com/a/existing', command: [] },
  'tailscale reuses the daemon authorization URL without replacing node identity'
)
assertDeepEqual(
  tailscale.loginPlan(true, ''),
  { authUrl: '', command: ['tailscale', 'up'] },
  'tailscale requests a login URL when the daemon has not supplied one'
)
assertDeepEqual(
  tailscale.loginPlan(false, 'https://login.tailscale.com/a/stale'),
  { authUrl: '', command: ['tailscale', 'up'] },
  'tailscale ignores stale authorization URLs outside the login state'
)

assertDeepEqual(tailscale.parseStatus('{'), { ok: false, unavailable: true, message: 'Status error', error: 'Failed to parse tailscale status' }, 'tailscale reports invalid status JSON')
assertDeepEqual(tailscale.parseAccounts('{'), { accounts: [], selectedAccountId: '', selectedAccountLabel: '' }, 'tailscale handles invalid account JSON')
JS

# The runtime half drives the real Panel and Service through QML against stub
# `systemctl`, `which`, and `tailscale`. It runs offscreen with a scrubbed
# environment: no Wayland or Hyprland socket, no session bus, and a scratch
# HOME and runtime dir, so it can neither reach the desktop nor the real user
# manager, and the panel is never opened.
#
# TS_TEST_PREVIEW=receiver|receiver-off|absent TS_TEST_SCREENSHOT=/tmp/card.png
# instead maps the disposable synthetic panel on the running compositor for
# about a second and saves only the card, with the same stubs and scratch HOME.
preview=${TS_TEST_PREVIEW:-}
if [[ -n $preview ]]; then
  [[ $preview == "receiver" || $preview == "receiver-off" || $preview == "absent" ]] || fail "TS_TEST_PREVIEW is receiver, receiver-off, or absent"
  [[ -n ${TS_TEST_SCREENSHOT:-} ]] || fail "TS_TEST_PREVIEW needs TS_TEST_SCREENSHOT"
  require_compositor "tailscale receiver preview"
fi

if ! command -v quickshell >/dev/null 2>&1; then
  pass "quickshell not installed; skipping tailscale receiver runtime test"
  exit 0
fi

stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/tailscale" "$stage/bin" "$stage/home" "$stage/runtime" "$stage/state"
chmod 700 "$stage/runtime"
ln -s "$ROOT/shell/Ui" "$stage/Ui"
ln -s "$ROOT/shell/Commons" "$stage/Commons"
cp "$SHELL_TEST_DIR/fixtures/tailscale-receiver/shell.qml" "$stage/shell.qml"
cp "$SHELL_TEST_DIR/fixtures/tailscale-receiver/KeyboardPanelMock.qml" "$stage/tailscale/KeyboardPanelMock.qml"
for file in Service.qml Model.js TailscaleIcon.qml; do
  cp "$ROOT/shell/plugins/panels/tailscale/$file" "$stage/tailscale/$file"
done
node - "$ROOT" "$stage" "$preview" <<'JS'
const fs = require('fs')
const [root, stage, preview] = process.argv.slice(2)
let source = fs.readFileSync(`${root}/shell/plugins/panels/tailscale/Panel.qml`, 'utf8')
// Expose private IDs in the disposable copy only, never in production code.
source = source.replace('  id: root', `  id: root
  property alias testService: tailscale
  property alias testKeys: keyCatcher
  property alias testReceiverRow: receiverRow
  property alias testReceiverSeparator: receiverSeparator
  property alias testReceiverSwitch: receiverSwitch
  property alias testFlick: panelFlick`)
// Offscreen has no layer-shell backend; previews keep the real card.
if (!preview) source = source.replace('  KeyboardPanel {', '  KeyboardPanelMock {')
fs.writeFileSync(`${stage}/tailscale/Panel.qml`, source)
JS

cat > "$stage/bin/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl %s\n' "$*" >> "$TS_TEST_LOG"
cd "$TS_TEST_STATE" || exit 1
case "$*" in
  "--user is-active omarchy-tailscale-receive.service")
    if [[ -f is-active-delay ]]; then sleep "$(<is-active-delay)"; fi
    if [[ -f is-active-exit ]]; then
      exit "$(<is-active-exit)"
    elif [[ -f active ]]; then
      exit 0
    else
      exit 3
    fi
    ;;
  "--user enable --now omarchy-tailscale-receive.service" | "--user disable --now omarchy-tailscale-receive.service")
    if [[ -f toggle-delay ]]; then sleep "$(<toggle-delay)"; fi
    if [[ -f toggle-stdout ]]; then cat toggle-stdout; fi
    if [[ -f toggle-stderr ]]; then cat toggle-stderr >&2; fi
    code=0
    if [[ -f toggle-exit ]]; then code=$(<toggle-exit); fi
    if (( code == 0 )); then
      if [[ $2 == "disable" ]]; then
        rm -f active
      elif [[ ! -f skip-start ]]; then
        touch active
      fi
      if [[ -f break-status-after-toggle ]]; then echo 1 > is-active-exit; fi
    fi
    exit "$code"
    ;;
  *)
    exit 1
    ;;
esac
STUB

cat > "$stage/bin/which" <<'STUB'
#!/bin/bash
printf 'which %s\n' "$*" >> "$TS_TEST_LOG"
if [[ $* == "tailscale" && -f $TS_TEST_STATE/installed ]]; then
  echo /usr/bin/tailscale
else
  exit 1
fi
STUB

cat > "$stage/bin/tailscale" <<'STUB'
#!/bin/bash
printf 'tailscale %s\n' "$*" >> "$TS_TEST_LOG"
cd "$TS_TEST_STATE" || exit 1
case "$*" in
  "status --json")
    if [[ -f status.json ]]; then
      cat status.json
    else
      printf '{"BackendState":"Running","Self":{"HostName":"fixture","TailscaleIPs":["100.64.0.1"]}}\n'
    fi
    ;;
  "switch --list --json")
    if [[ -f accounts.json ]]; then cat accounts.json; else echo "[]"; fi
    ;;
  "exit-node list")
    ;;
  *)
    exit 1
    ;;
esac
STUB
chmod +x "$stage/bin/systemctl" "$stage/bin/which" "$stage/bin/tailscale"
# PATH is only this directory, so the real systemctl and tailscale cannot be
# reached even when a stub is moved away; link just what the stubs use.
for tool in bash cat cp mv rm sleep touch; do
  ln -s "$(command -v "$tool")" "$stage/bin/$tool"
done

# Synthetic tailnet only: documentation-style names and CGNAT addresses.
cat > "$stage/state/status-full.json" <<'JSON'
{
  "BackendState": "Running",
  "Self": { "HostName": "fixture", "DNSName": "fixture.example.ts.net.", "TailscaleIPs": ["100.64.0.1"] },
  "Peer": {
    "exit": { "HostName": "exit-fixture", "DNSName": "exit-fixture.example.ts.net.", "TailscaleIPs": ["100.64.0.2"], "Online": true, "OS": "linux", "ExitNodeOption": true },
    "peer": { "HostName": "peer-fixture", "DNSName": "peer-fixture.example.ts.net.", "TailscaleIPs": ["100.64.0.3"], "Online": true, "OS": "linux" }
  }
}
JSON
printf '[{"id":"a1","nickname":"Fixture A","selected":true},{"id":"b2","nickname":"Fixture B","selected":false}]\n' > "$stage/state/accounts-two.json"
: > "$stage/calls.log"
timeout_bin=$(command -v timeout)
quickshell_bin=$(command -v quickshell)

if [[ -n $preview ]]; then
  if [[ $preview != "absent" ]]; then
    touch "$stage/state/installed"
    cp "$stage/state/status-full.json" "$stage/state/status.json"
  fi
  if [[ $preview == "receiver" ]]; then touch "$stage/state/active"; fi
  socket=${WAYLAND_DISPLAY:-wayland-0}
  [[ $socket == /* ]] || socket="$XDG_RUNTIME_DIR/$socket"
  output=$(cd "$stage" && env -i \
    HOME="$stage/home" USER=fixture LOGNAME=fixture \
    XDG_RUNTIME_DIR="$stage/runtime" XDG_CONFIG_HOME="$stage/home/.config" \
    XDG_CACHE_HOME="$stage/home/.cache" XDG_DATA_HOME="$stage/home/.local/share" \
    PATH="$stage/bin" OMARCHY_PATH="$ROOT" \
    WAYLAND_DISPLAY="$socket" QT_QPA_PLATFORM=wayland QML_XHR_ALLOW_FILE_READ=1 \
    TS_TEST_STATE="$stage/state" TS_TEST_LOG="$stage/calls.log" \
    TS_TEST_PREVIEW="$preview" TS_TEST_SCREENSHOT="$TS_TEST_SCREENSHOT" \
    "$timeout_bin" 30 "$quickshell_bin" -p "$stage" --no-color 2>&1) || fail "tailscale receiver preview exits cleanly" "$output"
  [[ $output == *"RESULT pass"* && -s $TS_TEST_SCREENSHOT ]] || fail "tailscale receiver preview saves the card" "$output"
  pass "tailscale receiver $preview preview saved to $TS_TEST_SCREENSHOT"
  exit 0
fi

output=$(cd "$stage" && env -i \
  HOME="$stage/home" USER=fixture LOGNAME=fixture \
  XDG_RUNTIME_DIR="$stage/runtime" XDG_CONFIG_HOME="$stage/home/.config" \
  XDG_CACHE_HOME="$stage/home/.cache" XDG_DATA_HOME="$stage/home/.local/share" \
  PATH="$stage/bin" OMARCHY_PATH="$ROOT" \
  QT_QPA_PLATFORM=offscreen QML_XHR_ALLOW_FILE_READ=1 \
  TS_TEST_STATE="$stage/state" TS_TEST_LOG="$stage/calls.log" \
  "$timeout_bin" 90 "$quickshell_bin" -p "$stage" --no-color 2>&1) || fail "tailscale receiver fixture exits cleanly" "$output"
[[ $output == *"RESULT pass"* ]] || fail "tailscale receiver runtime assertions pass" "$output"
if grep -Eq 'RESULT fail|ReferenceError|TypeError|Unable to assign|Binding loop|is not a function|Cannot assign' <<< "$output"; then
  fail "tailscale receiver fixture has no QML errors" "$output"
fi
unexpected=$(grep '^systemctl ' "$stage/calls.log" | grep -Ev '^systemctl --user (is-active|enable --now|disable --now) omarchy-tailscale-receive\.service$' || true)
[[ -z $unexpected ]] || fail "tailscale receiver only runs user-unit commands for its own service" "$unexpected"
pass "tailscale receiver gating, exit-code mapping, commands, busy guards, failure reporting, confirmation, refresh, accessibility, and keyboard routes work in QML"
