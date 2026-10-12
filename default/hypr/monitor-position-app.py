"""Graphical monitor positioning for two or more enabled screens."""

import argparse
import importlib.util
import os
from pathlib import Path
import sys
import threading

spec = importlib.util.spec_from_file_location('monitor_position', Path(__file__).with_name('monitor-position.py'))
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)


def default_pair(monitors):
  names = [m['name'] for m in monitors]
  if len(names) < 2:
    return (names[0] if names else None), None
  internal = next((name for name in names if name.startswith(('eDP-', 'LVDS-', 'DSI-'))), names[0])
  moving = next(name for name in reversed(names) if name != internal)
  return moving, internal


def display_name(monitor):
  if monitor['name'].startswith(('eDP-', 'LVDS-', 'DSI-')):
    return 'Laptop screen'
  model = monitor.get('model', '')
  return model if model and model.lower() not in ('hdmi', 'displayport', 'unknown') else 'External screen'


def current_side(moving, reference):
  width, height = backend.logical_size(moving)
  ref_width, ref_height = backend.logical_size(reference)
  x, y = moving['x'], moving['y']
  rx, ry = reference['x'], reference['y']
  if x == rx - width and y == ry:
    return 'left'
  if x == rx + ref_width and y == ry:
    return 'right'
  if x == rx and y == ry - height:
    return 'above'
  if x == rx and y == ry + ref_height:
    return 'below'
  return 'custom'


def gui(smoke_test=False):
  # Match the compact sizing of the existing Monitor Position app.
  os.environ['GDK_SCALE'] = '1'
  import gi
  gi.require_version('Gtk', '4.0')
  from gi.repository import Gtk, GLib, Gdk

  class App(Gtk.Application):
    def __init__(self):
      super().__init__(application_id='org.omarchy.MonitorPosition.Smoke' if smoke_test else 'org.omarchy.MonitorPosition')
      self.monitors = []
      self.output = None
      self.reference = None
      self.loading = False
      self.busy = False
      self.side = None
      self.preview_positions = None
      self.hitboxes = []

    def do_activate(self):
      if self.get_active_window():
        self.get_active_window().present()
        return
      self.window = Gtk.ApplicationWindow(application=self, title='Monitor Position')
      self.window.set_default_size(700, 650)
      self.window.set_resizable(False)
      self.window.connect('close-request', lambda window: self.busy)
      box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
      for edge in ('top', 'bottom', 'start', 'end'):
        getattr(box, 'set_margin_' + edge)(24)
      self.window.set_child(box)
      css = Gtk.CssProvider()
      css.load_from_data(b"""
        window { background: #111821; color: #edf3f8; font-family: Sans; }
        .app-title { font-size: 25px; font-weight: 700; }
        .muted { color: #9baab9; font-size: 13px; }
        .section-label { font-size: 13px; font-weight: 600; }
        .preview-panel { background: #19232e; border: 1px solid #334451; border-radius: 12px; padding: 14px; }
        dropdown { background: #19232e; border: 1px solid #334451; border-radius: 8px; padding: 5px; }
        dropdown button { background: transparent; border: none; box-shadow: none; }
        .direction { background: #19232e; border: 1px solid #334451; border-radius: 8px; padding: 12px 16px; font-weight: 600; }
        .direction:hover { background: #243443; }
        .direction:checked { background: #21483f; border-color: #6ce2bd; color: #a4f5db; }
        .apply { background: #6ce2bd; color: #102820; border: none; border-radius: 8px; padding: 13px 24px; font-weight: 700; }
        .apply:hover { background: #94efd1; }
        .apply:disabled { background: #243443; color: #778895; }
        .refresh { background: transparent; border: none; color: #b6c5d1; box-shadow: none; }
        .status { color: #b6c5d1; font-size: 13px; }
        .status.error { color: #ffbc82; }
        .status.success { color: #8ce7c4; }
        button:focus-visible, dropdown:focus-visible { outline: 2px solid #a4f5db; outline-offset: 2px; }
      """)
      Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
      title = Gtk.Label(label='Monitor Position', xalign=0)
      title.add_css_class('app-title')
      header = Gtk.Box(spacing=12)
      title.set_hexpand(True)
      header.append(title)
      self.close_button = Gtk.Button.new_from_icon_name('window-close-symbolic')
      self.close_button.add_css_class('refresh')
      self.close_button.set_tooltip_text('Close Monitor Position')
      self.close_button.connect('clicked', lambda button: self.window.close())
      header.append(self.close_button)
      box.append(header)
      subtitle = Gtk.Label(label='Make the screen layout match your desk.', xalign=0)
      subtitle.add_css_class('muted')
      box.append(subtitle)
      preview_panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
      preview_panel.add_css_class('preview-panel')
      preview_header = Gtk.Box(spacing=12)
      self.preview_heading = Gtk.Label(label='Current layout', xalign=0)
      self.preview_heading.add_css_class('section-label')
      self.preview_heading.set_hexpand(True)
      preview_header.append(self.preview_heading)
      self.refresh_button = Gtk.Button(label='Refresh screens')
      self.refresh_button.add_css_class('refresh')
      self.refresh_button.set_tooltip_text('Refresh after connecting or disconnecting a screen')
      self.refresh_button.connect('clicked', lambda button: self.refresh())
      preview_header.append(self.refresh_button)
      preview_panel.append(preview_header)
      self.canvas = Gtk.DrawingArea()
      self.canvas.set_content_height(185)
      self.canvas.set_hexpand(True)
      self.canvas.set_draw_func(self.draw)
      click = Gtk.GestureClick.new()
      click.connect('pressed', self.preview_clicked)
      self.canvas.add_controller(click)
      self.canvas.set_tooltip_text('Click a screen to choose which one to move')
      preview_panel.append(self.canvas)
      preview_hint = Gtk.Label(label='Green outline: screen to move. Blue outline: reference screen.', xalign=0)
      preview_hint.add_css_class('muted')
      preview_panel.append(preview_hint)
      box.append(preview_panel)
      row = Gtk.Box(spacing=16)
      box.append(row)
      self.selectors = []
      for label in ('Move this screen', 'Relative to'):
        column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        column.set_hexpand(True)
        caption = Gtk.Label(label=label, xalign=0)
        caption.add_css_class('section-label')
        column.append(caption)
        selector = Gtk.DropDown()
        selector.set_hexpand(True)
        selector.set_enable_search(True)
        selector.update_property([Gtk.AccessibleProperty.LABEL], [label])
        column.append(selector)
        self.selectors.append(selector)
        row.append(column)
      self.selectors[0].connect('notify::selected', self.output_changed)
      self.selectors[1].connect('notify::selected', self.reference_changed)
      self.position_label = Gtk.Label(xalign=0)
      self.position_label.add_css_class('muted')
      self.position_label.set_wrap(True)
      box.append(self.position_label)
      direction_label = Gtk.Label(label='Choose a position', xalign=0)
      direction_label.add_css_class('section-label')
      box.append(direction_label)
      grid = Gtk.Grid(column_spacing=10)
      grid.set_column_homogeneous(True)
      box.append(grid)
      self.buttons = []
      for index, (label, side) in enumerate((('← Left', 'left'), ('Right →', 'right'), ('↑ Above', 'above'), ('↓ Below', 'below'))):
        button = Gtk.ToggleButton(label=label)
        button.add_css_class('direction')
        button.connect('clicked', lambda button, side=side: self.select_side(side))
        self.buttons.append(button)
        grid.attach(button, index, 0, 1, 1)
      self.status = Gtk.Label(label='Choose a direction to preview the change.', xalign=0)
      self.status.add_css_class('status')
      self.status.set_wrap(True)
      self.status.set_selectable(True)
      self.status.set_size_request(-1, 36)
      box.append(self.status)
      footer = Gtk.Box(spacing=16)
      hint = Gtk.Label(label='Your layout is saved when you apply it.', xalign=0)
      hint.add_css_class('muted')
      hint.set_hexpand(True)
      hint.set_wrap(True)
      footer.append(hint)
      self.apply_button = Gtk.Button(label='Apply layout')
      self.apply_button.add_css_class('apply')
      self.apply_button.connect('clicked', lambda button: self.apply_layout())
      footer.append(self.apply_button)
      box.append(footer)
      self.refresh()
      self.window.present()
      if smoke_test:
        GLib.timeout_add(900, self.smoke_check)

    def smoke_check(self):
      assert len(self.monitors) >= 2
      assert self.output != self.reference
      assert all(button.get_sensitive() for button in self.buttons)
      self.selectors[0].set_selected(0)
      assert self.output != self.reference
      self.select_side('above')
      assert self.preview_positions is not None
      assert self.apply_button.get_sensitive()
      print(f'GUI checked: {len(self.monitors)} screens, distinct selections, valid preview and Apply enabled.', flush=True)
      self.quit()
      return False

    def labels(self, names):
      by_name = {m['name']: m for m in self.monitors}
      return [f"{display_name(by_name[name])} ({name})" for name in names]

    def refresh(self):
      if self.busy:
        return
      self.loading = True
      self.clear_side()
      try:
        self.monitors = backend.displays()
        names = [m['name'] for m in self.monitors]
        if self.output not in names:
          self.output, self.reference = default_pair(self.monitors)
        self.selectors[0].set_model(Gtk.StringList.new(self.labels(names)))
        if self.output is not None:
          self.selectors[0].set_selected(names.index(self.output))
        self.rebuild_references()
        self.set_status('Choose a direction to preview the change.' if len(names) > 1 else 'Connect and enable at least two screens.')
      except Exception as error:
        self.monitors = []
        self.output = self.reference = None
        for selector in self.selectors:
          selector.set_model(Gtk.StringList.new([]))
        self.set_status(str(error), 'error')
      finally:
        self.loading = False
        self.update_preview()

    def rebuild_references(self):
      self.reference_names = [m['name'] for m in self.monitors if m['name'] != self.output]
      if self.reference not in self.reference_names:
        self.reference = self.reference_names[0] if self.reference_names else None
      self.selectors[1].set_model(Gtk.StringList.new(self.labels(self.reference_names)))
      if self.reference is not None:
        self.selectors[1].set_selected(self.reference_names.index(self.reference))

    def output_changed(self, selector, parameter):
      if self.loading or self.busy:
        return
      index = selector.get_selected()
      if index >= len(self.monitors):
        return
      self.output = self.monitors[index]['name']
      self.clear_side()
      self.loading = True
      self.rebuild_references()
      self.loading = False
      self.update_preview()

    def reference_changed(self, selector, parameter):
      if self.loading or self.busy:
        return
      index = selector.get_selected()
      self.reference = self.reference_names[index] if index < len(self.reference_names) else None
      self.clear_side()
      self.update_preview()

    def update_preview(self):
      by_name = {m['name']: m for m in self.monitors}
      enabled = self.output in by_name and self.reference in by_name and self.output != self.reference
      for widget in self.buttons + self.selectors:
        widget.set_sensitive(enabled and not self.busy)
      self.refresh_button.set_sensitive(not self.busy)
      self.close_button.set_sensitive(not self.busy)
      if enabled:
        side = current_side(by_name[self.output], by_name[self.reference])
        self.position_label.set_text(f'{self.output} is {side} of {self.reference}.' if side != 'custom' else f'{self.output} and {self.reference} have a custom arrangement.')
      else:
        self.position_label.set_text('Choose two connected screens to position them.')
      self.apply_button.set_sensitive(enabled and not self.busy and self.preview_positions is not None and any(self.preview_positions[m['name']] != (m['x'], m['y']) for m in self.monitors))
      self.preview_heading.set_text('Preview of your new layout' if self.preview_positions else 'Current layout')
      self.canvas.queue_draw()

    def set_status(self, message, kind=None):
      self.status.set_text(message)
      for style in ('error', 'success'):
        self.status.remove_css_class(style)
      if kind:
        self.status.add_css_class(kind)

    def clear_side(self):
      self.side = None
      self.preview_positions = None
      for button in self.buttons:
        button.set_active(False)
      self.set_status('Choose a direction to preview the change.')

    def select_side(self, side):
      if self.busy:
        return
      self.side = side
      for button, candidate in zip(self.buttons, backend.SIDES):
        button.set_active(candidate == side)
      try:
        self.preview_positions = backend.arrange(self.monitors, self.output, self.reference, side)
        changed = any(self.preview_positions[m['name']] != (m['x'], m['y']) for m in self.monitors)
        self.set_status(f'{self.output} will move {side} of {self.reference}.' if changed else 'This screen is already in that position.')
      except Exception as error:
        self.preview_positions = None
        self.set_status(str(error), 'error')
      self.update_preview()

    def preview_clicked(self, gesture, presses, x, y):
      if self.busy:
        return
      for index, (left, top, width, height) in enumerate(self.hitboxes):
        if left <= x <= left + width and top <= y <= top + height:
          self.selectors[0].set_selected(index)
          return

    def draw(self, area, context, width, height):
      self.hitboxes = []
      if not self.monitors:
        return
      monitors = [dict(m, x=self.preview_positions[m['name']][0], y=self.preview_positions[m['name']][1]) for m in self.monitors] if self.preview_positions else self.monitors
      sizes = [backend.logical_size(m) for m in monitors]
      min_x = min(m['x'] for m in monitors)
      min_y = min(m['y'] for m in monitors)
      max_x = max(m['x'] + size[0] for m, size in zip(monitors, sizes))
      max_y = max(m['y'] + size[1] for m, size in zip(monitors, sizes))
      scale = min((width - 40) / max(1, max_x - min_x), (height - 40) / max(1, max_y - min_y))
      offset_x = (width - (max_x - min_x) * scale) / 2
      offset_y = (height - (max_y - min_y) * scale) / 2
      for monitor, size in zip(monitors, sizes):
        x = offset_x + (monitor['x'] - min_x) * scale
        y = offset_y + (monitor['y'] - min_y) * scale
        w, h = size[0] * scale, size[1] * scale
        self.hitboxes.append((x, y, w, h))
        moving = monitor['name'] == self.output
        reference = monitor['name'] == self.reference
        color = (0.42, 0.89, 0.74) if moving else ((0.52, 0.69, 0.95) if reference else (0.36, 0.44, 0.52))
        context.set_source_rgb(*( (0.12, 0.23, 0.22) if moving else (0.12, 0.17, 0.23) ))
        context.rectangle(x + 3, y + 3, max(1, w - 6), max(1, h - 6))
        context.fill_preserve()
        context.set_source_rgb(*color)
        context.set_line_width(2)
        context.stroke()
        context.save()
        context.rectangle(x + 8, y + 8, max(1, w - 16), max(1, h - 16))
        context.clip()
        context.select_font_face('Sans')
        context.set_font_size(min(15, max(8, w / 12)))
        label = display_name(monitor)
        while context.text_extents(label)[2] > w - 22 and len(label) > 3:
          label = label[:-2] + '…'
        text_width = context.text_extents(label)[2]
        context.move_to(x + (w - text_width) / 2, y + h / 2 - 1)
        context.show_text(label)
        context.set_source_rgb(0.64, 0.72, 0.79)
        context.set_font_size(min(11, max(7, w / 16)))
        label = monitor['name']
        text_width = context.text_extents(label)[2]
        context.move_to(x + (w - text_width) / 2, y + h / 2 + 18)
        context.show_text(label)
        context.restore()

    def apply_layout(self):
      side = self.side
      if self.busy or not self.output or not self.reference or not side or self.preview_positions is None:
        return
      output, reference = self.output, self.reference
      expected = backend.snapshot(self.monitors)
      self.busy = True
      self.set_status('Applying your layout…')
      self.apply_button.set_label('Applying…')
      self.update_preview()
      def worker():
        try:
          backend.apply(output, reference, side, expected_snapshot=expected)
          message = f'Layout saved. {output} is {side} of {reference}.'
          success = True
        except Exception as error:
          message = str(error)
          success = False
        GLib.idle_add(self.finished, message, success)
      threading.Thread(target=worker, daemon=False).start()

    def finished(self, message, success):
      self.busy = False
      self.clear_side()
      self.apply_button.set_label('Apply layout')
      self.refresh()
      self.set_status(message, 'success' if success else 'error')
      return False

  return App().run([])


def main():
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument('--set', choices=backend.SIDES)
  parser.add_argument('--toggle', action='store_true')
  parser.add_argument('--smoke-test', action='store_true', help=argparse.SUPPRESS)
  args = parser.parse_args()
  if args.set or args.toggle:
    try:
      monitors = backend.displays()
      if len(monitors) == 2:
        output, reference = default_pair(monitors)
        by_name = {m['name']: m for m in monitors}
        side = args.set or ('left' if current_side(by_name[output], by_name[reference]) == 'right' else 'right')
        backend.apply(output, reference, side)
        return 0
      # An old desktop action cannot identify a pair in a larger layout.
      # Open the selectors so the user decides which screens to move.
    except Exception as error:
      print(str(error), file=sys.stderr)
  return gui(args.smoke_test)


if __name__ == '__main__':
  sys.exit(main())
