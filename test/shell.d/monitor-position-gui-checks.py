"""Exercise the actual GTK controls with an isolated display service."""

import copy
import importlib.util
from pathlib import Path
import threading
import time
import unittest

import gi
gi.require_version('Gtk', '4.0')
from gi.repository import Gio, GLib, Gtk

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('position_app', ROOT / 'default/hypr/monitor-position-app.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

SCREENS = [
  dict(name='eDP-1', x=0, y=0, width=1920, height=1080, scale=1),
  dict(name='DP-1', x=1920, y=0, width=1920, height=1080, scale=1),
  dict(name='DP-2', x=3840, y=0, width=1920, height=1080, scale=1),
]


class DisplayService:
  SIDES = module.backend.SIDES
  logical_size = staticmethod(module.backend.logical_size)
  snapshot = staticmethod(module.backend.snapshot)
  arrange = staticmethod(module.backend.arrange)

  def __init__(self):
    self.screens = copy.deepcopy(SCREENS)
    self.apply_requests = []
    self.query_gate = None
    self.query_started = threading.Event()
    self.query_finished = threading.Event()
    self.query_error = None
    self.apply_gate = None
    self.apply_started = threading.Event()
    self.apply_error = None

  def displays(self):
    self.query_started.set()
    try:
      if self.query_gate is not None and not self.query_gate.wait(0.6):
        raise RuntimeError('Test display service did not answer')
      if self.query_error:
        raise RuntimeError(self.query_error)
      return copy.deepcopy(self.screens)
    finally:
      self.query_finished.set()

  def apply(self, output, reference, side, expected_snapshot=None):
    self.apply_requests.append((output, reference, side, expected_snapshot))
    self.apply_started.set()
    if self.apply_gate is not None and not self.apply_gate.wait(2):
      raise RuntimeError('Test apply service did not answer')
    if self.apply_error:
      raise RuntimeError(self.apply_error)
    if expected_snapshot != self.snapshot(self.screens):
      raise RuntimeError('The screens changed since the preview')
    if (output, reference, side) != ('DP-2', 'eDP-1', 'left'):
      raise RuntimeError('Unexpected test arrangement')
    self.screens[2]['x'] = -1920


def widgets(root):
  yield root
  child = root.get_first_child()
  while child is not None:
    yield from widgets(child)
    child = child.get_next_sibling()


def wait_until(predicate, timeout=3):
  context = GLib.MainContext.default()
  deadline = time.monotonic() + timeout
  while time.monotonic() < deadline:
    while context.pending():
      context.iteration(False)
    if predicate():
      return
    time.sleep(0.005)
  raise AssertionError('Timed out waiting for GTK state')


class GuiTests(unittest.TestCase):
  def setUp(self):
    self.service = DisplayService()
    self.app = None

  def tearDown(self):
    for gate in (self.service.query_gate, self.service.apply_gate):
      if gate is not None:
        gate.set()
    if self.app is not None and self.app.get_is_registered():
      # Let a pending worker finish before disposing of its GTK controls.
      wait_until(lambda: self.button('Refresh screens').get_sensitive())
      self.app.window.close()
      self.app.quit()
      while GLib.MainContext.default().pending():
        GLib.MainContext.default().iteration(False)

  def open_app(self, ready=True):
    self.app = module.create_application(display_backend=self.service)
    self.app.set_application_id('org.omarchy.MonitorPosition.Tests.' + self._testMethodName)
    self.app.set_flags(Gio.ApplicationFlags.NON_UNIQUE)
    self.app.register(None)
    self.app.activate()
    self.app.window.set_visible(False)
    if ready:
      wait_until(lambda: self.button('Refresh screens').get_sensitive())

  def button(self, label):
    return next(w for w in widgets(self.app.window) if isinstance(w, Gtk.Button) and w.get_label() == label)

  def selectors(self):
    return [w for w in widgets(self.app.window) if isinstance(w, Gtk.DropDown)]

  def text_contains(self, text):
    return any(isinstance(w, Gtk.Label) and text in w.get_text() for w in widgets(self.app.window))

  def click(self, label):
    self.button(label).emit('clicked')

  def test_window_remains_responsive_while_initial_query_is_delayed(self):
    self.service.query_gate = threading.Event()
    started = time.monotonic()
    self.open_app(ready=False)
    self.assertLess(time.monotonic() - started, 0.25, 'A delayed display query must not block opening the window')
    pulse = threading.Event()
    GLib.idle_add(lambda: pulse.set() or False)
    wait_until(pulse.is_set, timeout=0.25)
    self.assertFalse(self.service.query_gate.is_set())
    self.assertFalse(self.button('Apply layout').get_sensitive())
    self.service.query_gate.set()
    wait_until(lambda: self.button('Refresh screens').get_sensitive())
    self.assertTrue(all(selector.get_sensitive() for selector in self.selectors()))

  def test_preview_and_selector_changes_do_not_apply_a_layout(self):
    self.open_app()
    self.click('← Left')
    self.assertTrue(self.text_contains('Preview of your new layout'))
    self.assertTrue(self.button('Apply layout').get_sensitive())
    self.assertEqual(self.service.apply_requests, [])
    self.assertEqual(self.service.screens, SCREENS)
    moving, reference = self.selectors()
    moving.set_selected(0)
    self.assertNotEqual(moving.get_selected_item().get_string(), reference.get_selected_item().get_string())
    self.assertFalse(self.button('Apply layout').get_sensitive())
    self.assertTrue(self.text_contains('Current layout'))
    self.assertEqual(self.service.apply_requests, [])

  def test_apply_success_disables_inputs_then_restores_saved_layout_controls(self):
    self.open_app()
    self.service.apply_gate = threading.Event()
    self.click('← Left')
    apply_button = self.button('Apply layout')
    apply_button.emit('clicked')
    wait_until(self.service.apply_started.is_set)
    self.assertEqual(apply_button.get_label(), 'Applying…')
    self.assertFalse(self.button('Refresh screens').get_sensitive())
    self.assertTrue(all(not selector.get_sensitive() for selector in self.selectors()))
    self.assertTrue(all(not self.button(label).get_sensitive() for label in ('← Left', 'Right →', '↑ Above', '↓ Below')))
    self.service.apply_gate.set()
    wait_until(lambda: self.text_contains('Layout saved.'))
    self.assertTrue(self.text_contains('DP-2 is left of eDP-1.'))
    self.assertEqual(self.service.screens[2]['x'], -1920)
    self.assertTrue(self.button('Refresh screens').get_sensitive())
    self.assertTrue(all(selector.get_sensitive() for selector in self.selectors()))
    self.assertEqual(apply_button.get_label(), 'Apply layout')
    self.assertFalse(apply_button.get_sensitive())

  def test_failed_apply_shows_error_and_allows_a_successful_retry(self):
    self.open_app()
    self.service.apply_error = 'Test apply failed'
    self.click('← Left')
    self.click('Apply layout')
    wait_until(lambda: self.text_contains('Test apply failed'))
    self.assertEqual(self.service.screens, SCREENS)
    self.assertTrue(self.button('Refresh screens').get_sensitive())
    self.assertTrue(all(selector.get_sensitive() for selector in self.selectors()))
    self.assertTrue(self.button('← Left').get_sensitive())
    self.assertFalse(self.button('Apply layout').get_sensitive())
    self.service.apply_error = None
    self.click('← Left')
    self.assertTrue(self.button('Apply layout').get_sensitive())
    self.click('Apply layout')
    wait_until(lambda: self.text_contains('Layout saved.'))
    self.assertEqual(self.service.screens[2]['x'], -1920)

  def test_delayed_refresh_remains_responsive_and_handles_disconnection(self):
    self.open_app()
    self.service.query_gate = threading.Event()
    self.service.query_started.clear()
    started = time.monotonic()
    self.click('Refresh screens')
    self.assertLess(time.monotonic() - started, 0.2)
    pulse = threading.Event()
    GLib.idle_add(lambda: pulse.set() or False)
    wait_until(pulse.is_set, timeout=0.2)
    self.assertTrue(self.service.query_started.is_set())
    self.assertTrue(all(not selector.get_sensitive() for selector in self.selectors()))
    self.assertFalse(self.button('Refresh screens').get_sensitive())
    self.service.screens = copy.deepcopy(SCREENS[:2])
    self.service.query_gate.set()
    wait_until(lambda: self.button('Refresh screens').get_sensitive())
    moving, reference = self.selectors()
    self.assertEqual(moving.get_selected_item().get_string(), 'External screen (DP-1)')
    self.assertEqual(reference.get_selected_item().get_string(), 'Laptop screen (eDP-1)')
    self.assertTrue(all(selector.get_sensitive() for selector in self.selectors()))

  def test_refresh_error_leaves_refresh_available_for_recovery(self):
    self.open_app()
    self.service.query_error = 'Displays temporarily unavailable'
    self.click('Refresh screens')
    wait_until(lambda: self.text_contains('Displays temporarily unavailable'))
    self.assertTrue(self.button('Refresh screens').get_sensitive())
    self.assertTrue(all(not selector.get_sensitive() for selector in self.selectors()))
    self.assertFalse(self.button('Apply layout').get_sensitive())
    self.service.query_error = None
    self.click('Refresh screens')
    wait_until(lambda: self.button('Refresh screens').get_sensitive())
    self.assertTrue(all(selector.get_sensitive() for selector in self.selectors()))
    self.assertFalse(self.text_contains('Displays temporarily unavailable'))

  def test_window_can_close_while_query_is_pending(self):
    self.service.query_gate = threading.Event()
    self.open_app(ready=False)
    window = self.app.window
    window.close()
    self.assertEqual(self.app.get_windows(), [])
    self.service.query_gate.set()
    wait_until(self.service.query_finished.is_set)
    self.assertEqual(self.service.apply_requests, [])
    self.app.quit()
    self.app = None

  def test_refresh_failure_after_apply_keeps_the_apply_result_visible(self):
    self.open_app()
    self.click('← Left')
    self.service.query_error = 'Cannot read displays'
    self.click('Apply layout')
    wait_until(lambda: self.text_contains('Could not refresh screens: Cannot read displays'))
    self.assertTrue(self.text_contains('Layout saved.'))
    self.assertEqual(self.service.screens[2]['x'], -1920)
    self.assertTrue(self.button('Refresh screens').get_sensitive())
    self.service.query_error = None
    self.click('Refresh screens')
    wait_until(lambda: self.button('Refresh screens').get_sensitive())
    self.assertTrue(all(selector.get_sensitive() for selector in self.selectors()))
    self.assertTrue(self.text_contains('DP-2 is left of eDP-1.'))

  def test_changed_screens_reject_the_preview_without_applying(self):
    self.open_app()
    self.click('← Left')
    self.service.screens[1]['y'] = 100
    self.click('Apply layout')
    wait_until(lambda: self.text_contains('The screens changed since the preview'))
    self.assertEqual(self.service.screens[2]['x'], 3840)
    self.assertEqual(self.service.screens[1]['y'], 100)
    self.assertTrue(all(selector.get_sensitive() for selector in self.selectors()))
    self.assertTrue(self.button('← Left').get_sensitive())


if __name__ == '__main__':
  unittest.main()
