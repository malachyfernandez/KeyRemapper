#!/usr/bin/env python3
"""KeyRemapper — a modern keyboard remapping UI for Hammerspoon.

Zero-dependency Python backend using the built-in http.server module.
Serves a web UI and provides API endpoints for:
  - Reading the current macOS keyboard layout (via Swift helper)
  - Reading/writing keyremaps.lua
"""

import json
import os
import re
import shlex
import signal
import subprocess
import sys
from http.server import HTTPServer, SimpleHTTPRequestHandler
from socketserver import ThreadingMixIn
from pathlib import Path
from urllib.parse import urlparse

# ── Paths ────────────────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).resolve().parent
HS_DIR = Path(os.path.expanduser("~/.hammerspoon"))
KEYREMAPS_FILE = HS_DIR / "keyremaps.lua"
SWIFT_HELPER = Path(os.environ.get("KEYREMAPPER_HELPER", str(SCRIPT_DIR / "keyboard_layout")))

# ── Keyboard layout ─────────────────────────────────────────────────────

def get_keyboard_layout():
    """Call the Swift helper to get the current keyboard layout as JSON."""
    try:
        result = subprocess.run(
            [str(SWIFT_HELPER)],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode != 0:
            return {"error": result.stderr.strip() or "Swift helper failed"}
        return json.loads(result.stdout)
    except json.JSONDecodeError as e:
        return {"error": f"JSON parse error: {e}"}
    except subprocess.TimeoutExpired:
        return {"error": "Swift helper timed out"}
    except Exception as e:
        return {"error": str(e)}


# ── keyremaps.lua parsing & generation ──────────────────────────────────

# US layout key code <-> Hammerspoon key name (mirrors US_KEY_NAMES in app.js).
# Keycodes are hardware/layout-independent, which is what the eventtap needs.
KEY_CODE_TO_NAME = {
    0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g",
    6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
    12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
    18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
    24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
    30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p",
    37: "l", 38: "j", 39: "'", 40: "k",
    41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m",
    47: ".", 50: "`",
    36: "return", 48: "tab", 49: "space", 51: "delete", 53: "escape",
}
KEY_NAME_TO_CODE = {v: k for k, v in KEY_CODE_TO_NAME.items()}

# Canonical modifier order — MUST match the sig() function in the lua boilerplate.
# cmd and fn are never remapped but appear in sig() so that combos carrying them
# produce a signature with no matching entry and pass through untouched.
MOD_ORDER = ["capslock", "shift", "alt", "ctrl"]


def _key_name_to_code(name):
    """Convert a Hammerspoon key name to a macOS keycode."""
    if name in KEY_NAME_TO_CODE:
        return KEY_NAME_TO_CODE[name]
    # Fallback: name may be a numeric keycode string (getHSKeyName fallback in app.js)
    try:
        return int(name)
    except (ValueError, TypeError):
        return None


def _key_code_to_name(code):
    """Convert a macOS keycode to a Hammerspoon key name."""
    return KEY_CODE_TO_NAME.get(code, str(code))


def _canonical_mods(mods_list):
    """Canonicalize modifier list to a fixed order matching the lua sig() function."""
    present = set(mods_list)
    return [m for m in MOD_ORDER if m in present]


# Matches new-format table entries:
#   {key = 0, mods = "shift+alt", out = "¬"},
TABLE_RE = re.compile(
    r'\{\s*key\s*=\s*(\d+)\s*,\s*'
    r'mods\s*=\s*"([^"]*)"\s*,\s*'
    r'out\s*=\s*"((?:[^"\\]|\\.)*)"\s*\}'
)

# Matches legacy hs.hotkey.bind entries (for reading old-format files):
#   hs.hotkey.bind({"alt", "shift"}, ";", function()
#       hs.eventtap.keyStrokes("⋯")
#   end)
BIND_RE = re.compile(
    r'hs\.hotkey\.bind\(\s*\{([^}]*)\}\s*,\s*'
    r'"([^"]*)"\s*,\s*'
    r'function\(\)\s*'
    r'hs\.eventtap\.keyStrokes\(\s*"((?:[^"\\]|\\.)*)"\s*\)\s*'
    r'end\s*\)',
    re.DOTALL
)


def _unescape_lua(s):
    """Unescape a Lua double-quoted string."""
    return s.replace('\\"', '"').replace("\\\\", "\\").replace("\\n", "\n").replace("\\t", "\t")


def _escape_lua(s):
    """Escape a string for a Lua double-quoted string."""
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def parse_remaps(content):
    """Parse keyremaps.lua content and return a list of remap dicts.

    Reads the new eventtap table format. Falls back to the legacy
    hs.hotkey.bind format so old files migrate automatically on next save.
    """
    remaps = []

    # New format: {key = N, mods = "...", out = "..."}
    for match in TABLE_RE.finditer(content):
        keycode = int(match.group(1))
        mods_str = match.group(2)
        output = _unescape_lua(match.group(3))
        modifiers = [m for m in mods_str.split("+") if m and m != "none"]
        remaps.append({
            "modifiers": modifiers,
            "key": _key_code_to_name(keycode),
            "output": output,
        })

    # Legacy format fallback: hs.hotkey.bind({...}, "key", function() ... end)
    if not remaps:
        for match in BIND_RE.finditer(content):
            mods_str = match.group(1)
            modifiers = [m.strip().strip('"').strip("'") for m in mods_str.split(",") if m.strip()]
            key = match.group(2)
            output = _unescape_lua(match.group(3))
            remaps.append({
                "modifiers": modifiers,
                "key": key,
                "output": output,
            })

    return remaps


# Fixed eventtap boilerplate appended after the remaps table.
# The sig() modifier order MUST match MOD_ORDER above.
_EVENTTAP_BOILERPLATE = """-- Build lookup: keycode -> { mod_signature -> output }
local lookup = {}
for _, r in ipairs(remaps) do
    lookup[r.key] = lookup[r.key] or {}
    lookup[r.key][r.mods] = r.out
end

-- Compute a canonical modifier signature from CGEvent flags.
-- Order MUST match the mods strings in the remaps table above.
-- cmd and fn are included so that combos carrying them produce a
-- signature with no matching entry and pass through untouched.
local function sig(flags)
    local s = {}
    if flags.capslock then s[#s+1] = "capslock" end
    if flags.shift    then s[#s+1] = "shift"    end
    if flags.alt      then s[#s+1] = "alt"      end
    if flags.ctrl     then s[#s+1] = "ctrl"     end
    if flags.cmd      then s[#s+1] = "cmd"      end
    if flags.fn       then s[#s+1] = "fn"       end
    return table.concat(s, "+")
end

hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
    local byMod = lookup[event:getKeyCode()]
    if not byMod then return false end
    local out = byMod[sig(event:getFlags())]
    if out then
        hs.eventtap.keyStrokes(out)
        return true   -- swallow the original event
    end
    return false      -- let everything else through
end):start()
"""


def generate_remaps_lua(remaps):
    """Generate keyremaps.lua content from a list of remap dicts.

    Emits a flat remaps table + a single hs.eventtap that dispatches on
    keycode + modifier signature. This replaces hs.hotkey.bind because
    macOS Sequoia+ suppresses global hotkeys whose only modifiers are
    Option / Shift+Option. The eventtap intercepts raw keyDown events
    before that suppression applies.
    """
    lines = [
        "------------------------------------------------------------------------",
        "-- KEY REMAPS",
        "------------------------------------------------------------------------",
        "-- This file is managed by KeyRemapper. Edit via the app or manually.",
        '-- Loaded from init.lua via `require("keyremaps")`.',
        "--",
        "-- Remaps are delivered via an hs.eventtap (not hs.hotkey.bind) because",
        "-- macOS Sequoia+ suppresses global hotkeys whose only modifiers are",
        "-- Option / Shift+Option. The eventtap intercepts raw keyDown events",
        "-- before that suppression applies.",
        "",
        "-- One entry per remap. key = macOS keycode (hardware key, layout-independent).",
        "-- mods = canonical modifier signature (ordered: capslock+shift+alt+ctrl).",
        "local remaps = {",
    ]
    for r in remaps:
        keycode = _key_name_to_code(r["key"])
        if keycode is None:
            continue
        mods = _canonical_mods(r.get("modifiers", []))
        mods_str = "+".join(mods)  # empty string for no modifiers
        output_escaped = _escape_lua(r["output"])
        lines.append(f'    {{key = {keycode}, mods = "{mods_str}", out = "{output_escaped}"}},')
    lines.append("}")
    lines.append("")
    lines.append(_EVENTTAP_BOILERPLATE)
    return "\n".join(lines)


def read_remaps():
    """Read and parse keyremaps.lua. Create it (empty) if missing so
    Hammerspoon's require("keyremaps") doesn't fail."""
    if not KEYREMAPS_FILE.exists():
        write_remaps([])
        return []
    content = KEYREMAPS_FILE.read_text(encoding="utf-8")
    return parse_remaps(content)


def write_remaps(remaps):
    """Write remaps to keyremaps.lua."""
    content = generate_remaps_lua(remaps)
    KEYREMAPS_FILE.write_text(content, encoding="utf-8")


def check_hammerspoon():
    """Check if Hammerspoon is installed and running."""
    # Check if the app exists
    app_path = "/Applications/Hammerspoon.app"
    installed = os.path.exists(app_path) or os.path.exists(os.path.expanduser("~/Applications/Hammerspoon.app"))

    # Check if it's running
    running = False
    try:
        result = subprocess.run(
            ["osascript", "-e", 'application "Hammerspoon" is running'],
            capture_output=True, text=True, timeout=3
        )
        running = result.returncode == 0 and result.stdout.strip() == "true"
    except Exception:
        pass

    # Check if init.lua exists
    init_exists = HS_DIR.exists() and (HS_DIR / "init.lua").exists()

    # Check if init.lua actually requires keyremaps (not commented out)
    keyremaps_required = False
    if init_exists:
        content = (HS_DIR / "init.lua").read_text(encoding="utf-8")
        for line in content.splitlines():
            stripped = line.strip()
            # Active require: not a comment, contains require("keyremaps")
            if not stripped.startswith("--") and 'require("keyremaps")' in stripped:
                keyremaps_required = True
                break

    return {
        "installed": installed,
        "running": running,
        "init_exists": init_exists,
        "keyremaps_required": keyremaps_required,
    }


# ── HTTP server ──────────────────────────────────────────────────────────

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(SCRIPT_DIR / "static"), **kwargs)

    def handle_one_request(self):
        """Wrap request handling to catch all exceptions."""
        try:
            super().handle_one_request()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:
            pass

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/api/layout":
            data = get_keyboard_layout()
            self._json(data)
        elif path == "/api/remaps":
            remaps = read_remaps()
            self._json({"remaps": remaps})
        elif path == "/api/hammerspoon":
            data = check_hammerspoon()
            # One-shot flag: /api/restart-app drops a marker before
            # killing the app; the first status check after relaunch
            # consumes it so the UI knows it already restarted once.
            marker = Path("/tmp/keyremapper-restarted")
            data["just_restarted"] = marker.exists()
            try:
                marker.unlink(missing_ok=True)
            except Exception:
                pass
            self._json(data)
        elif path == "/" or path == "":
            self._serve_html()
        else:
            super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/api/remaps":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                data = json.loads(body)
                remaps = data.get("remaps", [])
                write_remaps(remaps)
                self._json({"ok": True})
            except Exception as e:
                self._json({"error": str(e)}, status=500)
        elif path == "/api/reload":
            # Try to trigger Hammerspoon reload via AppleScript
            try:
                subprocess.run(
                    ["osascript", "-e",
                     'tell application "Hammerspoon" to execute lua code "hs.reload()"'],
                    capture_output=True, timeout=5
                )
                self._json({"ok": True})
            except Exception as e:
                self._json({"error": str(e)}, status=500)
        elif path == "/api/export":
            # Copy keyremaps.lua to ~/Downloads and reveal it in Finder
            try:
                if not KEYREMAPS_FILE.exists():
                    write_remaps([])
                downloads = Path(os.path.expanduser("~/Downloads"))
                downloads.mkdir(exist_ok=True)
                target = downloads / "keyremaps.lua"
                n = 1
                while target.exists():
                    target = downloads / f"keyremaps-{n}.lua"
                    n += 1
                target.write_text(KEYREMAPS_FILE.read_text(encoding="utf-8"), encoding="utf-8")
                subprocess.Popen(["open", "-R", str(target)])
                self._json({"ok": True, "path": str(target)})
            except Exception as e:
                self._json({"error": str(e)}, status=500)
        elif path == "/api/restart-app":
            # Full app restart: spawn a detached watchdog process that
            # kills this app's entire process group (Swift host + this
            # server), then relaunches the .app bundle — exactly like a
            # force-quit followed by reopening it manually.
            try:
                bundle = os.environ.get("KEYREMAPPER_BUNDLE_PATH", "")
                if not bundle.endswith(".app"):
                    bundle = ""
                    for p in [Path(__file__).resolve()] + list(Path(__file__).resolve().parents):
                        if p.name.endswith(".app"):
                            bundle = str(p)
                            break
                if not bundle:
                    bundle = "/Applications/KeyRemapper.app"
                # Marker so the relaunched UI knows a restart already
                # happened (server-side — survives the full process kill).
                try:
                    Path("/tmp/keyremapper-restarted").write_text("1")
                except Exception:
                    pass
                pgid = os.getpgrp()
                # Kill the full ancestor chain (applet → sh → KeyRemapper →
                # this server) so no wrapper process survives to complain.
                targets = {str(os.getpid()), str(os.getppid())}
                pid = os.getppid()
                while pid > 1:
                    try:
                        out = subprocess.run(
                            ["/bin/ps", "-o", "ppid=", "-p", str(pid)],
                            capture_output=True, text=True, timeout=3
                        ).stdout.strip()
                        pid = int(out) if out else 1
                        if pid > 1:
                            targets.add(str(pid))
                    except Exception:
                        break
                script = (
                    "sleep 0.6; "
                    f"kill -KILL -{pgid} {' '.join(sorted(targets))} 2>/dev/null; "
                    "sleep 0.4; "
                    # Clear stale runtime files so the relaunched app
                    # can't read a dead port before its server writes one.
                    "rm -f /tmp/keyremapper-port /tmp/keyremapper-pid; "
                    f"/usr/bin/open {shlex.quote(bundle)}"
                )
                subprocess.Popen(
                    ["/bin/sh", "-c", script],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,  # own session: survives the group kill
                )
                self._json({"ok": True, "restarting": True})
            except Exception as e:
                self._json({"error": str(e)}, status=500)
        elif path == "/api/create-init":
            # Create/fix the Hammerspoon init.lua file so it requires keyremaps
            try:
                HS_DIR.mkdir(parents=True, exist_ok=True)
                init_file = HS_DIR / "init.lua"
                if not init_file.exists():
                    # Create a fresh init.lua
                    init_content = (
                        "-- Hammerspoon init.lua\n"
                        "-- Created by KeyRemapper\n\n"
                        'require("keyremaps")\n\n'
                        "-- Auto-reload when keyremaps.lua changes\n"
                        'hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/keyremaps.lua", function()\n'
                        "    hs.reload()\n"
                        "end):start()\n"
                    )
                    init_file.write_text(init_content, encoding="utf-8")
                else:
                    # init.lua exists — make sure require("keyremaps") is active
                    content = init_file.read_text(encoding="utf-8")
                    lines = content.splitlines()
                    found = False
                    changed = False
                    for i, line in enumerate(lines):
                        stripped = line.strip()
                        # Uncomment a commented-out require("keyremaps")
                        if stripped.startswith("--") and 'require("keyremaps")' in stripped:
                            lines[i] = line.lstrip().lstrip("-").lstrip()
                            found = True
                            changed = True
                        elif not stripped.startswith("--") and 'require("keyremaps")' in stripped:
                            found = True
                    if not found:
                        # Add require("keyremaps") + pathwatcher at the end
                        lines.append("")
                        lines.append("------------------------------------------------------------------------")
                        lines.append("-- KEY REMAPS -- managed by KeyRemapper")
                        lines.append("------------------------------------------------------------------------")
                        lines.append('require("keyremaps")')
                        lines.append("")
                        lines.append("-- Auto-reload when keyremaps.lua changes")
                        lines.append('hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/keyremaps.lua", function()')
                        lines.append("    hs.reload()")
                        lines.append("end):start()")
                        changed = True
                    if changed:
                        init_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
                # Also create keyremaps.lua if it doesn't exist
                if not KEYREMAPS_FILE.exists():
                    write_remaps([])
                self._json({"ok": True})
            except Exception as e:
                self._json({"error": str(e)}, status=500)
        else:
            self._json({"error": "not found"}, status=404)

    def do_DELETE(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/remaps":
            # Delete a specific remap by index
            query = parsed.query
            # Simple query parsing
            from urllib.parse import parse_qs
            params = parse_qs(query)
            idx = int(params.get("index", ["-1"])[0])
            remaps = read_remaps()
            if 0 <= idx < len(remaps):
                remaps.pop(idx)
                write_remaps(remaps)
                self._json({"ok": True})
            else:
                self._json({"error": "invalid index"}, status=400)
        else:
            self._json({"error": "not found"}, status=404)

    def _json(self, data, status=200):
        body = json.dumps(data).encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", len(body))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _serve_html(self):
        html_path = SCRIPT_DIR / "templates" / "index.html"
        if html_path.exists():
            body = html_path.read_bytes()
            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", len(body))
                self.end_headers()
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self._json({"error": "index.html not found"}, status=404)

    def log_message(self, format, *args):
        # Suppress request logs for cleanliness
        pass


def main():
    import socket
    import signal

    # Ignore SIGPIPE — this prevents the server from dying when a client
    # (like WKWebView) disconnects before the response is fully sent.
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)

    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5173

    # If port is 0, let the OS pick a free port
    if port == 0:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.bind(("", 0))
        port = s.getsockname()[1]
        s.close()

    # Enable SO_REUSEADDR to avoid "Address already in use" on quick restarts
    Handler.allow_reuse_address = True

    class ThreadedServer(ThreadingMixIn, HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    server = ThreadedServer(("127.0.0.1", port), Handler)
    server.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

    # Write the actual port to a file so the Swift app can read it
    port_file = os.environ.get("KEYREMAPPER_PORT_FILE", "/tmp/keyremapper-port")
    try:
        with open(port_file, "w") as f:
            f.write(str(port))
    except Exception:
        pass

    print(f"KeyRemapper running at http://127.0.0.1:{port}", flush=True)

    # Auto-open browser (skip when running inside the standalone app)
    if not os.environ.get("KEYREMAPPER_NO_BROWSER"):
        try:
            subprocess.Popen(["open", f"http://127.0.0.1:{port}"])
        except Exception:
            pass
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
