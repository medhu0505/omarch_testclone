"""Geometry, Lua preservation and transaction regressions for monitor positioning."""

import copy
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('position', ROOT / 'default/hypr/monitor-position.py')
position = importlib.util.module_from_spec(spec)
spec.loader.exec_module(position)
app_spec = importlib.util.spec_from_file_location('position_app', ROOT / 'default/hypr/monitor-position-app.py')
app = importlib.util.module_from_spec(app_spec)
app_spec.loader.exec_module(app)


def monitor(name, x=0, y=0, width=1920, height=1080, scale=1, transform=0, **extra):
  return dict(name=name, x=x, y=y, width=width, height=height, scale=scale, transform=transform, **extra)


def evaluate(contents):
  # Execute the actual Lua with a rule-merging stub matching hl.monitor. Comparing
  # evaluated rules catches lost expressions, options, and malformed generated Lua.
  script = '''local rules = {}
  hl = { env = function() end, monitor = function(rule)
    local previous = rules[rule.output] or {}
    for key, value in pairs(rule) do previous[key] = value end
    rules[rule.output] = previous
  end }
  ''' + contents + '''
  for name, rule in pairs(rules) do
    for key, value in pairs(rule) do
      if type(value) ~= "table" then print(name .. "\\t" .. key .. "\\t" .. tostring(value)) end
    end
  end
  '''
  result = subprocess.run(['lua5.1', '-'], input=script, capture_output=True, text=True, check=True)
  return dict((tuple(line.split('\t')[:2]), line.split('\t')[2]) for line in result.stdout.splitlines())


class GeometryTests(unittest.TestCase):
  def test_multiple_desktop_screens_and_nonzero_anchor(self):
    screens = [monitor('DP-1', 100, 200), monitor('DP-2', 2020, 200), monitor('DP-3', 3940, 200)]
    result = position.arrange(screens, 'DP-3', 'DP-2', 'below')
    self.assertEqual(result, {'DP-1': (100, 200), 'DP-2': (2020, 200), 'DP-3': (2020, 1280)})

  def test_scaled_rotated_screen_and_negative_positions(self):
    anchor = monitor('eDP-1', -100, -200, 3840, 2160, 2)
    moving = monitor('DP-1', 1820, -200, 2560, 1440, 1.25, 1)
    expected = {'left': (-1252, -200), 'right': (1820, -200),
                'above': (-100, -2248), 'below': (-100, 880)}
    for side, coordinates in expected.items():
      with self.subTest(side=side):
        self.assertEqual(position.arrange([anchor, moving], 'DP-1', 'eDP-1', side)['DP-1'], coordinates)

  def test_overlap_with_third_screen_rejected(self):
    screens = [monitor('DP-1'), monitor('DP-2', 1920), monitor('DP-3', 3840)]
    with self.assertRaisesRegex(RuntimeError, 'overlap DP-2 and DP-3'):
      position.arrange(screens, 'DP-3', 'DP-1', 'right')

  def test_missing_or_same_screen_rejected(self):
    for output, reference in [('DP-1', 'DP-1'), ('DP-2', 'DP-1')]:
      with self.assertRaises(RuntimeError):
        position.arrange([monitor('DP-1')], output, reference, 'left')

  def test_invalid_scale_rejected(self):
    for scale in (0, -1, float('nan'), float('inf')):
      with self.assertRaises(RuntimeError):
        position.logical_size(monitor('DP-1', scale=scale))


class ConfigTests(unittest.TestCase):
  def test_multiline_rules_comments_nested_fields_and_missing_position(self):
    original = '''-- hl.monitor({output="DP-1", scale=99})
local example = "hl.monitor({output='DP-1'})"
hl.monitor({
  output = 'DP-1', mode = '2560x1440@144', scale = 1.25,
  transform = 1, vrr = 2, reserved_area = {top=12, bottom=3}
  -- preserve this comment
})
hl.monitor({output='DP-2', scale=2, position='auto'})
'''
    screens = [monitor('DP-1'), monitor('DP-2', 1920)]
    updated = position.update_config(original, screens, {'DP-1': (-1920, 0), 'DP-2': (0, 0)})
    before, after = evaluate(original), evaluate(updated)
    for key, value in before.items():
      if key[1] != 'position':
        self.assertEqual(after[key], value)
    self.assertEqual(after['DP-1', 'position'], '-1920x0')
    self.assertIn('-- preserve this comment', updated)
    self.assertEqual(position.update_config(updated, screens, {'DP-1': (-1920, 0), 'DP-2': (0, 0)}), updated)

  def test_generic_rules_preserve_expressions_and_merged_options(self):
    original = '''local omarchy_monitor_scale = 1.6
hl.monitor({output="", mode="preferred", scale=omarchy_monitor_scale, transform=3, vrr=2})
hl.monitor({output="", bitdepth=10})
'''
    screens = [monitor('DP-1'), monitor('DP-2', 1920)]
    locations = {'DP-1': (0, 0), 'DP-2': (1920, 0)}
    updated = position.update_config(original, screens, locations)
    values = evaluate(updated)
    for name in locations:
      for field in ('mode', 'scale', 'transform', 'vrr', 'bitdepth'):
        self.assertEqual(values[name, field], values['', field])
    self.assertIn('scale=omarchy_monitor_scale', updated)
    self.assertEqual(position.update_config(updated, screens, locations), updated)

  def test_fallback_copies_keep_the_value_at_the_original_declaration(self):
    original = 'local value=1\nhl.monitor({output="",scale=value,vrr=value})\nvalue=2\nlocal value=3\n'
    updated = position.update_config(original, [monitor('DP-1')], {'DP-1': (0, 0)})
    values = evaluate(updated)
    self.assertEqual(values['DP-1', 'scale'], '1')
    self.assertEqual(values['DP-1', 'vrr'], '1')

  def test_fallback_computed_settings_are_not_evaluated_again(self):
    for expression in ('choose_scale()', 'settings.scale', 'value - 1', 'value + 1', 'next_vrr "argument"', 'next_vrr {}', 'value % 2', 'value or 1'):
      original = 'hl.monitor({output="",scale=' + expression + '})\n'
      with self.subTest(expression=expression), self.assertRaisesRegex(RuntimeError, 'computed scale'):
        position.update_config(original, [monitor('DP-1')], {'DP-1': (0, 0)})

  def test_description_rule_gets_independent_connector_rule(self):
    original = 'hl.monitor({output="desc:Acme", scale=2, transform=1})\n'
    screens = [monitor('DP-1', description='Acme screen')]
    updated = position.update_config(original, screens, {'DP-1': (-1080, 0)})
    values = evaluate(updated)
    self.assertEqual(values['DP-1', 'scale'], '2')
    self.assertEqual(values['DP-1', 'position'], '-1080x0')
    self.assertIn(original.strip(), updated)

  def test_repeated_explicit_rules_keep_merged_settings(self):
    original = 'hl.monitor({output="DP-1", scale=2, position="auto"})\nhl.monitor({output="DP-1", vrr=1})\n'
    updated = position.update_config(original, [monitor('DP-1')], {'DP-1': (100, -900)})
    self.assertEqual(evaluate(updated)['DP-1', 'position'], '100x-900')
    self.assertEqual(evaluate(updated)['DP-1', 'scale'], '2')

  def test_long_comments_and_strings_do_not_become_rules(self):
    original = '''--[=[ hl.monitor(dynamic) ]=]
local text = [==[ hl.monitor(dynamic) ]==]
hl.monitor({output="",scale=1})
'''
    self.assertEqual(len(position.monitor_rules(original)), 1)

  def test_expression_context_calls_are_rejected(self):
    for original in ('local unused = hl.monitor({output="",scale=1}) or true',
                     'local unused =\n hl.monitor({output="",scale=1})',
                     'consume(\n hl.monitor({output="",scale=1}))'):
      with self.subTest(original=original), self.assertRaisesRegex(RuntimeError, 'standalone'):
        position.monitor_rules(original)

  def test_dynamic_and_ambiguous_rules_rejected(self):
    for contents in ('hl.monitor(rule)', 'if true then hl.monitor({output="DP-1"}) end',
                     'hl.monitor({output=connector})', 'hl.monitor({["output"]="DP-1"})'):
      with self.subTest(contents=contents), self.assertRaises(RuntimeError):
        position.monitor_rules(contents)
    with self.assertRaisesRegex(RuntimeError, 'Ambiguous'):
      position.update_config('hl.monitor({output="desc:A"})\nhl.monitor({output="desc:Acme"})',
                             [monitor('DP-1', description='Acme')], {'DP-1': (0, 0)})


class AppSelectionTests(unittest.TestCase):
  def test_laptop_with_multiple_external_screens_defaults_to_distinct_pair(self):
    self.assertEqual(app.default_pair([monitor('eDP-1'), monitor('DP-1'), monitor('DP-2')]), ('DP-2', 'eDP-1'))

  def test_desktop_only_and_dsi_internal_defaults(self):
    self.assertEqual(app.default_pair([monitor('DP-1'), monitor('DP-2'), monitor('HDMI-A-1')]), ('HDMI-A-1', 'DP-1'))
    self.assertEqual(app.default_pair([monitor('DSI-1'), monitor('DP-1')]), ('DP-1', 'DSI-1'))

  def test_zero_or_one_screen_has_no_reference(self):
    self.assertEqual(app.default_pair([]), (None, None))
    self.assertEqual(app.default_pair([monitor('DP-1')]), ('DP-1', None))

  def test_current_side_accounts_for_scaled_rotated_geometry(self):
    anchor = monitor('DP-1', 100, 200, 3840, 2160, 2)
    moving = monitor('DP-2', -980, 200, 1920, 1080, 1, 1)
    self.assertEqual(app.current_side(moving, anchor), 'left')
    moving['x'], moving['y'] = 100, -1720
    self.assertEqual(app.current_side(moving, anchor), 'above')

  def test_custom_layout_is_not_mislabelled_as_aligned(self):
    self.assertEqual(app.current_side(monitor('DP-2', 1920, 100), monitor('DP-1')), 'custom')


class TransactionTests(unittest.TestCase):
  def setUp(self):
    self.temp = tempfile.TemporaryDirectory()
    self.addCleanup(self.temp.cleanup)
    self.config_home = Path(self.temp.name)
    self.config = self.config_home / 'hypr/monitors.lua'
    self.config.parent.mkdir()
    self.original = 'hl.monitor({output="",scale=1})\n'
    self.config.write_text(self.original)
    self.config.chmod(0o640)
    self.screens = [monitor('DP-1'), monitor('DP-2', 1920)]
    self.environment = patch.dict(os.environ, {'XDG_CONFIG_HOME': str(self.config_home)})
    self.environment.start()
    self.addCleanup(self.environment.stop)

  def run_apply(self, **kwargs):
    return position.apply('DP-2', 'DP-1', 'left', **kwargs)

  def test_success_backup_and_permissions(self):
    with patch.object(position, 'displays', return_value=self.screens), patch.object(position, 'hypr', return_value=''), patch.object(position, 'wait_layout'):
      self.run_apply()
    self.assertEqual(self.config.with_name('monitors.lua.bak.monitor-position').read_text(), self.original)
    self.assertEqual(self.config.stat().st_mode & 0o777, 0o640)
    self.assertEqual(evaluate(self.config.read_text())['DP-2', 'position'], '-1920x0')

  def test_reload_failure_rolls_back_and_checks_layout(self):
    calls = []
    def fake_hypr(*args):
      calls.append(args)
      if args == ('reload',) and calls.count(args) == 1:
        raise RuntimeError('reload failed')
      return ''
    with patch.object(position, 'displays', return_value=self.screens), patch.object(position, 'hypr', side_effect=fake_hypr), patch.object(position, 'wait_layout') as wait:
      with self.assertRaisesRegex(RuntimeError, 'previous configuration and layout were restored'):
        self.run_apply()
      wait.assert_called_once_with(self.screens, {'DP-1': (0, 0), 'DP-2': (1920, 0)})
    self.assertEqual(self.config.read_text(), self.original)

  def test_config_errors_and_hotplug_leave_config_untouched(self):
    with patch.object(position, 'displays', return_value=self.screens), patch.object(position, 'hypr', return_value='existing error'):
      with self.assertRaisesRegex(RuntimeError, 'existing'):
        self.run_apply()
    with patch.object(position, 'displays', side_effect=[self.screens, self.screens[:1]]), patch.object(position, 'hypr', return_value=''):
      with self.assertRaisesRegex(RuntimeError, 'changed'):
        self.run_apply()
    self.assertEqual(self.config.read_text(), self.original)

  def test_stale_gui_preview_does_not_change_configuration(self):
    changed = copy.deepcopy(self.screens)
    changed[0]['x'] = 100
    with patch.object(position, 'displays', return_value=changed), patch.object(position, 'hypr') as hypr:
      with self.assertRaisesRegex(RuntimeError, 'changed since the preview'):
        self.run_apply(expected_snapshot=position.snapshot(self.screens))
      hypr.assert_not_called()
    self.assertEqual(self.config.read_text(), self.original)
    self.assertFalse(self.config.with_name('monitors.lua.bak.monitor-position').exists())

  def test_external_edit_during_backup_is_not_overwritten(self):
    original_write = position.atomic_write
    def edit_during_backup(path, contents):
      original_write(path, contents)
      if path.name == 'monitors.lua.bak.monitor-position':
        self.config.write_text('-- user edit during backup\n')
    with patch.object(position, 'displays', return_value=self.screens), patch.object(position, 'hypr', return_value=''), patch.object(position, 'atomic_write', side_effect=edit_during_backup):
      with self.assertRaisesRegex(RuntimeError, 'changed while creating'):
        self.run_apply()
    self.assertEqual(self.config.read_text(), '-- user edit during backup\n')

  def test_external_edit_during_apply_is_not_overwritten(self):
    def external_edit(*args):
      self.config.write_text('-- user edit\n')
      raise RuntimeError('apply failed')
    with patch.object(position, 'displays', return_value=self.screens), patch.object(position, 'hypr', return_value=''), patch.object(position, 'wait_layout', side_effect=external_edit):
      with self.assertRaisesRegex(RuntimeError, 'restore .* manually'):
        self.run_apply()
    self.assertEqual(self.config.read_text(), '-- user edit\n')

  def test_dry_run_leaves_config_and_backup_untouched(self):
    with patch.object(position, 'displays', return_value=self.screens), patch.object(position, 'hypr') as hypr, patch('builtins.print'):
      self.run_apply(dry_run=True)
      hypr.assert_not_called()
    self.assertEqual(self.config.read_text(), self.original)
    self.assertFalse(self.config.with_name('monitors.lua.bak.monitor-position').exists())

  def test_symlink_preserved(self):
    target = self.config_home / 'actual.lua'
    self.config.rename(target)
    self.config.symlink_to(target)
    with patch.object(position, 'displays', return_value=self.screens), patch.object(position, 'hypr', return_value=''), patch.object(position, 'wait_layout'):
      self.run_apply()
    self.assertTrue(self.config.is_symlink())
    self.assertEqual(evaluate(target.read_text())['DP-2', 'position'], '-1920x0')

  def test_wait_checks_all_outputs_modes_and_config_errors(self):
    moved = copy.deepcopy(self.screens)
    moved[1]['x'] = -1920
    with patch.object(position, 'hypr', return_value=''), patch.object(position, 'displays', side_effect=[self.screens, moved]), patch.object(position.time, 'sleep'):
      position.wait_layout(self.screens, {'DP-1': (0, 0), 'DP-2': (-1920, 0)})
    with patch.object(position, 'hypr', return_value='config error'):
      with self.assertRaisesRegex(RuntimeError, 'config error'):
        position.wait_layout(self.screens, {'DP-1': (0, 0), 'DP-2': (-1920, 0)})


if __name__ == '__main__':
  unittest.main()
