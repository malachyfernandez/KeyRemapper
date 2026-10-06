# Option-key hotkeys broken on macOS 27 (Sequoia+)

## Summary

On macOS 27 (Darwin 27.0.0, build 26A5406e), Hammerspoon hotkeys bound with
`hs.hotkey.bind` where the **only** modifiers are `alt` (Option) — and in some
cases `shift`+`alt` (Shift+Option) — **register successfully but never fire**.

This affected the following remaps in `~/.hammerspoon/keyremaps.lua`:

| Binding            | Output | Status before fix        |
|--------------------|--------|--------------------------|
| `alt` + `a`        | `∀`    | Registered, never fired   |
| `shift`+`alt` + `a`| `¬`    | Registered, never fired   |

The binding `shift`+`alt` + `e` → `∄` continued to work, which is what made
this hard to diagnose — the failure was key-specific, not a blanket failure
of all Option-based hotkeys.

## Root cause

This is **not** a Hammerspoon bug. It is an intentional change by Apple.

Starting with **macOS Sequoia (15)**, Apple stopped delivering global hotkeys
whose only modifiers are Option (or Shift+Option) when they are registered via
the Carbon `RegisterEventHotKey` API — which is the API `hs.hotkey.bind` uses
internally.

- The hotkey **registers** successfully (`RegisterEventHotKey` returns noErr,
  and `hs.hotkey.bind` returns a valid hotkey object, not `nil`).
- macOS simply **never routes the keypress** to the registered handler.
- `hs.hotkey.assignable(...)` returns `false` for these combos, but that
  function is documented as unreliable for this purpose and returns `false`
  even for combos that *do* work (e.g. `shift`+`alt`+`e`), so it cannot be
  used as a discriminator.

References:
- Hammerspoon issue #3699 — "Global Hotkeys on Sequoia: hs.hotkey.bind({'alt'}, 'a' ...) still working?"
  https://github.com/Hammerspoon/hammerspoon/issues/3699
- Shottr KB — "MacOS Sequoia and Opt-based hotkeys"
  https://shottr.cc/kb/sequoia
- Apple Developer Forums thread 763878 (linked from the Shottr KB)

## Why `shift`+`alt`+`e` worked but `shift`+`alt`+`a` didn't

This was the confusing part. All of these keys produce OS-level characters
on the US layout (none are dead keys):

- `Option+A` → `å`
- `Option+Shift+A` → `Å`
- `Option+E` → (dead key: acute accent)
- `Option+Shift+E` → `´`
- `Option+Z` → `Ω`
- `Option+U` → (dead key: diaeresis)

The difference in behavior is **not** explained by the dead-key vs. direct-
character distinction — both `a` and `z` produce direct characters, yet
`shift`+`alt`+`a` failed while `shift`+`alt`+`z` worked. The failure appears
to be inconsistent and layout/key-specific rather than following a clean
rule. The only reliable takeaway is: **Option-only and Shift+Option global
hotkeys registered via `RegisterEventHotKey` are unreliable on Sequoia+**,
and whether a specific combo survives is not predictable.

## What was tried

### 1. `hs.hotkey.assignable` / `hs.hotkey.systemAssigned`

Both were queried for the failing and working combos. `assignable` returned
`false` for **every** Option-based combo, including ones that work. Not a
useful signal here.

### 2. Checking whether `hs.hotkey.bind` returns `nil`

It does not. `hs.hotkey.bind({"alt"}, "a", ...)` returns a valid hotkey object
on macOS 27 — the bind "succeeds" at the API level. The failure is purely at
the event-delivery stage, so checking the return value cannot detect it.

### 3. Fire-logging diagnostic

A temporary diagnostic bound log-only callbacks for `alt+a`, `shift+alt+a`,
`alt+e`, `shift+alt+e`, `shift+alt+z`, and `alt+u`, writing to `/tmp/hs_fire.txt`
when each fired. **This step shadowed the user's real bindings** (Hammerspoon
only allows one active binding per key combo), which temporarily broke all the
remapped letters. The diagnostic was removed and the file restored.

Lesson: when testing hotkey firing with duplicate `hs.hotkey.bind` calls,
they will **replace** the existing binding rather than coexist. Use a single
binding that both logs and performs the real action, or delete the original
first.

## The fix

Replace `hs.hotkey.bind` with an `hs.eventtap` for the affected combos. An
eventtap intercepts raw `CGEvent` key events at the HID event tap level
**before** macOS's hotkey-suppression logic runs, so Option-only and
Shift+Option combos fire reliably.

Applied to the two `a` bindings:

```lua
hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
    local flags = event:getFlags()
    if event:getKeyCode() == hs.keycodes.map.a
       and flags.alt and not flags.cmd and not flags.ctrl and not flags.fn then
        if flags.shift then
            hs.eventtap.keyStrokes("¬")
        else
            hs.eventtap.keyStrokes("∀")
        end
        return true   -- swallow the original event
    end
    return false      -- let everything else through
end):start()
```

This preserves the exact key combinations the user originally coded
(`alt+a` and `shift+alt+a`) — no modifier changes required.

## Why `hs.eventtap.keyStrokes` is not the culprit

`hs.eventtap.keyStrokes` (source: `extensions/eventtap/libeventtap.m`,
function `eventtap_keyStrokes`) sets `CGEventSetFlags(..., 0)` and writes the
target character via `CGEventKeyboardSetUnicodeString`. It explicitly clears
modifier flags, so held modifiers cannot corrupt the output. If a hotkey
callback fires, `keyStrokes` will type the correct character. The bug was
entirely that the callback never fired.

## Recommendation (implemented)

All remaps in `keyremaps.lua` have been migrated from `hs.hotkey.bind` to a
single `hs.eventtap`. Rather than converting only the broken combos (which
is unpredictable — see "Why `shift`+`alt`+e` worked but `shift`+`alt`+a`
didn't" above), the entire remap set now uses the eventtap approach.

### New file format

`keyremaps.lua` now contains a flat `remaps` table + a single eventtap:

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

Key design points:
- **Numeric keycodes** (not `hs.keycodes.map[name]`) — layout-independent.
- **Modifier signature** includes `cmd` and `fn` so combos carrying them
  produce a signature with no matching entry and pass through untouched.
- **Auto-repeat allowed** — held keys repeat the output (unlike
  `hs.hotkey.bind` which fires once).
- **No re-entrancy loop** — `keyStrokes` clears flags to 0, so the
  re-entrant event has signature `""` which matches no entry.

### Why all remaps, not just the broken ones

- The failure is key-specific and unpredictable (no clean rule separates
  working from broken Option combos).
- The KeyRemapper app regenerates the entire file on save, so a hybrid
  approach (eventtap for some, `hs.hotkey.bind` for others) would require
  the app to maintain two code paths and a "known-broken keys" list.
- One system (eventtap) is simpler for the app to generate and parse, and
  is future-proof if Apple expands the suppression.

## Environment

- macOS: 27.0.0 (Build 26A5406e)
- Hammerspoon: installed at `/Applications/Hammerspoon.app` (PID 10701)
- Config: `~/.hammerspoon/init.lua` → requires `~/.hammerspoon/keyremaps.lua`
- Auto-reload: `hs.pathwatcher` on `keyremaps.lua` triggers `hs.reload()`
