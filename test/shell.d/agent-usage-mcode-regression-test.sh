#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
require_command python3

COLLECTOR="$ROOT/bin/omarchy-agent-usage-mcode" python3 - <<'PY'
import base64, contextlib, hashlib, http.client, importlib.machinery, importlib.util
import io, json, os, tempfile, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

loader = importlib.machinery.SourceFileLoader('mcode', os.environ['COLLECTOR'])
spec = importlib.util.spec_from_loader(loader.name, loader)
c = importlib.util.module_from_spec(spec)
loader.exec_module(c)
scratch = tempfile.TemporaryDirectory()
root = Path(scratch.name)
os.environ['HOME'] = str(root / 'home')
os.environ['XDG_CACHE_HOME'] = str(root / 'cache')
for key in ('MCODE_HOME', 'MINIMAX_DATA_DIR', 'MAVIS_DATA_DIR', '__MAVIS_RUNTIME_PROFILE', '__MAVIS_ALLOW_LEGACY_RUNTIME_ENV', 'MAVIS_REGION'):
  os.environ.pop(key, None)
home = root / 'data'
os.environ['MINIMAX_DATA_DIR'] = str(home)
state = {'requests': [], 'mode': 'ok', 'payload': {'model_remains': [{
  'model_name': 'general', 'current_interval_remaining_percent': 78,
  'end_time': int((time.time() + 18000) * 1000),
  'current_weekly_remaining_percent': 88, 'weekly_end_time': int((time.time() + 604800) * 1000),
}]}}

class Handler(BaseHTTPRequestHandler):
  def log_message(self, *args): pass
  def do_POST(self): self.do_GET()
  def do_GET(self):
    state['requests'].append((self.command, self.path, dict(self.headers)))
    if self.path.startswith('/v1/api/user/info'):
      payload = {'data': {'userInfo': {'realUserID': 'fixture-user'}}}
    elif self.path.startswith('/matrix/api/v1/user/get_user_extra_info'):
      assert self.command == 'POST'
      assert self.rfile.read(int(self.headers.get('Content-Length', 0))) == b'{}'
      payload = {'workspaces': [{'workspace_type': 1, 'op_group_id': 'team'},
                                {'workspace_type': 0, 'op_group_id': 'personal'}]}
    else:
      if state['mode'] == 'redirect':
        self.send_response(302)
        self.send_header('Location', 'https://untrusted.example/stolen')
        self.end_headers()
        return
      if state['mode'] == 'failure':
        self.send_response(503)
        self.end_headers()
        return
      payload = state['payload']
    self.send_response(200)
    self.send_header('Content-Type', 'application/json')
    self.end_headers()
    self.wfile.write(json.dumps(payload).encode())

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
class FixtureHTTPS(urllib.request.HTTPSHandler):
  def https_open(self, req):
    return self.do_open(lambda host, timeout=8, **kwargs:
      http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=timeout), req)
real_build_opener = urllib.request.build_opener
c.urllib.request.build_opener = lambda *handlers: real_build_opener(FixtureHTTPS(), *handlers)

def credential(token='fixture-A', region='en', directory=None):
  directory = Path(os.path.abspath(directory or os.environ['MINIMAX_DATA_DIR']))
  (directory / 'preferences').mkdir(parents=True, exist_ok=True)
  (directory / 'preferences/mcode-region.json').write_text(json.dumps({'version': 1, 'regions': {'prod': region}}))
  auth = directory / 'auth/prod' / region / 'mcode-public'
  auth.mkdir(parents=True, exist_ok=True)
  account = base64.urlsafe_b64encode(hashlib.sha256((str(directory / 'auth') + '\0mcode-public').encode()).digest()).decode().rstrip('=')
  key = 'com.minimax.mcode.oauth.prod.' + region + '\0' + account
  (auth / 'auth.json').write_text(json.dumps({'schemaVersion': 1, 'records': {
    'unrelated': {'clientId': 'mcode-public', 'accessToken': 'wrong-account'},
    key: {'schemaVersion': 1, 'clientId': 'mcode-public', 'accessToken': token},
  }}))
  return auth / 'auth.json'

def run(*args):
  import sys
  sys.argv = ['collector', *args]
  output = io.StringIO()
  with contextlib.redirect_stdout(output): c.main()
  return json.loads(output.getvalue())

failures = 0
def check(label, function):
  global failures
  try:
    function()
    print('ok - ' + label)
  except Exception as exc:
    failures += 1
    print('not ok - ' + label + ': ' + repr(exc))

def assert_true(value): assert value
credential()
check('MiniMax honors its real data-directory override', lambda: assert_true(c.config_root() == home))
os.environ['MAVIS_DATA_DIR'] = str(root / 'other')
check('MiniMax prefers MINIMAX_DATA_DIR to MAVIS_DATA_DIR', lambda: assert_true(c.config_root() == home))
check('MiniMax selects the exact native OAuth record', lambda: assert_true(c.load_access_token() == 'fixture-A'))

def first_quota():
  record = run('--force')
  assert len(record['limits']) == 2 and record['limits'][0]['percent'] == .22
  assert record['scope'] == 'device' and record['ready']
  request = state['requests'][-1]
  assert request[0] == 'GET' and request[2]['Authorization'] == 'Bearer fixture-A'
  assert request[2]['X-Group-Id'] == 'personal'
  identity = state['requests'][-3]
  assert 'x-signature' in {key.lower() for key in identity[2]}
check('MiniMax resolves its personal billing group and fetches real HTTP quota', first_quota)

def cached():
  before = len(state['requests'])
  record = run()
  assert len(state['requests']) == before and len(record['limits']) == 2
check('MiniMax reuses recent quota without another request', cached)
def fresh():
  before = len(state['requests'])
  run('--limits-only')
  assert len(state['requests']) == before + 3
check('MiniMax limits-only bypasses the quota cache', fresh)

def stale():
  previous = run('--force')
  state['mode'] = 'failure'
  record = run('--force')
  assert record['limits'] == previous['limits'] and record['limitsStale']
  assert record['limitsFetchedAt'] == previous['limitsFetchedAt'] and record['retryAdvised']
check('MiniMax preserves dated stale limits on a same-account failure', stale)
def changed_account():
  credential('fixture-B')
  record = run('--force')
  assert record['limits'] == [] and not record.get('limitsStale')
check('MiniMax never reuses another bearer’s quota', changed_account)
state['mode'] = 'ok'
credential()
def changed_home():
  os.environ['MINIMAX_DATA_DIR'] = str(root / 'second-data')
  credential()
  state['mode'] = 'failure'
  assert run('--force')['limits'] == []
check('MiniMax isolates the quota cache by data directory', changed_home)
os.environ['MINIMAX_DATA_DIR'] = str(home)
state['mode'] = 'ok'

def wrong_region():
  (home / 'preferences/mcode-region.json').write_text('{"version":1,"regions":{"prod":"cn"}}')
  before = len(state['requests'])
  assert run('--force')['limits'] == [] and len(state['requests']) == before
check('MiniMax never borrows another region’s sign-in', wrong_region)
credential()
def missing_window():
  state['payload'] = {'model_remains': [{'model_name': 'general', 'current_interval_remaining_percent': 75}]}
  record = run('--force')
  assert record['limits'] == [{'label': '5h', 'percent': .25}]
check('MiniMax omits quota windows absent from the API', missing_window)
def legacy_counts():
  state['payload'] = {'model_remains': [{'model_name': 'general', 'current_interval_total_count': 200, 'current_interval_usage_count': 150}]}
  assert run('--force')['limits'] == [{'label': '5h', 'percent': .25}]
check('MiniMax understands the upstream legacy remaining-count fields', legacy_counts)
def redirect():
  state['mode'] = 'redirect'
  before = len(state['requests'])
  run('--force')
  assert len(state['requests']) == before + 3
  assert all('/stolen' not in req[1] for req in state['requests'])
check('MiniMax refuses credential-bearing HTTP redirects', redirect)
state['mode'] = 'ok'

def all_time():
  directory = home / 'v2/sessions/2020/01/01/old-session'
  directory.mkdir(parents=True, exist_ok=True)
  messages = [
    {'message_id': 'user', 'message': {'role': 'user', 'timestamp': 1577836800000}},
    {'message_id': 'assistant', 'message': {'role': 'assistant', 'model': 'fixture-model', 'timestamp': 1577836800000, 'usage': {'input': 10, 'output': 5}}},
    {'message_id': 'tool-turn', 'message': {'role': 'assistant', 'model': 'fixture-model', 'timestamp': 1577836800000, 'usage': {'input': 0, 'output': 0, 'cacheRead': 20}}},
  ]
  path = directory / 'messages.jsonl'
  path.write_text('\n'.join(json.dumps(message) for message in messages))
  os.utime(path, (1577836800, 1577836800))
  record = run('--force')
  assert record['totalPrompts'] == 1 and record['totalSessions'] == 1
  assert record['modelUsage']['fixture-model']['cacheReadInputTokens'] == 20
  assert record['modelUsage']['fixture-model']['inputTokens'] == 10
check('MiniMax keeps old history, user prompt counts, and cache-only turns', all_time)
def cache_unavailable():
  cache_file = root / 'not-a-directory'
  cache_file.write_text('file')
  os.environ['XDG_CACHE_HOME'] = str(cache_file)
  assert run('--force')['modelUsage']['fixture-model']['inputTokens'] == 10
check('MiniMax still reports usage when cache creation fails', cache_unavailable)
def no_credentials():
  path = credential()
  path.write_text('{"schemaVersion":1,"records":{}}')
  record = run('--force')
  assert record['limits'] == [] and record['usageStatusText'] == 'Waiting for auth'
check('MiniMax recognizes logout despite a surviving auth directory', no_credentials)
os.environ['XDG_CACHE_HOME'] = str(root / 'cache')

def lexical_symlink():
  linked = root / 'linked-data'
  linked.symlink_to(home, target_is_directory=True)
  os.environ['MINIMAX_DATA_DIR'] = str(linked)
  credential('linked-account')
  assert c.config_root() == linked and c.load_access_token() == 'linked-account'
check('MiniMax preserves the native lexical credential identity through symlinks', lexical_symlink)
os.environ['MINIMAX_DATA_DIR'] = str(home)
def inherited_region():
  credential('global-account', 'en')
  credential('china-account', 'cn')
  os.environ['MAVIS_REGION'] = 'en'
  assert c.load_access_token() == 'global-account'
check('MiniMax inherited runtime region takes precedence over saved preferences', inherited_region)
os.environ.pop('MAVIS_REGION')
def reusable_region():
  (home / 'preferences/mcode-region.json').unlink()
  state_path = home / 'auth/prod/en/mcode-public/auth-state.json'
  state_path.write_text('{"buildEnv":"prod","region":"en","status":"authenticated"}')
  assert c.load_access_token() == 'global-account'
check('MiniMax follows a sole reusable region when preferences are absent', reusable_region)

os.environ.pop('MINIMAX_DATA_DIR')
os.environ.pop('MAVIS_DATA_DIR')
os.environ['__MAVIS_RUNTIME_PROFILE'] = 'work'
check('MiniMax ignores inactive legacy profile variables', lambda: assert_true(c.config_root() == Path.home() / '.minimax'))
os.environ['__MAVIS_ALLOW_LEGACY_RUNTIME_ENV'] = '1'
check('MiniMax honors an explicitly enabled legacy runtime profile', lambda: assert_true(c.config_root() == Path.home() / '.minimax-work'))

server.shutdown()
scratch.cleanup()
raise SystemExit(bool(failures))
PY
