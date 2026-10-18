"""Exercise the actual CLI with isolated media, menus, encoders and clipboard."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import types

ROOT = Path(os.environ['ROOT'])
STUB = '''#!/usr/bin/python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['TRANSCODE_TEST'])
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'calls').open('a') as f:
  f.write(json.dumps([name, args]) + '\\n')
if name == 'file':
  print(json.loads((root / 'mimes').read_text())[args[-1]])
elif name == 'omarchy-menu-select':
  answers = json.loads((root / 'answers').read_text())
  if not answers: sys.exit(99)
  answer = answers.pop(0)
  (root / 'answers').write_text(json.dumps(answers))
  if answer is None: sys.exit(1)
  print(json.dumps(answer) if isinstance(answer, dict) else answer)
elif name in ('magick', 'ffmpeg'):
  if os.environ.get('FAIL_INPUT') in args: sys.exit(1)
  pathlib.Path(args[-1]).touch()
elif name == 'wl-copy':
  sys.stdin.read()
'''


def check(description, condition):
  assert condition, description
  print('ok - ' + description)


with tempfile.TemporaryDirectory() as tmp:
  work = Path(tmp)
  stub = work / 'bin'
  stub.mkdir()
  for name in ('file', 'omarchy-menu-select', 'magick', 'ffmpeg', 'wl-copy', 'omarchy-notification-send'):
    path = stub / name
    path.write_text(STUB)
    path.chmod(0o755)
  env = {**os.environ, 'HOME': tmp, 'OMARCHY_PATH': str(ROOT), 'TRANSCODE_TEST': tmp,
         'PATH': f'{stub}:{ROOT / "bin"}:' + os.environ['PATH']}

  def run(files, answers, *, single=None, failed=None, existing=None):
    media = work / 'media'
    if media.exists():
      import shutil
      shutil.rmtree(media)
    media.mkdir()
    paths = [str(media / name) for name, mime in files]
    for path in paths:
      Path(path).touch()
    if existing:
      (media / existing).write_text('keep existing output')
    (work / 'mimes').write_text(json.dumps(dict(zip(paths, [mime for _, mime in files]))))
    (work / 'answers').write_text(json.dumps(answers))
    (work / 'calls').write_text('')
    args = ['--batch', '--', *paths] if single is None else [paths[0], *single]
    result = subprocess.run([ROOT / 'bin/omarchy-transcode', *args], env={**env, 'FAIL_INPUT': paths[failed] if failed is not None else ''}, capture_output=True, text=True, timeout=15)
    calls = [json.loads(line) for line in (work / 'calls').read_text().splitlines()]
    menus = [args for name, args in calls if name == 'omarchy-menu-select']
    encodes = [(name, args) for name, args in calls if name in ('magick', 'ffmpeg')]
    return result, menus, encodes, calls

  heics = [('one.heic', 'image/heic'), ('two.HEIC', 'image/heic'), ('three.heic', 'image/heic')]
  r, menus, encodes, calls = run(heics, ['jpg', {'value': 'medium', 'checked': True}])
  check('checked settings convert three HEICs with just one format/resolution pair', r.returncode == 0 and len(menus) == 2 and len(encodes) == 3)
  check('both format and resolution carry over', all('2160x>' in args and args[-1].endswith('-medium.jpg') for _, args in encodes))
  check('checkbox identifies the source type', '--checkbox' in menus[1] and 'Apply to all heic files' in menus[1])

  r, menus, encodes, _ = run(heics, ['jpg', {'value': 'medium', 'checked': False}, 'png', {'value': 'low', 'checked': False}, 'jpg', 'high'])
  check('unchecked settings prompt separately and final file has no checkbox', r.returncode == 0 and len(menus) == 6 and '--checkbox' not in menus[-1] and encodes[1][1][-1].endswith('-low.png'))

  mixed = [heics[0], ('clip.mov', 'video/quicktime'), heics[1], ('second.MOV', 'video/quicktime'), ('fake.heic', 'image/png')]
  r, menus, encodes, _ = run(mixed, ['jpg', {'value': 'low', 'checked': True}, 'mp4', {'value': '720p', 'checked': True}, 'png', 'high'])
  check('interleaved pictures/videos cache separately and misleading suffixes do not share', r.returncode == 0 and len(menus) == 6 and [name for name, _ in encodes] == ['magick', 'ffmpeg', 'magick', 'ffmpeg', 'magick'])
  check('cached video settings reach ffmpeg', 'scale=-2:720' in encodes[3][1] and encodes[3][1][-1].endswith('-720p.mp4'))

  r, menus, encodes, _ = run([('one.jpg', 'image/jpeg'), ('two.JPEG', 'image/jpeg')], ['png', {'value': 'low', 'checked': True}])
  check('JPEG aliases share detected source type', r.returncode == 0 and len(menus) == 2 and len(encodes) == 2)

  r, menus, encodes, _ = run(heics, ['jpg', None])
  check('cancel stops the whole batch before encoding', r.returncode == 130 and len(menus) == 2 and not encodes)

  r, menus, encodes, calls = run(heics, ['jpg', {'value': 'medium', 'checked': True}], failed=0)
  check('encoder failure is reported, later files still reuse settings', r.returncode == 1 and len(encodes) == 3 and len(menus) == 2 and sum(name == 'wl-copy' for name, _ in calls) == 2)

  r, menus, encodes, _ = run(heics[:2], ['jpg', {'value': 'medium', 'checked': True}], existing='one-medium.jpg')
  check('batch skips existing output without overwriting it', r.returncode == 1 and len(encodes) == 1 and (work / 'media/one-medium.jpg').read_text() == 'keep existing output')

  unusual = [('a space\nand quote\' $(touch INJECTED).heic', 'image/heic'), ('--odd.heic', 'image/heic')]
  r, _, encodes, _ = run(unusual, ['jpg', {'value': 'medium', 'checked': True}])
  check('spaces, newlines, quotes and shell syntax remain literal file paths', r.returncode == 0 and len(encodes) == 2 and not (work / 'media/INJECTED').exists())

  r, menus, encodes, _ = run(heics[:1], [], single=['jpg', 'medium'])
  check('existing explicit single-file CLI stays noninteractive', r.returncode == 0 and not menus and len(encodes) == 1)
  r, menus, encodes, _ = run(heics[:1], ['png', 'low'], single=[])
  check('single-file interactive flow has no checkbox or retained batch settings', r.returncode == 0 and len(menus) == 2 and '--checkbox' not in menus[1])

  r, menus, encodes, _ = run([('notes.txt', 'text/plain'), heics[0]], ['jpg', 'low'])
  check('unsupported input reports failure without preventing supported conversions', r.returncode == 1 and len(encodes) == 1)

  r = subprocess.run([ROOT / 'bin/omarchy-transcode', '--batch'], env=env, capture_output=True)
  check('empty batch is a usage error', r.returncode == 2)

# Import the Nautilus extension against minimal GI doubles, then inspect what
# it actually launches rather than matching the source text.
gi = types.ModuleType('gi')
gi.require_version = lambda *args: None
repository = types.ModuleType('gi.repository')
launched = []
repository.GObject = types.SimpleNamespace(GObject=type('GObject', (), {}))
repository.Nautilus = types.SimpleNamespace(MenuProvider=type('MenuProvider', (), {}))
repository.Gio = types.SimpleNamespace(Subprocess=types.SimpleNamespace(new=lambda args, flags: launched.append(args)), SubprocessFlags=types.SimpleNamespace(NONE=0))
sys.modules['gi'] = gi
sys.modules['gi.repository'] = repository
spec = importlib.util.spec_from_file_location('transcode_extension', ROOT / 'default/nautilus-python/extensions/transcode.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.shutil.which = lambda cmd: '/test/' + cmd
paths = ['/tmp/a space.heic', "/tmp/quote'$(touch nope).HEIC", '/tmp/new\nline.heic']
module.TranscodeAction()._launch_transcode(paths)
check('Files launches exactly one batch with safely quoted paths', len(launched) == 1 and shlex.split(launched[0][1]) == ['/test/omarchy-transcode', '--batch', '--', *paths])
