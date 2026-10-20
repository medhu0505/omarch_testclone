"""Import local installations as ordinary desktop entries, without running clients."""

import configparser
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import struct
import sys
import tempfile
from urllib.parse import parse_qs, unquote, urlencode, urlsplit


def read_json(path):
  return json.loads(path.read_text())


def text_vdf(text):
  tokens = []
  pattern = re.compile(r'\s+|//[^\n]*|"(?:\\.|[^"\\])*"|[{}]')
  offset = 0
  for match in pattern.finditer(text.lstrip("\ufeff")):
    if match.start() != offset:
      raise ValueError("Invalid text VDF")
    offset = match.end()
    token = match.group()
    if token.startswith('"'):
      tokens.append(("value", re.sub(r'\\([\\"])', r'\1', token[1:-1])))
    elif token in ("{", "}"):
      tokens.append((token, token))
  if offset != len(text.lstrip("\ufeff")):
    raise ValueError("Truncated text VDF")
  stack = [{}]
  key = None
  for kind, token in tokens:
    if kind == "{":
      if key is None:
        raise ValueError("Missing VDF key")
      child = {}
      stack[-1][key] = child
      stack.append(child)
      key = None
    elif kind == "}":
      if len(stack) == 1 or key is not None:
        raise ValueError("Unbalanced VDF")
      stack.pop()
    elif key is None:
      key = token.lower()
    else:
      stack[-1][key] = token
      key = None
  if len(stack) != 1 or key is not None:
    raise ValueError("Incomplete VDF")
  return stack[0]


def cstring(stream):
  value = bytearray()
  while len(value) < 1024 * 1024:
    byte = stream.read(1)
    if byte == b"\0":
      return value.decode("utf-8", errors="replace")
    if not byte:
      break
    value.extend(byte)
  raise ValueError("Invalid binary VDF string")


def binary_vdf(stream, names=None, depth=0):
  if depth > 32:
    raise ValueError("Nested binary VDF")
  result = {}
  while True:
    kind = stream.read(1)
    if kind in (b"\x08", b"\x0b"):
      return result
    if not kind:
      raise ValueError("Truncated binary VDF")
    key = names[struct.unpack("<I", stream.read(4))[0]] if names is not None else cstring(stream)
    if kind == b"\0":
      value = binary_vdf(stream, names, depth + 1)
    elif kind == b"\x01":
      value = cstring(stream)
    elif kind in (b"\x02", b"\x03", b"\x04", b"\x06", b"\x07", b"\x0a"):
      size = 8 if kind in (b"\x07", b"\x0a") else 4
      value = stream.read(size)
      if len(value) != size:
        raise ValueError("Truncated binary VDF number")
    else:
      raise ValueError("Unsupported binary VDF type")
    result[key.lower()] = value


def steam_metadata(path, appids):
  # Valve's appinfo versions 27/28 use literal keys; 29 has a string table.
  # See SteamDatabase/SteamAppInfo's AppInfo.cs for the on-disk format.
  result = {}
  if not appids:
    return result
  with path.open("rb") as stream:
    file_size = os.fstat(stream.fileno()).st_size
    version, universe = struct.unpack("<II", stream.read(8))
    if version not in (0x07564427, 0x07564428, 0x07564429):
      raise ValueError("Unsupported Steam appinfo version")
    names = None
    if version == 0x07564429:
      offset = struct.unpack("<Q", stream.read(8))[0]
      stream.seek(offset)
      count = struct.unpack("<I", stream.read(4))[0]
      if count > 1000000:
        raise ValueError("Invalid Steam string table")
      names = [cstring(stream) for _ in range(count)]
      stream.seek(16)
    remaining = set(appids)
    while remaining:
      appid = struct.unpack("<I", stream.read(4))[0]
      if appid == 0:
        break
      size = struct.unpack("<I", stream.read(4))[0]
      end = stream.tell() + size
      header_size = 40 if version == 0x07564427 else 60
      if size < header_size or end > file_size:
        raise ValueError("Invalid Steam appinfo record")
      if str(appid) in remaining:
        if size > 16 * 1024 * 1024:
          raise ValueError("Oversized Steam appinfo record")
        stream.seek(header_size, 1)
        data = binary_vdf(io.BytesIO(stream.read(size - header_size)), names)
        result[str(appid)] = data.get("appinfo", {}).get("common", {})
        remaining.remove(str(appid))
      stream.seek(end)
  return result


def steam_games(home, data_home):
  games, present = {}, set()
  complete = True
  roots = [data_home / "Steam", home / ".steam/steam", home / ".steam/root",
           home / ".var/app/com.valvesoftware.Steam/data/Steam",
           home / ".var/app/com.valvesoftware.Steam/.local/share/Steam"]
  visited = set()
  found = False
  for root in roots:
    if not root.is_dir() or root.resolve() in visited:
      continue
    found = True
    visited.add(root.resolve())
    try:
      libraries = text_vdf((root / "steamapps/libraryfolders.vdf").read_text())["libraryfolders"]
      directories = {root / "steamapps"}
      for value in libraries.values():
        path = value.get("path") if isinstance(value, dict) else value
        if isinstance(path, str) and Path(path).is_absolute():
          directories.add(Path(path) / "steamapps")
      manifests = {}
      for directory in directories:
        if not directory.is_dir():
          complete = False  # An unmounted library is not an uninstall.
          continue
        # iterdir surfaces permission errors; glob can silently return an empty
        # list, which must never be interpreted as an uninstalled library.
        for path in directory.iterdir():
          if not re.fullmatch(r"appmanifest_\d+\.acf", path.name):
            continue
          try:
            game = text_vdf(path.read_text())["appstate"]
            appid = game["appid"]
            if not appid.isdecimal():
              raise ValueError("Invalid Steam app ID")
            present.add("steam:" + appid)
            install = directory / "common" / game["installdir"]
            if int(game["stateflags"]) & 4 and install.is_dir():
              manifests[appid] = game
          except (OSError, ValueError, KeyError, TypeError, AttributeError):
            complete = False
      metadata = steam_metadata(root / "appcache/appinfo.vdf", manifests)
      for appid, game in manifests.items():
        common = metadata.get(appid, {})
        if str(common.get("type", "")).lower() not in ("game", "demo", "mod"):
          continue  # Proton, runtimes, tools, DLC and unknown types stay out.
        icon_hash = common.get("clienticon", "")
        icon = root / "steam/games" / (str(icon_hash) + ".ico")
        games["steam:" + appid] = (game["name"], "steam://rungameid/" + appid,
                                    str(icon) if re.fullmatch(r"[a-fA-F0-9]{40}", str(icon_hash)) and icon.is_file() else "steam_icon_" + appid)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError, struct.error):
      complete = False
  return games, present, {"steam"} if found and complete else set()


def heroic_games(home, config_home):
  games, present, complete = {}, set(), set()
  roots = [config_home / "heroic", home / ".var/app/com.heroicgameslauncher.hgl/config/heroic"]
  statuses = {runner: [] for runner in ("legendary", "gog", "nile")}
  for root in roots:
    if not root.is_dir():
      continue
    stores = [
      ("legendary", root / "legendaryConfig/legendary/installed.json", root / "store_cache/legendary_library.json", "library"),
      ("gog", root / "gog_store/installed.json", root / "store_cache/gog_library.json", "games"),
      ("nile", root / "nile_config/nile/installed.json", root / "store_cache/nile_library.json", "library")
    ]
    for runner, installed_path, library_path, library_key in stores:
      try:
        installed = read_json(installed_path)
        if runner == "legendary":
          if not isinstance(installed, dict):
            raise ValueError("Invalid Legendary installations")
          entries = [(str(appid), game) for appid, game in installed.items()]
        elif runner == "gog":
          entries = [(str(game["appName"]), game) for game in installed["installed"]]
        else:
          entries = [(str(game["id"]), game) for game in installed]
        # Installation identity is authoritative even if cached titles are missing.
        present.update("heroic:" + runner + ":" + appid for appid, _ in entries)
        library = {}
        if library_path and library_path.exists():
          library = {str(game["app_name"]): game for game in read_json(library_path)[library_key]}
        for appid, game in entries:
          info = library.get(appid, game)
          path = game.get("install_path", game.get("path", ""))
          title = info.get("title", game.get("title", ""))
          if not title or not path or not Path(path).is_dir() or game.get("is_dlc"):
            continue
          art = str(info.get("art_square", ""))
          if runner == "legendary":
            art += "?h=400&resize=1&w=300"
          icon = root / "images-cache" / hashlib.sha256(art.encode()).hexdigest()
          url = "heroic://launch?" + urlencode({"appName": appid, "runner": runner})
          games["heroic:" + runner + ":" + appid] = (title, url, str(icon) if icon.is_file() else "heroic")
        statuses[runner].append(True)
      except (OSError, ValueError, KeyError, TypeError, AttributeError):
        statuses[runner].append(False)
  for runner, status in statuses.items():
    if status and all(status):
      complete.add("heroic:" + runner)
  return games, present, complete


def launch_identity(command):
  # Compare store identities, never titles. Different stores may own the same title.
  try:
    words = shlex.split(command.replace("%%", "%"))
  except ValueError:
    return None
  for word in words:
    try:
      url = urlsplit(word)
    except ValueError:
      continue
    if url.scheme == "steam" and url.netloc in ("rungameid", "run"):
      appid = url.path.strip("/").split("/")[0]
      if appid.isdecimal():
        return "steam:" + appid
    if url.scheme == "heroic" and url.netloc == "launch":
      query = parse_qs(url.query)
      if query.get("runner") and query.get("appName"):
        return "heroic:" + query["runner"][0] + ":" + query["appName"][0]
      parts = url.path.strip("/").split("/", 1)
      if len(parts) == 2:
        return "heroic:" + parts[0] + ":" + unquote(parts[1])
  for index, word in enumerate(words[:-1]):
    if word == "-applaunch" and words[index + 1].isdecimal():
      return "steam:" + words[index + 1]
  return None


def desktop_value(value):
  return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")


def shortcut_filename(key):
  return "omarchy-game-" + hashlib.sha256(key.encode()).hexdigest()[:24] + ".desktop"


def with_checksum(text):
  return text + "X-Omarchy-Game-Hash=" + hashlib.sha256(text.encode()).hexdigest() + "\n"


def shortcut_text(key, game, alias=False):
  title, url, icon = game
  # Desktop Exec has its own quoting and field-code rules; no shell is involved.
  argument = url.replace("%", "%%")
  argument = '"' + re.sub(r'([\\"`$])', r'\\\1', argument) + '"'
  lines = ["[Desktop Entry]", "Type=Application", "Name=" + desktop_value(title),
           "Exec=xdg-open " + desktop_value(argument), "Icon=" + desktop_value(icon),
           "Terminal=false", "Categories=Game;", "X-Omarchy-Game=" + desktop_value(key)]
  if key.startswith("steam:"):
    lines.append("StartupWMClass=steam_app_" + key.split(":", 1)[1])
  if alias:
    lines.append("NoDisplay=true")
  return with_checksum("\n".join(lines + [""]))


def recover_shortcut(path):
  # The content checksum recovers our last write if the process stopped before
  # saving the ledger. A marker alone must never claim a user-edited file.
  if path.is_symlink() or not path.is_file():
    return None
  text = path.read_bytes().decode("utf-8")
  body, separator, digest = text.rpartition("X-Omarchy-Game-Hash=")
  if not separator or digest != hashlib.sha256(body.encode()).hexdigest() + "\n":
    return None
  desktop = configparser.ConfigParser(interpolation=None, strict=False)
  desktop.read_string(body)
  key = desktop.get("Desktop Entry", "X-Omarchy-Game", fallback="")
  if path.name != shortcut_filename(key) or launch_identity(desktop.get("Desktop Entry", "Exec", fallback="")) != key:
    return None
  record = {"file": path.name, "hash": hashlib.sha256(text.encode()).hexdigest()}
  if desktop.get("Desktop Entry", "NoDisplay", fallback="false") == "true":
    record["external"] = True
  return key, record


def atomic_write(path, text):
  with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
    temporary = Path(stream.name)
    try:
      stream.write(text)
      stream.close()
      temporary.chmod(0o644)
      temporary.replace(path)
    finally:
      temporary.unlink(missing_ok=True)


def load_state(state_path):
  state = read_json(state_path) if state_path.exists() else {"version": 1, "entries": {}}
  if not isinstance(state, dict) or state.get("version") != 1 or not isinstance(state.get("entries"), dict):
    raise ValueError("Invalid game-shortcut state")
  entries = state["entries"]
  for key, record in entries.items():
    if not isinstance(record, dict):
      raise ValueError("Invalid managed shortcut record")
    filename = record.get("file", "")
    if not isinstance(filename, str) or (filename and (Path(filename).name != filename or not filename.startswith("omarchy-game-"))):
      raise ValueError("Invalid managed shortcut filename")
  return state


def save_state(state_path, state):
  text = json.dumps(state, indent=2, sort_keys=True) + "\n"
  if not state_path.exists() or state_path.read_text() != text:
    atomic_write(state_path, text)


def remove_shortcut(app_dir, state_path, filename):
  if Path(filename).name != filename or not filename.startswith("omarchy-game-") or not filename.endswith(".desktop"):
    raise ValueError("Invalid managed shortcut filename")
  path = app_dir / filename
  state = load_state(state_path)
  key = next((key for key, record in state["entries"].items() if record.get("file") == filename), None)
  if key is None:
    recovered = recover_shortcut(path)
    if recovered:
      key = recovered[0]
  if key is not None:
    # Persist the user's choice before unlinking, under the discovery lock.
    # Pending cleanup also lets discovery finish an interrupted removal.
    record = {"file": filename, "suppressed": True, "cleanup": True}
    if path.is_file() and not path.is_symlink():
      record["hash"] = hashlib.sha256(path.read_bytes()).hexdigest()
    state["entries"][key] = record
    save_state(state_path, state)
  path.unlink(missing_ok=True)
  if key is not None:
    state["entries"][key] = {"suppressed": True}
    save_state(state_path, state)


def synchronize(app_dir, desktop_dirs, state_path, games, present, complete):
  state = load_state(state_path)
  entries = state["entries"]
  for path in app_dir.glob("omarchy-game-*.desktop"):
    try:
      recovered = recover_shortcut(path)
      record = entries.get(recovered[0], {}) if recovered else {}
      if recovered and not record.get("suppressed") and not record.get("cleanup"):
        entries[recovered[0]] = recovered[1]
    except (OSError, ValueError, configparser.Error):
      continue
  existing = set()
  managed_paths = {app_dir / record["file"] for record in entries.values() if "file" in record and Path(record["file"]).name == record["file"]}
  for directory in desktop_dirs:
    for path in directory.rglob("*.desktop"):
      if path in managed_paths:
        continue
      try:
        desktop = configparser.ConfigParser(interpolation=None, strict=False)
        desktop.read_string(path.read_text())
        key = launch_identity(desktop.get("Desktop Entry", "Exec", fallback=""))
        if key:
          existing.add(key)
      except (OSError, ValueError, configparser.Error):
        continue
  for key in set(entries) | set(games):
    record = entries.get(key, {})
    filename = record.get("file", shortcut_filename(key))
    if Path(filename).name != filename or not filename.startswith("omarchy-game-"):
      raise ValueError("Invalid managed shortcut filename")
    path = app_dir / filename
    owned = False
    if record.get("hash"):
      if path.is_file() and not path.is_symlink():
        owned = hashlib.sha256(path.read_bytes()).hexdigest() == record["hash"]
    if record.get("cleanup"):
      if record.get("suppressed"):
        if owned:
          path.unlink()
        entries[key] = {"suppressed": True}
        continue
      if not path.exists() and not path.is_symlink():
        # Our interrupted cleanup removed it, even if the game is installed again.
        record = {}
        entries.pop(key, None)
      else:
        record.pop("cleanup", None)
    if record.get("hash") and not owned:
      record["suppressed"] = True  # Deleted and edited imports belong to the user.
    if record.get("suppressed"):
      entries[key] = record
      continue
    source = "steam" if key.startswith("steam:") else ":".join(key.split(":")[:2])
    if key not in present and source in complete:
      if owned:
        # Write ahead of unlink: a missing file must not look like a user removal
        # if the process stops before the final ledger write.
        record["cleanup"] = True
        save_state(state_path, state)
        path.unlink()
      entries.pop(key, None)
      continue
    if not record.get("hash") and (key in existing or record.get("external")):
      # A client shortcut is an observation, not a permanent removal preference.
      # Forget it on confirmed uninstall, so a later reinstall can be imported.
      entries[key] = {"external": True}
      continue
    if key in games:
      if (path.exists() or path.is_symlink()) and not owned:
        continue
      # Preserve an existing imported ID for dock pins when a client adds its
      # own entry. NoDisplay keeps the alias out of every desktop app launcher.
      alias = key in existing or record.get("external", False)
      text = shortcut_text(key, games[key], alias)
      digest = hashlib.sha256(text.encode()).hexdigest()
      if digest != record.get("hash"):
        atomic_write(path, text)
      entries[key] = {"file": filename, "hash": digest}
      if alias:
        entries[key]["external"] = True
  save_state(state_path, state)


def main():
  remove = len(sys.argv) == 3 and sys.argv[1] == "--remove"
  if len(sys.argv) != 1 and not remove:
    raise ValueError("Usage: shortcuts.py [--remove <desktop-file>]")
  home = Path.home()
  data_home = Path(os.environ.get("XDG_DATA_HOME") or home / ".local/share")
  config_home = Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config")
  state_home = Path(os.environ.get("XDG_STATE_HOME") or home / ".local/state")
  state_dir = state_home / "omarchy"
  state_dir.mkdir(parents=True, exist_ok=True)
  with (state_dir / "game-shortcuts.lock").open("a") as lock:
    try:
      fcntl.flock(lock, fcntl.LOCK_EX if remove else fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
      return
    app_dir = data_home / "applications"
    app_dir.mkdir(parents=True, exist_ok=True)
    if remove:
      remove_shortcut(app_dir, state_dir / "game-shortcuts.json", sys.argv[2])
      return
    desktop_dirs = [app_dir] + [Path(path) / "applications" for path in (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":") if path]
    steam, steam_present, steam_complete = steam_games(home, data_home)
    heroic, heroic_present, heroic_complete = heroic_games(home, config_home)
    if not steam and not heroic and not (state_dir / "game-shortcuts.json").exists() and not next(app_dir.glob("omarchy-game-*.desktop"), None):
      return
    synchronize(app_dir, desktop_dirs, state_dir / "game-shortcuts.json", steam | heroic,
                steam_present | heroic_present, steam_complete | heroic_complete)


if __name__ == "__main__":
  try:
    main()
  except (OSError, ValueError, TypeError) as error:
    print("Game shortcut refresh failed: " + str(error), file=sys.stderr)
    sys.exit(1)
