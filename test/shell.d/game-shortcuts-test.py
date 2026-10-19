import importlib.util
import fcntl
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("shortcuts", ROOT / "default/games/shortcuts.py")
shortcuts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shortcuts)


def write(path, value):
  path.parent.mkdir(parents=True, exist_ok=True)
  path.write_text(value if isinstance(value, str) else json.dumps(value))


def appinfo(path, version, apps):
  names = ["appinfo", "common", "type", "name"]

  def name(value):
    return struct.pack("<I", names.index(value)) if version == 0x29 else value.encode() + b"\0"

  records = b""
  for appid, kind in apps.items():
    body = b"\0" + name("appinfo") + b"\0" + name("common")
    body += b"\x01" + name("type") + kind.encode() + b"\0\x08\x08\x08"
    header = bytes(40 if version == 0x27 else 60)
    records += struct.pack("<II", appid, len(header + body)) + header + body
  records += bytes(4)
  header = struct.pack("<II", 0x07564400 + version, 1)
  table = b""
  if version == 0x29:
    header += struct.pack("<Q", 16 + len(records))
    table = struct.pack("<I", len(names)) + b"".join(value.encode() + b"\0" for value in names)
  path.parent.mkdir(parents=True, exist_ok=True)
  path.write_bytes(header + records + table)


class GameShortcutsTest(unittest.TestCase):
  def setUp(self):
    self.temporary = tempfile.TemporaryDirectory()
    self.addCleanup(self.temporary.cleanup)
    self.home = Path(self.temporary.name)
    self.data = self.home / "custom data"
    self.config = self.home / "custom config"
    self.app_dir = self.data / "applications"
    self.app_dir.mkdir(parents=True)
    self.state = self.home / "state.json"
    self.steam = self.data / "Steam"
    self.heroic = self.config / "heroic"
    self.game = ("Hades", "steam://rungameid/1145360", "steam_icon_1145360")

  def sync(self, games=None, present=None, complete=None):
    shortcuts.synchronize(self.app_dir, [self.app_dir], self.state,
                          games if games is not None else {"steam:1145360": self.game},
                          present if present is not None else {"steam:1145360"},
                          complete if complete is not None else {"steam"})

  def generated(self):
    return list(self.app_dir.glob("omarchy-game-*.desktop"))

  def manifest(self, root, appid, name, flags=4):
    write(root / f"steamapps/appmanifest_{appid}.acf", f'"AppState" {{ "appid" "{appid}" "name" "{name}" "StateFlags" "{flags}" "installdir" "{appid}" }}')
    (root / f"steamapps/common/{appid}").mkdir(parents=True, exist_ok=True)

  def test_steam_cache_versions_and_actual_game_types(self):
    external = self.home / "other disk/SteamLibrary"
    write(self.steam / "steamapps/libraryfolders.vdf", f'"libraryfolders" {{ "0" {{ "path" "{self.steam}" }} "1" {{ "path" "{external}" }} }}')
    types = {1145360: "Game", 1493710: "Tool", 100: "DLC", 101: "Demo", 102: "Mod", 103: "Game", 104: "Game"}
    for appid in types:
      self.manifest(external if appid == 101 else self.steam, appid, str(appid), 1 if appid == 104 else 4)
    (self.steam / "steamapps/common/103").rmdir()
    for version in (0x27, 0x28, 0x29):
      with self.subTest(version=version):
        appinfo(self.steam / "appcache/appinfo.vdf", version, types)
        games, present, complete = shortcuts.steam_games(self.home, self.data)
        self.assertEqual(set(games), {"steam:1145360", "steam:101", "steam:102"})
        self.assertIn("steam:104", present)
        self.assertEqual(complete, {"steam"})
    # Missing external media never authorizes cleanup; neither does a partial cache.
    (external / "steamapps").rename(external / "offline")
    self.assertEqual(shortcuts.steam_games(self.home, self.data)[2], set())
    (self.steam / "appcache/appinfo.vdf").write_bytes(b"partial")
    self.assertEqual(shortcuts.steam_games(self.home, self.data)[2], set())

  def test_flatpak_steam_and_aliases_deduplicate(self):
    flatpak = self.home / ".var/app/com.valvesoftware.Steam/data/Steam"
    write(flatpak / "steamapps/libraryfolders.vdf", '"libraryfolders" {}')
    self.manifest(flatpak, 1145360, "Hades")
    appinfo(flatpak / "appcache/appinfo.vdf", 0x29, {1145360: "Game"})
    (self.home / ".steam").mkdir()
    (self.home / ".steam/root").symlink_to(flatpak, target_is_directory=True)
    self.assertEqual(len(shortcuts.steam_games(self.home, self.data)[0]), 1)

  def test_heroic_stores_join_only_installed_games(self):
    install = self.home / "games/one"
    install.mkdir(parents=True)
    write(self.heroic / "legendaryConfig/legendary/installed.json", {
      "Epic App & 1": {"title": "Epic game", "install_path": str(install)},
      "dlc": {"title": "Extra", "install_path": str(install), "is_dlc": True}})
    write(self.heroic / "store_cache/legendary_library.json", {"library": [{"app_name": "Epic App & 1", "title": "Epic game", "art_square": "https://example.org/icon"}]})
    icon = self.heroic / "images-cache" / shortcuts.hashlib.sha256(b"https://example.org/icon?h=400&resize=1&w=300").hexdigest()
    write(icon, "local icon")
    write(self.heroic / "gog_store/installed.json", {"installed": [{"appName": "42", "install_path": str(install)}]})
    write(self.heroic / "store_cache/gog_library.json", {"games": [{"app_name": "42", "title": "GOG game"}, {"app_name": "43", "title": "Not installed"}]})
    write(self.heroic / "nile_config/nile/installed.json", [{"id": "amazon", "path": str(install)}])
    write(self.heroic / "store_cache/nile_library.json", {"library": [{"app_name": "amazon", "title": "Amazon game"}]})
    games, present, complete = shortcuts.heroic_games(self.home, self.config)
    self.assertEqual(set(games), {"heroic:legendary:Epic App & 1", "heroic:gog:42", "heroic:nile:amazon"})
    self.assertEqual(complete, {"heroic:legendary", "heroic:gog", "heroic:nile"})
    self.assertEqual(games["heroic:legendary:Epic App & 1"][2], str(icon))
    url = games["heroic:legendary:Epic App & 1"][1]
    self.assertEqual(shortcuts.launch_identity("xdg-open " + url), "heroic:legendary:Epic App & 1")
    write(self.heroic / "store_cache/gog_library.json", "invalid")
    self.assertIn("heroic:gog:42", shortcuts.heroic_games(self.home, self.config)[1])
    self.assertNotIn("heroic:gog", shortcuts.heroic_games(self.home, self.config)[2])

  def test_flatpak_heroic(self):
    root = self.home / ".var/app/com.heroicgameslauncher.hgl/config/heroic"
    write(root / "legendaryConfig/legendary/installed.json", {"game": {"title": "Game", "install_path": str(self.home)}})
    self.assertIn("heroic:legendary:game", shortcuts.heroic_games(self.home, self.config)[0])

  def test_idempotence_updates_and_uninstall_cleanup(self):
    self.sync()
    path = self.generated()[0]
    self.assertIn("StartupWMClass=steam_app_1145360", path.read_text())
    first = path.stat().st_mtime_ns
    self.sync()
    self.assertEqual(path.stat().st_mtime_ns, first)
    self.sync({"steam:1145360": ("New title", self.game[1], "new-icon")})
    self.assertIn("Name=New title", path.read_text())
    self.sync({}, set(), set())
    self.assertTrue(path.exists())
    self.sync({}, set(), {"steam"})
    self.assertFalse(path.exists())

  def test_removed_and_edited_entries_are_never_recreated_or_deleted(self):
    self.sync()
    path = self.generated()[0]
    path.unlink()
    self.sync()
    self.assertEqual(self.generated(), [])
    self.sync({}, set(), {"steam"})
    self.sync()
    self.assertEqual(self.generated(), [])
    self.state.unlink()
    self.sync()
    path = self.generated()[0]
    path.write_text("user edit")
    self.sync()
    self.sync({}, set(), {"steam"})
    self.assertEqual(path.read_text(), "user edit")

  def test_client_shortcut_prevents_duplicates_and_respects_removal(self):
    client = self.app_dir / "Hades.desktop"
    write(client, "[Desktop Entry]\nExec=steam steam://rungameid/1145360\nHidden=true\n")
    self.sync()
    self.assertEqual(self.generated(), [])
    client.unlink()
    self.sync()
    self.assertEqual(self.generated(), [])

  def test_client_shortcut_does_not_suppress_a_later_reinstall(self):
    client = self.app_dir / "Hades.desktop"
    write(client, "[Desktop Entry]\nExec=steam -applaunch 1145360\n")
    self.sync()
    client.unlink()
    self.sync({}, set(), {"steam"})
    self.sync()
    self.assertEqual(len(self.generated()), 1)

  def test_later_client_shortcut_keeps_the_imported_id_as_a_hidden_alias(self):
    self.sync()
    path = self.generated()[0]
    write(self.app_dir / "Hades.desktop", "[Desktop Entry]\nExec=steam -applaunch 1145360\n")
    self.sync()
    self.assertTrue(path.exists(), "previously pinned desktop IDs must still resolve")
    self.assertIn("NoDisplay=true", path.read_text())
    self.assertTrue((self.app_dir / "Hades.desktop").exists())
    self.sync({}, set(), {"steam"})
    self.assertFalse(path.exists(), "only an uninstall removes the imported alias")

  def test_failed_state_write_recovers_shortcut_ownership(self):
    write_atomic = shortcuts.atomic_write

    def fail_state(path, text):
      if path == self.state:
        raise OSError("interrupted state write")
      write_atomic(path, text)

    for update in (False, True):
      with self.subTest(update=update):
        if update:
          self.sync()
        with patch.object(shortcuts, "atomic_write", side_effect=fail_state):
          with self.assertRaises(OSError):
            self.sync({"steam:1145360": ("Updated Hades", *self.game[1:])})
        path = self.generated()[0]
        self.sync()
        self.assertIn("Name=Hades", path.read_text())
        self.sync({}, set(), {"steam"})
        self.assertFalse(path.exists(), "a recovered file must still be cleaned up")

  def test_recovery_never_claims_an_edited_shortcut(self):
    self.sync()
    path = self.generated()[0]
    path.write_text(path.read_text().replace("Name=Hades", "Name=My Hades"))
    self.state.unlink()
    self.sync({}, set(), {"steam"})
    self.assertIn("Name=My Hades", path.read_text())

  def test_interrupted_cleanup_does_not_suppress_a_reinstall(self):
    self.sync()
    path = self.generated()[0]
    write_atomic = shortcuts.atomic_write

    def fail_final_state(target, text):
      if target == self.state and not path.exists():
        raise OSError("interrupted cleanup after unlink")
      write_atomic(target, text)

    with patch.object(shortcuts, "atomic_write", side_effect=fail_final_state):
      with self.assertRaises(OSError):
        self.sync({}, set(), {"steam"})
    self.assertFalse(path.exists())
    self.assertTrue(shortcuts.read_json(self.state)["entries"]["steam:1145360"]["cleanup"])
    self.sync()  # Reinstall immediately, without an intervening cleanup run.
    self.assertEqual(len(self.generated()), 1)
    self.sync({}, set(), {"steam"})
    self.assertFalse(path.exists(), "recovered imports retain cleanup ownership")

  def test_failed_cleanup_journal_leaves_shortcut_intact(self):
    self.sync()
    path = self.generated()[0]
    before = path.read_bytes()
    with patch.object(shortcuts, "atomic_write", side_effect=OSError("unwritable state")):
      with self.assertRaises(OSError):
        self.sync({}, set(), {"steam"})
    self.assertEqual(path.read_bytes(), before)
    self.sync()
    self.assertEqual(len(self.generated()), 1)

  def test_pending_cleanup_before_unlink_preserves_edits(self):
    for edited in (False, True):
      with self.subTest(edited=edited):
        self.state.unlink(missing_ok=True)
        self.sync()
        path = self.generated()[0]
        original_unlink = Path.unlink

        def fail_unlink(target, *args, **kwargs):
          if target == path:
            raise OSError("interrupted before unlink")
          return original_unlink(target, *args, **kwargs)

        with patch.object(Path, "unlink", fail_unlink):
          with self.assertRaises(OSError):
            self.sync({}, set(), {"steam"})
        self.assertTrue(shortcuts.read_json(self.state)["entries"]["steam:1145360"]["cleanup"])
        if edited:
          path.write_text("user edit after interrupted cleanup")
        self.sync()
        if edited:
          self.sync({}, set(), {"steam"})
          self.assertEqual(path.read_text(), "user edit after interrupted cleanup")
        else:
          self.assertIn("Name=Hades", path.read_text())

  def test_missing_shortcut_is_suppressed_before_uninstall_cleanup(self):
    self.sync()
    self.generated()[0].unlink()
    self.sync({}, set(), {"steam"})
    self.sync()
    self.assertEqual(self.generated(), [])

  def test_failed_removal_state_write_does_not_delete_shortcut(self):
    self.sync()
    path = self.generated()[0]
    with patch.object(shortcuts, "atomic_write", side_effect=OSError("unwritable state")):
      with self.assertRaises(OSError):
        shortcuts.remove_shortcut(self.app_dir, self.state, path.name)
    self.assertTrue(path.exists())
    self.sync()
    self.assertEqual(len(self.generated()), 1)

  def test_interrupted_explicit_removal_is_completed_without_touching_edits(self):
    for edited in (False, True):
      with self.subTest(edited=edited):
        self.state.unlink(missing_ok=True)
        self.sync()
        path = self.generated()[0]
        original_unlink = Path.unlink

        def fail_unlink(target, *args, **kwargs):
          if target == path:
            raise OSError("interrupted removal")
          return original_unlink(target, *args, **kwargs)

        with patch.object(Path, "unlink", fail_unlink):
          with self.assertRaises(OSError):
            shortcuts.remove_shortcut(self.app_dir, self.state, path.name)
        if edited:
          path.write_text("new user edit")
        self.sync({}, set(), {"steam"})
        self.sync()
        if edited:
          self.assertEqual(path.read_text(), "new user edit")
        else:
          self.assertFalse(path.exists())

  def test_launcher_removal_survives_uninstall_before_discovery(self):
    self.sync()
    path = self.generated()[0]
    state_dir = self.home / "custom state/omarchy"
    state_dir.mkdir(parents=True)
    self.state.rename(state_dir / "game-shortcuts.json")
    self.state = state_dir / "game-shortcuts.json"
    env = dict(os.environ, HOME=str(self.home), OMARCHY_PATH=str(ROOT), XDG_DATA_HOME=str(self.data),
               XDG_STATE_HOME=str(state_dir.parent), XDG_DATA_DIRS=str(self.home / "system"))
    subprocess.run([str(ROOT / "bin/omarchy-remove-launcher-entry"), path.stem, "Hades"], env=env, check=True, capture_output=True)
    self.assertFalse(path.exists())
    self.sync({}, set(), {"steam"})
    self.sync()
    self.assertEqual(self.generated(), [], "explicit removal must survive uninstall before the next discovery")

  def test_command_recovers_orphans_even_with_no_installed_games(self):
    key = "heroic:legendary:epic"
    path = self.app_dir / shortcuts.shortcut_filename(key)
    write(path, shortcuts.shortcut_text(key, ("Epic game", "heroic://launch?appName=epic&runner=legendary", "heroic")))
    write(self.heroic / "legendaryConfig/legendary/installed.json", {})
    env = dict(os.environ, HOME=str(self.home), OMARCHY_PATH=str(ROOT), XDG_DATA_HOME=str(self.data),
               XDG_CONFIG_HOME=str(self.config), XDG_STATE_HOME=str(self.home / "custom state"), XDG_DATA_DIRS=str(self.home / "system"))
    subprocess.run([str(ROOT / "bin/omarchy-refresh-game-shortcuts")], env=env, check=True, capture_output=True)
    self.assertFalse(path.exists(), "orphan ownership is recovered before the no-games fast path")

  def test_exec_field_codes_and_escaping(self):
    key = "heroic:gog:game%20 with & stuff"
    url = "heroic://launch?" + shortcuts.urlencode({"appName": "game%20 with & stuff", "runner": "gog"})
    text = shortcuts.shortcut_text(key, ('Game\\name\nExec=evil $(cmd)', url, '/tmp/icon with spaces.png'))
    self.assertIn('Name=Game\\\\name\\nExec=evil $(cmd)\n', text)
    self.assertNotIn('\nExec=evil', text)
    command = next(line[5:] for line in text.splitlines() if line.startswith("Exec="))
    self.assertIn("%%", command)
    self.assertEqual(shortcuts.launch_identity(command), key)
    self.assertEqual(shortcuts.launch_identity('flatpak run com.valvesoftware.Steam steam://run/123//'), 'steam:123')
    self.assertEqual(shortcuts.launch_identity('xdg-open heroic://launch/gog/some%20game'), 'heroic:gog:some game')

  def test_invalid_state_does_not_change_shortcuts(self):
    self.sync()
    path = self.generated()[0]
    before = path.read_bytes()
    write(self.state, {"version": 1, "entries": {"steam:1145360": {"file": "../outside"}}})
    with self.assertRaises(ValueError):
      self.sync({}, set(), {"steam"})
    self.assertEqual(path.read_bytes(), before)

  def test_failed_discovery_command_preserves_existing_shortcuts(self):
    self.sync()
    path = self.generated()[0]
    before = path.read_bytes()
    state_dir = self.home / "custom state/omarchy"
    state_dir.mkdir(parents=True)
    write(state_dir / "game-shortcuts.json", "invalid JSON")
    env = dict(os.environ, HOME=str(self.home), OMARCHY_PATH=str(ROOT), XDG_DATA_HOME=str(self.data),
               XDG_CONFIG_HOME=str(self.config), XDG_STATE_HOME=str(state_dir.parent), XDG_DATA_DIRS=str(self.home / "system"))
    result = subprocess.run([str(ROOT / "bin/omarchy-refresh-game-shortcuts")], env=env, capture_output=True, text=True)
    self.assertEqual(result.returncode, 1)
    self.assertIn("Game shortcut refresh failed", result.stderr)
    self.assertEqual(path.read_bytes(), before)

  def test_removal_waits_for_discovery_lock(self):
    self.sync()
    path = self.generated()[0]
    state_dir = self.home / "custom state/omarchy"
    state_dir.mkdir(parents=True)
    self.state.rename(state_dir / "game-shortcuts.json")
    self.state = state_dir / "game-shortcuts.json"
    env = dict(os.environ, HOME=str(self.home), OMARCHY_PATH=str(ROOT), XDG_DATA_HOME=str(self.data),
               XDG_STATE_HOME=str(state_dir.parent), XDG_DATA_DIRS=str(self.home / "system"))
    with (state_dir / "game-shortcuts.lock").open("a") as lock:
      fcntl.flock(lock, fcntl.LOCK_EX)
      process = subprocess.Popen([str(ROOT / "bin/omarchy-remove-launcher-entry"), path.stem, "Hades"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
      self.addCleanup(lambda: process.kill() if process.poll() is None else None)
      with self.assertRaises(subprocess.TimeoutExpired):
        process.communicate(timeout=0.2)
      self.assertTrue(path.exists())
    output, error = process.communicate(timeout=5)
    self.assertEqual(process.returncode, 0, error.decode())
    self.assertFalse(path.exists())
    self.sync({}, set(), {"steam"})
    self.sync()
    self.assertEqual(self.generated(), [])

  def test_command_uses_xdg_paths_without_launching_clients(self):
    write(self.heroic / "legendaryConfig/legendary/installed.json", {"epic": {"title": "Epic game", "install_path": str(self.home)}})
    env = dict(os.environ, HOME=str(self.home), OMARCHY_PATH=str(ROOT), XDG_DATA_HOME=str(self.data),
               XDG_CONFIG_HOME=str(self.config), XDG_STATE_HOME=str(self.home / "custom state"), XDG_DATA_DIRS=str(self.home / "system"))
    lock_path = self.home / "custom state/omarchy/game-shortcuts.lock"
    lock_path.parent.mkdir(parents=True)
    with lock_path.open("a") as lock:
      fcntl.flock(lock, fcntl.LOCK_EX)
      subprocess.run([str(ROOT / "bin/omarchy-refresh-game-shortcuts")], env=env, check=True, capture_output=True, timeout=5)
      self.assertEqual(self.generated(), [])
    subprocess.run([str(ROOT / "bin/omarchy-refresh-game-shortcuts")], env=env, check=True, capture_output=True)
    self.assertEqual(len(self.generated()), 1)
    self.assertTrue((self.home / "custom state/omarchy/game-shortcuts.json").exists())
    self.assertIn("Exec=xdg-open", self.generated()[0].read_text())

  def test_vdf_quoted_braces_and_escapes(self):
    self.assertEqual(shortcuts.text_vdf('"Root" {"name" "}" "path" "C:\\\\Games"}'), {"root": {"name": "}", "path": "C:\\Games"}})
    with self.assertRaises(ValueError):
      shortcuts.text_vdf('"Root" {')


if __name__ == "__main__":
  unittest.main()
