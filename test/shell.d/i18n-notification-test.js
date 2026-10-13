const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { execFileSync } = require('child_process')
const root = path.resolve(__dirname, '../..')
const catalog = require('../../default/i18n/zh_CN.json')
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'omarchy-i18n-'))
function stub(name, source) { fs.writeFileSync(path.join(temp, name), '#!/bin/bash\n' + source, { mode: 0o755 }) }
try {
  // Invoke helpers through the test Bash (Bash 5 is required by Omarchy).
  stub('omarchy-i18n', 'exec bash "$OMARCHY_PATH/bin/omarchy-i18n" "$@"\n')
  stub('omarchy-notification-send', 'printf "%s" "${@: -1}"\n')
  stub('omarchy-battery-status', `if [[ $1 == "--shell" ]]; then
  printf 'percentage\\t80%%\\nstate\\t%s\\nrate\\t20W\\nsize\\t52Wh\\ntime\\t%s\\nthreshold\\t80%%\\n' "$STATE" "$BATTERY_TIME"
else
  printf '%s' "$ORIGINAL_STATUS"
fi
`)
  const english = 'Battery 80%  ·  original CLI output 20W / 52Wh 2h'
  stub('date', `case "$1" in
  +%Y) echo 2026 ;;
  +%-m) echo 9 ;;
  +%-d) echo 9 ;;
  +%A) echo Wednesday ;;
  +%H:%M) echo 08:05 ;;
  +%-V) echo 37 ;;
  *) echo 'Wednesday 08:05  ·  09 September 2026  ·  Week 37' ;;
esac
`)
  for (const locale of ['zh_CN', 'en', 'zh_TW']) {
    const env = { ...process.env, PATH: temp + ':' + process.env.PATH, OMARCHY_PATH: root, OMARCHY_UI_LANGUAGE: locale, ORIGINAL_STATUS: english }
    const run = (file, extra = {}) => execFileSync('bash', [path.join(root, 'bin', file)], { env: { ...env, ...extra }, encoding: 'utf8' })
    assert.strictEqual(run('omarchy-notification-time'), locale === 'zh_CN' ? '2026年9月9日 星期三 08:05  ·  第37周' : 'Wednesday 08:05  ·  09 September 2026  ·  Week 37')
    for (const [state, time, expected] of [
      ['holding', '', '电池 80%  ·  保持在 80%  ·  20W / 52Wh'],
      ['charging', '2h', '电池 80%  ·  2h 后充满  ·   20W / 52Wh'],
      ['charging', '', '电池 80%  ·  正在充电  ·   20W / 52Wh'],
      ['discharging', '2h', '电池 80%  ·  剩余 2h  ·   20W / 52Wh'],
      ['discharging', '', '电池 80%  ·  正在放电  ·   20W / 52Wh']
    ]) assert.strictEqual(run('omarchy-notification-battery', { STATE: state, BATTERY_TIME: time }), locale === 'zh_CN' ? expected : english)
  }
  // Test only the modified notification function, never execute the privileged migration.
  const migration = fs.readFileSync(path.join(root, 'migrations/1787494718.sh'), 'utf8')
  const reportFunction = migration.match(/report_unrepairable\(\) \{[\s\S]*?\n\}/)[0]
  for (const locale of ['zh_CN', 'en', 'zh_TW']) {
    for (const key of ['notification.fido2.symlink', 'notification.fido2.not_regular']) {
      const output = execFileSync('bash', ['-c', reportFunction + '\nauthfile=/test/authfile\nreport_unrepairable "Original first sentence." "Original second sentence." "$1"', 'fixture', key], {
        env: { ...process.env, PATH: temp + ':' + process.env.PATH, OMARCHY_PATH: root, OMARCHY_UI_LANGUAGE: locale }, encoding: 'utf8'
      })
      assert.strictEqual(output, '  Original first sentence.\n  Original second sentence.\n' + (locale === 'zh_CN' ? catalog[key].replace('%1', '/test/authfile') : 'Original first sentence. Original second sentence.'))
    }
  }
  console.log('ok - migration notification function preserves terminal output and translates both body variants')
  for (const name of ['time', 'battery']) {
    const source = fs.readFileSync(path.join(root, 'bin/omarchy-notification-' + name), 'utf8')
    assert(!/\p{Script=Han}/u.test(source), 'Chinese must live in catalogs')
    assert(!source.includes('ui.' + name + '.locale'))
  }
  assert(!('ui.date.locale' in catalog)); assert(!('ui.battery.locale' in catalog))
  const arities = { 'notification.time.format': 6, 'notification.battery.holding': 4, 'notification.battery.charging_with_time': 4, 'notification.battery.charging': 3, 'notification.battery.discharging_with_time': 4, 'notification.battery.discharging': 3 }
  for (const [key, count] of Object.entries(arities)) {
    assert.deepStrictEqual([...catalog[key].matchAll(/%(\d+)/g)].map(m => Number(m[1])).sort(), Array.from({ length: count }, (_, i) => i + 1))
  }
  console.log('ok - date and all five battery states in zh_CN/en/zh_TW; template arities')
  // Exercise the real account event helpers without signing into any provider.
  const accountSource = fs.readFileSync(path.join(root, 'bin/omarchy-agent-account-add'), 'utf8')
  const eventFunctions = accountSource.match(/(?:say|finish|fail)\(\) \{[\s\S]*?\n\}/g).join('\n')
  stub('omarchy-notification-send', 'printf "notification:%s\\n" "$*"\n')
  for (const locale of ['zh_CN', 'en', 'zh_TW']) {
    const env = { ...process.env, PATH: temp + ':' + process.env.PATH, OMARCHY_PATH: root, OMARCHY_UI_LANGUAGE: locale }
    const runEvents = events => execFileSync('bash', ['-c', eventFunctions + '\nevents=$1\nname=Claude\nsay "Installing the Claude CLI…" "Installing the %1 CLI…" Claude\nfinish "Added A&B %2." "Added %1." "A&B %2"', 'fixture', events], { env, encoding: 'utf8' })
    assert.strictEqual(runEvents('false'), 'Installing the Claude CLI…\n\nAdded A&B %2.\n')
    const eventOutput = runEvents('true')
    assert(eventOutput.includes(locale === 'zh_CN' ? '@@omarchy status 正在安装 Claude CLI…' : '@@omarchy status Installing the Claude CLI…'))
    assert(eventOutput.includes(locale === 'zh_CN' ? '@@omarchy done 已添加 A&B %2。' : '@@omarchy done Added A&B %2.'))
    const rawError = 'Provider error A&B $(whoami) %2'
    let failure
    try {
      execFileSync('bash', ['-c', eventFunctions + '\nevents=true\nname=Claude\nfail "$1"', 'fixture', rawError], { env, encoding: 'utf8' })
      assert.fail('fail must return a nonzero status')
    } catch (error) { failure = error }
    assert.strictEqual(failure.status, 1)
    assert(failure.stdout.includes('@@omarchy error ' + rawError), 'provider error stays literal')
    assert(failure.stdout.includes(locale === 'zh_CN' ? '无法添加 Claude 账号' : "Couldn't add the Claude account"))
  }
  console.log('ok - account events translate templates, preserve terminal output and keep provider errors literal')

  // Simulate systemd's isolated worker environment; no real session or power action.
  stub('systemd-run', `forwarded=()
while [[ $1 == --* ]]; do
  if [[ $1 == --setenv=* ]]; then
    name=\${1#--setenv=}
    forwarded+=("$name=\${!name}")
  fi
  shift
done
exec env -i "\${forwarded[@]}" bash "$@"
`)
  stub('systemd-inhibit', 'while [[ $1 == --* ]]; do shift; done\nexec bash "$@"\n')
  stub('timeout', 'shift\nexec "$@"\n')
  for (const command of ['omarchy-state', 'omarchy-hyprland-window-close-all', 'uwsm']) stub(command, 'exit 0\n')
  stub('systemctl', 'exit "${SYSTEM_EXIT_CODE:-0}"\n')
  stub('omarchy-osd', 'printf "osd:%s\\n" "$*"\n')
  for (const locale of ['zh_CN', 'en', 'zh_TW']) {
    for (const [action, chinese, english] of [['logout', '正在退出登录', 'Logging out'], ['reboot', '正在重启', 'Rebooting'], ['shutdown', '正在关机', 'Shutting down']]) {
      const env = { ...process.env, PATH: temp + ':' + process.env.PATH, OMARCHY_PATH: root, OMARCHY_UI_LANGUAGE: locale, LANG: 'C' }
      const output = execFileSync('bash', [path.join(root, 'bin/omarchy-system'), action], { env, encoding: 'utf8' })
      assert(output.includes('-m ' + (locale === 'zh_CN' ? chinese : english)), 'worker inherits the UI override')
    }
  }
  for (const locale of ['zh_CN', 'en', 'zh_TW']) {
    const env = { ...process.env, PATH: temp + ':' + process.env.PATH, OMARCHY_PATH: root, OMARCHY_UI_LANGUAGE: locale, SYSTEM_EXIT_CODE: '17' }
    let failure
    try {
      execFileSync('bash', [path.join(root, 'bin/omarchy-system'), 'reboot', '--execute'], { env, encoding: 'utf8' })
      assert.fail('failed system action must keep its status')
    } catch (error) { failure = error }
    assert.strictEqual(failure.status, 17)
    assert(failure.stdout.includes(locale === 'zh_CN' ? '重启失败 无法完成重启，请重试。' : 'Reboot failed Could not complete reboot. Please try again.'))
  }
  console.log('ok - logout, reboot and shutdown workers retain UI locale in isolated service environments')
} finally { fs.rmSync(temp, { recursive: true, force: true }) }
