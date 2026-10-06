|
## KeyRemapper Overview (for context)

KeyRemapper is a standalone macOS app that provides a modern UI for remapping keyboard keys via Hammerspoon. It's a replacement for Ukelele. The app:

- Shows a live virtual keyboard reflecting the user's current macOS layout
- Lets users click or press a key to select it
- Lets users type a replacement output
- Saves remaps to `~/.hammerspoon/keyremaps.lua` as a flat table + single `hs.eventtap` (not `hs.hotkey.bind` — see `docs/option-key-hotkeys-broken-macos27.md` for why)
- Auto-reloads Hammerspoon when remaps change

### Architecture

- **`KeyRemapperApp.swift`** — Swift macOS app (WKWebView window). Launches Python server via `Process`, stores it as `serverProcess` class property. Uses custom `keyremapper://` URL scheme to serve static files and proxy API calls to Python (bypasses ATS restrictions on http:// in WKWebView).
- **`app.py`** — Zero-dependency Python HTTP server (stdlib only, no Flask). Threaded (`ThreadingMixIn`). Serves web UI + API endpoints. Writes port to `/tmp/keyremapper-port`. Generates and parses `keyremaps.lua` in the eventtap format (see below).
- **`keyboard_layout.swift`** — Swift helper using Carbon `UCKeyboardLayout`/`UCKeyTranslate` APIs. Outputs JSON mapping key codes → characters for each modifier state (none, shift, option, shift_option, caps, ctrl, etc.).
- **`templates/index.html`** — Web UI structure: virtual keyboard, modifier bar, remap panel, remaps sidebar, onboarding overlay.
- **`static/style.css`** — Dark theme styling.
- **`static/app.js`** — Frontend logic: keyboard rendering, key selection, remap save/delete, modifier handling, onboarding, Hammerspoon check.
- **`build.sh`** — Compiles Swift files, creates AppleScript-based `.app` bundle (via `osacompile` — needed because macOS 26 LaunchServices rejects unsigned Swift-compiled bundles with error -10825), bundles all resources, ad-hoc codesigns.
- **`build_dmg.sh`** — Builds a `.dmg` with the app + `/Applications` symlink. Runs `build.sh` first, so it's the only command you need.

### keyremaps.lua format (eventtap, not hs.hotkey.bind)

The app generates `~/.hammerspoon/keyremaps.lua` as a flat table + a single `hs.eventtap`. This replaced the old `hs.hotkey.bind` format because macOS Sequoia+ suppresses global hotkeys whose only modifiers are Option/Shift+Option (see `docs/option-key-hotkeys-broken-macos27.md` for the full investigation).

**Format:**
```lua
local remaps = {
    {key = 0, mods = "alt",       out = "∀"},
    {key = 0, mods = "shift+alt", out = "¬"},
    -- ...
}

local lookup = {}
for _, r in ipairs(remaps) do
    lookup[r.key] = lookup[r.key] or {}
    lookup[r.key][r.mods] = r.out
end

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
        return true
    end
    return false
end):start()
```

**Key design points:**
- **Numeric keycodes** (not `hs.keycodes.map[name]`) — layout-independent. The app converts between Hammerspoon key names (e.g. "a", ";", "1") and keycodes using `KEY_CODE_TO_NAME` / `KEY_NAME_TO_CODE` tables in `app.py` (mirrors `US_KEY_NAMES` in `app.js`).
- **Modifier signature** is canonical-ordered: `capslock+shift+alt+ctrl`. `cmd` and `fn` are included in `sig()` so combos carrying them produce a signature with no matching entry and pass through untouched. This gives correct cmd/fn/ctrl passthrough for free.
- **Auto-repeat allowed** — held keys repeat the output (unlike `hs.hotkey.bind` which fires once). This was a deliberate choice.
- **No re-entrancy loop** — `keyStrokes` clears flags to 0, so the re-entrant event has signature `""` which matches no entry → passes through.
- **Modifier order MUST match** between the `mods` strings in the table and the `sig()` function in the boilerplate. Both use `capslock+shift+alt+ctrl` order. `MOD_ORDER` in `app.py` enforces this.

**Parsing:** `parse_remaps()` in `app.py` reads the new table format via `TABLE_RE` regex. It also has a fallback to the legacy `hs.hotkey.bind` format via `BIND_RE` so old files migrate automatically on first save.

**NEVER hand-edit the eventtap block in `keyremaps.lua` without also updating `app.py`'s generator.** The app regenerates the entire file on every save — any manual additions that the parser doesn't understand will be silently lost. This was the root cause of the "app nukes the fix" bug: the manual `a` eventtap block was invisible to the parser, so the next UI save deleted it.

### Hammerspoon Detection (the flaky part)

`check_hammerspoon()` in `app.py` checks:
- `installed`: Does `/Applications/Hammerspoon.app` or `~/Applications/Hammerspoon.app` exist?
- `running`: `osascript -e 'application "Hammerspoon" is running'` returns "true"?
- `init_exists`: Does `~/.hammerspoon/init.lua` exist?
- `keyremaps_required`: Does `init.lua` contain an active (non-commented) `require("keyremaps")` line?

On first launch after install, one or more of these checks can fail (likely a timing issue with macOS process launch or file system access). The exact root cause is unknown and the user does NOT want it investigated.

### Frontend Init Flow

`init()` in `static/app.js`:
1. Calls `checkHammerspoon()` → `GET /api/hammerspoon`
2. If Hammerspoon check fails → shows onboarding overlay, wires up buttons
3. Loads keyboard layout, renders keyboard, sets up event listeners

### Onboarding Overlay (in `templates/index.html`)

The `#onboarding` div is a full-screen overlay with 3 steps:
1. Install Hammerspoon (download link)
2. Launch Hammerspoon
3. Create config file (button calls `POST /api/create-init`)

It has a "Check again" button (`#btn-refresh-check`) and a "Continue anyway" button (`#btn-continue-anyway`).

### API Endpoints (in `app.py`)

- `GET /api/layout` — returns keyboard layout JSON (calls Swift helper)
- `GET /api/remaps` — returns current remaps from `keyremaps.lua` (as `{modifiers, key, output}` where `key` is a Hammerspoon key name like "a", ";", "1")
- `POST /api/remaps` — saves remaps to `keyremaps.lua` (regenerates the entire file in eventtap format)
- `DELETE /api/remaps?index=N` — deletes a remap by index
- `GET /api/hammerspoon` — returns `{installed, running, init_exists, keyremaps_required}`
- `POST /api/reload` — triggers `hs.reload()` via AppleScript
- `POST /api/create-init` — creates/repairs `~/.hammerspoon/init.lua` with `require("keyremaps")` + pathwatcher

### Environment

- macOS, arm64, Darwin 27
- Python 3.9.6 at `/usr/bin/python3`
- Swift 6.2.3
- No Flask — backend uses stdlib `http.server` only
- Hammerspoon IS installed on this machine at `/Applications/Hammerspoon.app`
- `~/.hammerspoon/init.lua` exists and contains `require("keyremaps")` + pathwatcher
- `~/.hammerspoon/keyremaps.lua` exists (managed by the app, eventtap format)

### Build, Uninstall, and Rebuild Workflow

**IMPORTANT: Always uninstall the old app and rebuild the DMG when making changes.** The user installs by opening the DMG and dragging to Applications, so the DMG must always be current.

The canonical DMG lives at:
```
/Users/malachyfernandez/Documents/1-programing/applications/keyRemaper/releases/KeyRemapper-1.0.dmg
```

**Full rebuild + reinstall workflow:**
```bash
# 1. Kill any running instance
pkill -f "keyremapper" 2>/dev/null; pkill -f "KeyRemapper" 2>/dev/null

# 2. Uninstall the old app (LEAVES .lua files untouched)
rm -rf /Applications/KeyRemapper.app

# 3. Rebuild the app + DMG (build_dmg.sh runs build.sh first, so this is the only command needed)
cd /Users/malachyfernandez/Documents/1-programing/applications/keyRemaper/codebase
./build_dmg.sh

# 4. Copy the new DMG to the releases folder (this is the canonical DMG going forward)
cp .build/KeyRemapper-1.0.dmg /Users/malachyfernandez/Documents/1-programing/applications/keyRemaper/releases/KeyRemapper-1.0.dmg

# 5. User installs by opening the DMG and dragging to Applications
open /Users/malachyfernandez/Documents/1-programing/applications/keyRemaper/releases/KeyRemapper-1.0.dmg
```

**DO NOT copy the DMG to the Desktop.** The user does not want DMGs left on the Desktop. The releases folder is the single source of truth.

**The `.lua` files in `~/.hammerspoon/` must NEVER be touched when uninstalling.** The app manages `keyremaps.lua` but the user's existing remaps must survive uninstall/reinstall. Only the app binary in `/Applications/KeyRemapper.app` is removed.

**Build commands reference:**
- `./build.sh` — builds `.build/KeyRemapper.app` only
- `./build_dmg.sh` — builds the app AND the DMG (runs `build.sh` first)
- Build output is in `codebase/.build/`
- The DMG is `codebase/.build/KeyRemapper-1.0.dmg` after building

**Testing the app without installing:**
```bash
cd /Users/malachyfernandez/Documents/1-programing/applications/keyRemaper/codebase
python3 app.py 5188 &   # start server on a test port
curl -s http://127.0.0.1:5188/api/remaps | python3 -m json.tool  # verify API
pkill -f "python3 app.py 5188"  # stop test server
```

**Verifying the lua file round-trips correctly:**
```python
import sys
sys.path.insert(0, "/Users/malachyfernandez/Documents/1-programing/applications/keyRemaper/codebase")
from app import parse_remaps, generate_remaps_lua, KEYREMAPS_FILE
content = KEYREMAPS_FILE.read_text()
remaps = parse_remaps(content)
new_content = generate_remaps_lua(remaps)
assert parse_remaps(new_content) == remaps, "round-trip failed"
print(f"OK: {len(remaps)} remaps round-trip cleanly")
```

**Validating lua syntax** (requires `brew install lua`):
```bash
luac -p ~/.hammerspoon/keyremaps.lua && echo "Lua syntax OK"
```

### Server log / port

- Server log: `/tmp/keyremapper-server.log`
- Port file: `/tmp/keyremapper-port` (the app writes the chosen port here so the Swift layer can read it)

### What NOT to Change

- The `serverProcess` property in `KeyRemapperApp.swift` — this is the fix for the server-dying bug. Don't remove it.
- The synchronous AppleScript wrapper in `build.sh` — don't add backgrounding.
- The `ThreadingMixIn` in `app.py` — needed for concurrent WKWebView requests.
- The `keyremapper://` custom URL scheme in `KeyRemapperApp.swift` — this bypasses ATS.
- The `MOD_ORDER` in `app.py` and the `sig()` function order in the eventtap boilerplate — they MUST match. Both use `capslock+shift+alt+ctrl`.
- The `KEY_CODE_TO_NAME` / `KEY_NAME_TO_CODE` tables in `app.py` — they MUST match `US_KEY_NAMES` in `static/app.js`.
- The eventtap format in `keyremaps.lua` — the generator and parser are a matched pair. Don't change one without the other.
