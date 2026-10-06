/* ── KeyRemapper — frontend logic ─────────────────────────────── */

// ── Keyboard physical layout (ANSI, key codes) ─────────────────
const KEYBOARD_LAYOUT = [
    [ // Number row
        { code: 50, w: 1 },
        { code: 18, w: 1 }, { code: 19, w: 1 }, { code: 20, w: 1 },
        { code: 21, w: 1 }, { code: 23, w: 1 }, { code: 22, w: 1 },
        { code: 26, w: 1 }, { code: 28, w: 1 }, { code: 25, w: 1 },
        { code: 29, w: 1 }, { code: 27, w: 1 }, { code: 24, w: 1 },
        { code: 51, w: 2, special: true, label: "⌫" },
    ],
    [ // Tab row
        { code: 48, w: 1.5, special: true, label: "Tab" },
        { code: 12, w: 1 }, { code: 13, w: 1 }, { code: 14, w: 1 },
        { code: 15, w: 1 }, { code: 17, w: 1 }, { code: 16, w: 1 },
        { code: 32, w: 1 }, { code: 34, w: 1 }, { code: 31, w: 1 },
        { code: 35, w: 1 }, { code: 33, w: 1 }, { code: 30, w: 1 },
        { code: 42, w: 1.5 },
    ],
    [ // Caps row
        { code: 57, w: 1.75, special: true, label: "Caps" },
        { code: 0, w: 1 }, { code: 1, w: 1 }, { code: 2, w: 1 },
        { code: 3, w: 1 }, { code: 5, w: 1 }, { code: 4, w: 1 },
        { code: 38, w: 1 }, { code: 40, w: 1 }, { code: 37, w: 1 },
        { code: 41, w: 1 }, { code: 39, w: 1 },
        { code: 36, w: 2.25, special: true, label: "⏎" },
    ],
    [ // Shift row
        { code: 56, w: 2.25, special: true, label: "⇧" },
        { code: 6, w: 1 }, { code: 7, w: 1 }, { code: 8, w: 1 },
        { code: 9, w: 1 }, { code: 11, w: 1 }, { code: 45, w: 1 },
        { code: 46, w: 1 }, { code: 43, w: 1 }, { code: 47, w: 1 },
        { code: 44, w: 1 },
        { code: 60, w: 2.75, special: true, label: "⇧" },
    ],
    [ // Bottom row
        { code: 63, w: 1.25, special: true, label: "fn" },
        { code: 59, w: 1.25, special: true, label: "⌃" },
        { code: 58, w: 1.25, special: true, label: "⌥" },
        { code: 55, w: 1.25, special: true, label: "⌘" },
        { code: 49, w: 6.25, special: true, label: "Space" },
        { code: 54, w: 1.25, special: true, label: "⌘" },
        { code: 61, w: 1.25, special: true, label: "⌥" },
    ],
];

// Keys that are modifiers or special — can't be remapped directly
const NON_REMAPPABLE = new Set([56, 57, 58, 59, 60, 61, 54, 55, 63]);

// ── JS event.code → macOS key code ─────────────────────────────
const CODE_TO_KEYCODE = {
    KeyA: 0, KeyS: 1, KeyD: 2, KeyF: 3, KeyH: 4, KeyG: 5,
    KeyZ: 6, KeyX: 7, KeyC: 8, KeyV: 9, KeyB: 11,
    KeyQ: 12, KeyW: 13, KeyE: 14, KeyR: 15, KeyY: 16, KeyT: 17,
    Digit1: 18, Digit2: 19, Digit3: 20, Digit4: 21,
    Digit6: 22, Digit5: 23, Equal: 24, Digit9: 25,
    Digit7: 26, Minus: 27, Digit8: 28, Digit0: 29,
    BracketRight: 30, KeyO: 31, KeyU: 32, BracketLeft: 33,
    KeyI: 34, KeyP: 35, Enter: 36, KeyL: 37, KeyJ: 38,
    Quote: 39, KeyK: 40, Semicolon: 41, Backslash: 42,
    Comma: 43, Slash: 44, KeyN: 45, KeyM: 46, Period: 47,
    Tab: 48, Space: 49, Backquote: 50, Backspace: 51,
    Escape: 53,
};

// ── US layout key names for Hammerspoon bindings ─────────────────
const US_KEY_NAMES = {
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
};

// ── State ───────────────────────────────────────────────────────
let layoutData = null;       // keyboard layout from Swift helper
let remaps = [];             // current remaps from keyremaps.lua
let toggleMods = {           // modifier toggle state (on-screen buttons)
    shift: false, option: false, control: false, caps: false,
};
let physicalMods = {         // modifier state from physical key presses
    shift: false, option: false, control: false, caps: false,
};
let selectedKeyCode = null;  // currently selected key for remapping
let selectedMods = null;     // modifiers at time of selection

// Effective modifier state = toggle OR physical (union)
function effectiveMods() {
    return {
        shift: toggleMods.shift || physicalMods.shift,
        option: toggleMods.option || physicalMods.option,
        control: toggleMods.control || physicalMods.control,
        caps: toggleMods.caps || physicalMods.caps,
    };
}

// For backwards compat, modState is a getter
function getModState() { return effectiveMods(); }

// ── Utility: modifier state → API name ──────────────────────────
function getModName(state) {
    const parts = [];
    if (state.caps) parts.push("caps");
    if (state.control) parts.push("ctrl");
    if (state.shift) parts.push("shift");
    if (state.option) parts.push("option");
    return parts.length === 0 ? "none" : parts.join("_");
}

// ── Utility: modifier state → Hammerspoon modifier list ─────────
function getHSMods(state) {
    const mods = [];
    if (state.shift) mods.push("shift");
    if (state.option) mods.push("alt");
    if (state.control) mods.push("ctrl");
    if (state.caps) mods.push("capslock");
    return mods;
}

// ── Utility: readable modifier string ──────────────────────────
function modDisplayString(state) {
    const parts = [];
    if (state.caps) parts.push("⇪");
    if (state.control) parts.push("⌃");
    if (state.shift) parts.push("⇧");
    if (state.option) parts.push("⌥");
    return parts.join(" + ");
}

// Build combo HTML with grey "+" separators so they don't visually
// compete with the accent-colored key symbols.
const SEP = ' <span class="combo-sep">+</span> ';
function comboHTML(modStr, key) {
    if (!modStr) return escapeHTML(key);
    // modStr may contain " + " between multiple modifiers (e.g. "⇧ + ⌥").
    // Split on " + " and rejoin with styled separators, then add the key.
    const parts = modStr.split(" + ").map(escapeHTML);
    return parts.join(SEP) + SEP + escapeHTML(key);
}

function escapeHTML(s) {
    // Only escape characters that could break HTML.
    // Using char codes to avoid entity decoding issues in editors.
    return String(s)
        .replace(/&/g, String.fromCharCode(38) + "amp;")
        .replace(/</g, String.fromCharCode(38) + "lt;")
        .replace(/>/g, String.fromCharCode(38) + "gt;")
        .replace(/"/g, String.fromCharCode(38) + "quot;")
        .replace(/'/g, String.fromCharCode(38) + "#39;");
}

// ── API ─────────────────────────────────────────────────────────

async function fetchLayout() {
    const res = await fetch("/api/layout");
    layoutData = await res.json();
    if (layoutData.error) {
        console.error("Layout error:", layoutData.error);
        document.getElementById("layout-name").textContent = "Error";
        return;
    }
    document.getElementById("layout-name").textContent = layoutData.layout_name || "Unknown";
}

async function fetchRemaps() {
    const res = await fetch("/api/remaps");
    const data = await res.json();
    remaps = data.remaps || [];
    renderRemaps();
    updateKeyRemapIndicators();
}

async function saveRemaps() {
    const res = await fetch("/api/remaps", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ remaps }),
    });
    return res.ok;
}

async function reloadHS() {
    const res = await fetch("/api/reload", { method: "POST" });
    return res.ok;
}

async function exportRemaps() {
    const res = await fetch("/api/export", { method: "POST" });
    return res.json();
}

async function importRemaps(file) {
    const content = await file.text();
    const res = await fetch("/api/import", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: file.name, content }),
    });
    return res.json();
}

// Open a URL in the real default browser — window.open is a no-op
// inside the app's WKWebView, so we bounce through the native bridge.
function openExternal(url) {
    try {
        window.webkit.messageHandlers.openExternal.postMessage(url);
    } catch (e) {
        window.open(url, "_blank"); // browser-preview fallback
    }
}

// ── Theme ───────────────────────────────────────────────────────
const THEME_KEY = "keyremapper_theme";

function currentTheme() {
    return document.documentElement.dataset.theme || "apple";
}

function setTheme(theme) {
    document.documentElement.dataset.theme = theme;
    try { localStorage.setItem(THEME_KEY, theme); } catch (e) {}
    syncThemeSeg();
}

function syncThemeSeg() {
    const t = currentTheme();
    document.querySelectorAll("#theme-seg .seg").forEach(b => {
        b.classList.toggle("active", b.dataset.theme === t);
    });
}

// ── Settings sheet ──────────────────────────────────────────────

function settingsOpen() {
    return !document.getElementById("settings").classList.contains("hidden");
}

function troubleshootOpen() {
    return !document.getElementById("troubleshoot").classList.contains("hidden");
}

function openTroubleshoot() {
    document.getElementById("troubleshoot").classList.remove("hidden");
    document.querySelectorAll("#troubleshoot video").forEach(v => v.play().catch(() => {}));
}

function closeTroubleshoot() {
    document.getElementById("troubleshoot").classList.add("hidden");
    document.querySelectorAll("#troubleshoot video").forEach(v => v.pause());
}

function openSettings() {
    syncThemeSeg();
    document.getElementById("remap-count").textContent = remaps.length;
    document.getElementById("settings").classList.remove("hidden");
}

function closeSettings() {
    document.getElementById("settings").classList.add("hidden");
}

function setupSettings() {
    const sheet = document.getElementById("settings");
    const tSheet = document.getElementById("troubleshoot");
    document.getElementById("troubleshoot-btn").addEventListener("click", openTroubleshoot);
    document.getElementById("troubleshoot-close").addEventListener("click", closeTroubleshoot);
    tSheet.addEventListener("click", (e) => {
        if (e.target === tSheet) closeTroubleshoot();
    });
    document.getElementById("settings-btn").addEventListener("click", openSettings);
    document.getElementById("settings-close").addEventListener("click", closeSettings);
    sheet.addEventListener("click", (e) => {
        if (e.target === sheet) closeSettings();
    });

    document.querySelectorAll("#theme-seg .seg").forEach(btn => {
        btn.addEventListener("click", () => setTheme(btn.dataset.theme));
    });

    document.getElementById("btn-refresh-layout").addEventListener("click", async () => {
        await fetchLayout();
        renderKeyboard();
    });

    document.getElementById("btn-settings-reload").addEventListener("click", reloadHS);

    document.getElementById("btn-repair-init").addEventListener("click", async () => {
        const status = document.getElementById("export-status");
        const row = document.getElementById("export-status-row");
        const result = await createInitFile();
        row.style.display = "";
        status.textContent = result.ok ? "init.lua configured" : (result.error || "Failed");
    });

    document.getElementById("btn-export").addEventListener("click", async () => {
        const status = document.getElementById("export-status");
        const row = document.getElementById("export-status-row");
        try {
            const result = await exportRemaps();
            row.style.display = "";
            status.textContent = result.ok
                ? "Saved to " + (result.path || "Downloads")
                : (result.error || "Export failed");
        } catch (e) {
            row.style.display = "";
            status.textContent = "Export failed";
        }
    });

    const importInput = document.getElementById("import-file");
    document.getElementById("btn-import").addEventListener("click", () => importInput.click());
    importInput.addEventListener("change", async () => {
        const status = document.getElementById("export-status");
        const row = document.getElementById("export-status-row");
        const file = importInput.files[0];
        importInput.value = "";
        if (!file) return;
        if (!file.name.toLowerCase().endsWith(".lua")) {
            row.style.display = "";
            status.textContent = "Needs a .lua file";
            return;
        }
        try {
            const result = await importRemaps(file);
            row.style.display = "";
            if (result.ok) {
                remaps = result.remaps || [];
                renderRemaps();
                updateKeyRemapIndicators();
                reloadHS();
                status.textContent = `Imported ${remaps.length} remap${remaps.length === 1 ? "" : "s"}`;
            } else {
                status.textContent = result.error || "Import failed";
            }
        } catch (e) {
            row.style.display = "";
            status.textContent = "Import failed";
        }
    });
}

// ── Rendering ───────────────────────────────────────────────────

function getKeyChar(keyCode) {
    if (!layoutData || !layoutData.keys) return "";
    const modName = getModName(effectiveMods());
    const modKeys = layoutData.keys[modName];
    if (!modKeys) return "";
    return modKeys[String(keyCode)] || "";
}

function getBaseChar(keyCode) {
    if (!layoutData || !layoutData.keys) return "";
    const noneKeys = layoutData.keys["none"];
    if (!noneKeys) return "";
    return noneKeys[String(keyCode)] || "";
}

function getHSKeyName(keyCode) {
    return US_KEY_NAMES[keyCode] || String(keyCode);
}

function renderKeyboard() {
    const kb = document.getElementById("keyboard");
    kb.innerHTML = "";

    for (const row of KEYBOARD_LAYOUT) {
        const rowEl = document.createElement("div");
        rowEl.className = "kb-row";

        for (const keyDef of row) {
            const keyEl = document.createElement("div");
            const wClass = `w-${String(keyDef.w).replace(".", "-")}`;
            keyEl.className = `key ${wClass}`;
            if (keyDef.special) keyEl.classList.add("special");
            if (NON_REMAPPABLE.has(keyDef.code)) keyEl.classList.add("modifier-key");
            keyEl.dataset.code = keyDef.code;

            if (keyDef.special) {
                const charSpan = document.createElement("span");
                charSpan.className = "key-char";
                charSpan.textContent = keyDef.label;
                keyEl.appendChild(charSpan);
            } else {
                // Key has two layers: original (greyed) on top, active char below
                const originalSpan = document.createElement("span");
                originalSpan.className = "key-original";
                originalSpan.textContent = getBaseChar(keyDef.code) || "";

                const charSpan = document.createElement("span");
                charSpan.className = "key-char";
                charSpan.textContent = getKeyChar(keyDef.code) || "";

                keyEl.appendChild(originalSpan);
                keyEl.appendChild(charSpan);
            }

            if (!NON_REMAPPABLE.has(keyDef.code)) {
                keyEl.addEventListener("click", () => selectKey(keyDef.code, { ...effectiveMods() }));
            }

            rowEl.appendChild(keyEl);
        }
        kb.appendChild(rowEl);
    }

    updateKeyRemapIndicators();
}

function updateKeyChars() {
    const keys = document.querySelectorAll(".key");
    for (const keyEl of keys) {
        const code = parseInt(keyEl.dataset.code);
        if (keyEl.classList.contains("special")) continue;
        const charSpan = keyEl.querySelector(".key-char");
        if (charSpan) {
            charSpan.textContent = getKeyChar(code) || "";
        }
    }
    // Also update remap indicators (which may override the char display)
    updateKeyRemapIndicators();
}

// Find the remap for a key code + current effective modifier state
function findRemapForKey(keyCode) {
    const keyName = getHSKeyName(keyCode);
    const eff = effectiveMods();
    return remaps.find(r => r.key === keyName && modsMatch(r.modifiers, eff));
}

function updateKeyRemapIndicators() {
    const keys = document.querySelectorAll(".key");
    for (const keyEl of keys) {
        const code = parseInt(keyEl.dataset.code);
        const keyName = getHSKeyName(code);
        const hasRemap = remaps.some(r => r.key === keyName);
        keyEl.classList.toggle("has-remap", hasRemap);

        // If this key has an active remap for the current modifier state,
        // show the remapped output as the main char and grey out the original
        const remap = findRemapForKey(code);
        const charSpan = keyEl.querySelector(".key-char");
        const originalSpan = keyEl.querySelector(".key-original");
        if (remap && charSpan && originalSpan) {
            charSpan.textContent = remap.output;
            // Show what the key would normally produce with the current
            // modifier state (e.g. "+" for Shift+=, not just "=")
            originalSpan.textContent = getKeyChar(code) || getBaseChar(code) || "";
            originalSpan.style.opacity = "0.35";
            keyEl.classList.add("remapped");
        } else if (charSpan && originalSpan) {
            charSpan.textContent = getKeyChar(code) || "";
            originalSpan.textContent = getBaseChar(code) || "";
            originalSpan.style.opacity = "";
            keyEl.classList.remove("remapped");
        }
    }
}

function highlightKey(keyCode) {
    const keyEl = document.querySelector(`.key[data-code="${keyCode}"]`);
    if (!keyEl) return;
    keyEl.classList.add("pressed");
    setTimeout(() => keyEl.classList.remove("pressed"), 200);
}

function selectKey(keyCode, mods) {
    if (NON_REMAPPABLE.has(keyCode)) return;

    // Clear previous selection
    document.querySelectorAll(".key.selected").forEach(el => el.classList.remove("selected"));

    selectedKeyCode = keyCode;
    selectedMods = mods;

    // Highlight on virtual keyboard
    const keyEl = document.querySelector(`.key[data-code="${keyCode}"]`);
    if (keyEl) keyEl.classList.add("selected");

    // Show remap panel
    const panel = document.getElementById("remap-panel");
    panel.classList.remove("hidden");

    const modStr = modDisplayString(mods);
    const keyName = getHSKeyName(keyCode);
    document.getElementById("remap-combo").innerHTML = comboHTML(modStr, keyName);

    const osChar = getBaseChar(keyCode);
    document.getElementById("remap-os-char").textContent = osChar || "(special)";

    // Check for existing remap
    const existing = remaps.find(r => {
        return r.key === keyName && modsMatch(r.modifiers, mods);
    });

    const existingBadge = document.getElementById("remap-existing");
    const output = document.getElementById("remap-output");
    if (existing) {
        existingBadge.classList.remove("hidden");
        output.value = existing.output;
    } else {
        existingBadge.classList.add("hidden");
        output.value = "";
    }

    output.focus();
}

function modsMatch(hsMods, state) {
    const expected = new Set(getHSMods(state));
    if (hsMods.length !== expected.size) return false;
    return hsMods.every(m => expected.has(m));
}

function renderRemaps() {
    const container = document.getElementById("remaps-container");

    if (remaps.length === 0) {
        container.innerHTML = '<p class="muted empty-msg">No remaps yet. Select a key to begin.</p>';
        return;
    }

    container.innerHTML = "";
    remaps.forEach((r, i) => {
        const item = document.createElement("div");
        item.className = "remap-item";

        const info = document.createElement("div");
        info.className = "remap-item-info";

        // Plain-text combo like macOS shows shortcuts: ⇧⌥; → ⋯
        const modSymbols = { shift: "⇧", alt: "⌥", ctrl: "⌃", cmd: "⌘", capslock: "⇪" };
        const combo = document.createElement("span");
        combo.className = "remap-key";
        combo.textContent = r.modifiers.map(m => modSymbols[m] || m).join("") + " " + r.key;

        const arrow = document.createElement("span");
        arrow.className = "remap-arrow";
        arrow.textContent = "→";

        const outSpan = document.createElement("span");
        outSpan.className = "remap-output";
        outSpan.textContent = r.output || "(empty)";
        outSpan.title = r.output;

        info.appendChild(combo);
        info.appendChild(arrow);
        info.appendChild(outSpan);

        const delBtn = document.createElement("button");
        delBtn.className = "remap-delete";
        delBtn.textContent = "✕";
        delBtn.title = "Delete remap";
        delBtn.addEventListener("click", () => deleteRemap(i));

        item.appendChild(info);
        item.appendChild(delBtn);
        container.appendChild(item);
    });
}

// ── Toast ───────────────────────────────────────────────────────
let toastTimer = null;
function showToast(msg) {
    const el = document.getElementById("toast");
    el.textContent = msg;
    el.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove("show"), 2600);
}

function remapLabel(r) {
    const modSymbols = { shift: "⇧", alt: "⌥", ctrl: "⌃", cmd: "⌘", capslock: "⇪" };
    const mods = r.modifiers.map(m => modSymbols[m] || m).join("");
    return mods ? mods + " " + r.key : r.key;
}

async function deleteRemap(index) {
    const removed = remaps[index];
    remaps.splice(index, 1);
    await saveRemaps();
    renderRemaps();
    updateKeyRemapIndicators();
    reloadHS();
    showToast(`Removed ${remapLabel(removed)}`);
}

async function saveRemap() {
    if (selectedKeyCode === null) return;

    const output = document.getElementById("remap-output").value;

    const keyName = getHSKeyName(selectedKeyCode);
    const hsMods = getHSMods(selectedMods);

    // Find and update existing, or add new
    const existingIdx = remaps.findIndex(r => r.key === keyName && modsMatch(r.modifiers, selectedMods));

    // Saving an empty output over an existing remap removes it —
    // same as the ✕ button in the list.
    if (!output) {
        if (existingIdx >= 0) {
            const removed = remaps[existingIdx];
            remaps.splice(existingIdx, 1);
            await saveRemaps();
            renderRemaps();
            updateKeyRemapIndicators();
            reloadHS();
            showToast(`Removed ${remapLabel(removed)}`);
            cancelRemap();
        }
        return;
    }

    const remap = { modifiers: hsMods, key: keyName, output };

    if (existingIdx >= 0) {
        remaps[existingIdx] = remap;
    } else {
        remaps.push(remap);
    }

    await saveRemaps();
    renderRemaps();
    updateKeyRemapIndicators();
    reloadHS();

    // Close panel
    cancelRemap();
}

function cancelRemap() {
    document.getElementById("remap-panel").classList.add("hidden");
    document.querySelectorAll(".key.selected").forEach(el => el.classList.remove("selected"));
    selectedKeyCode = null;
    selectedMods = null;
    // Clear clicked (toggled) modifiers — the pills would otherwise stay
    // lit even though nothing is pressed or being edited anymore.
    toggleMods = { shift: false, option: false, control: false, caps: false };
    updateModButtons();
    updateKeyChars();
}

// ── Modifier toggle buttons (on-screen) ───────────────────────

function setupModifierButtons() {
    document.querySelectorAll(".mod-btn[data-mod]").forEach(btn => {
        btn.addEventListener("click", () => {
            const mod = btn.dataset.mod;
            toggleMods[mod] = !toggleMods[mod];
            updateModButtons();
            updateKeyChars();
        });
    });

    document.getElementById("clear-mods").addEventListener("click", () => {
        toggleMods = { shift: false, option: false, control: false, caps: false };
        updateModButtons();
        updateKeyChars();
    });
}

// Update on-screen modifier buttons to reflect toggle + physical state
function updateModButtons() {
    const eff = effectiveMods();
    document.querySelectorAll(".mod-btn[data-mod]").forEach(btn => {
        const mod = btn.dataset.mod;
        btn.classList.toggle("active", eff[mod]);
    });
}

// ── Physical keyboard capture ──────────────────────────────────

function setupKeyCapture() {
    const overlay = document.getElementById("focus-overlay");

    // Show/hide overlay based on whether the webview has keyboard focus.
    // When the webview loses focus, keyboard events stop entirely.
    function showOverlay() { overlay.classList.remove("focused"); }
    function hideOverlay() { overlay.classList.add("focused"); }

    // Clicking the overlay focuses the webview
    overlay.addEventListener("click", () => {
        window.focus();
        document.body.focus();
        hideOverlay();
    });

    // Any keydown means we have focus — hide overlay
    document.addEventListener("keydown", (e) => {
        hideOverlay();

        // While a sheet is open, keys are not remap input.
        if (settingsOpen() || troubleshootOpen()) {
            if (e.key === "Escape") {
                e.preventDefault();
                closeSettings();
                closeTroubleshoot();
            }
            return;
        }

        // Don't capture if typing in the output field
        if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") return;

        // Update physical modifier state from the event
        updatePhysicalMods(e);
        updateModButtons();
        updateKeyChars();

        const keyCode = CODE_TO_KEYCODE[e.code];
        if (keyCode === undefined) return;

        // Highlight the pressed key
        highlightKey(keyCode);

        // Select the key for remapping (prevent default to avoid navigation etc.)
        if (!NON_REMAPPABLE.has(keyCode)) {
            e.preventDefault();
            selectKey(keyCode, effectiveMods());
        }
    });

    // When a physical modifier key is released, update state and unhighlight.
    // If that modifier was also toggled on by a click, the release clears the
    // toggle too — press-and-release means "done with it".
    const MOD_RELEASE_CODES = {
        ShiftLeft: "shift", ShiftRight: "shift",
        AltLeft: "option", AltRight: "option",
        ControlLeft: "control", ControlRight: "control",
        CapsLock: "caps",
    };
    document.addEventListener("keyup", (e) => {
        if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA") return;

        const toggled = MOD_RELEASE_CODES[e.code];
        if (toggled) toggleMods[toggled] = false;

        updatePhysicalMods(e);
        updateModButtons();
        updateKeyChars();
    });

    // Detect focus loss — use blur/focusout on the window
    window.addEventListener("blur", () => {
        // Small delay to avoid flicker when focus moves between elements
        setTimeout(() => {
            if (!document.hasFocus()) showOverlay();
        }, 100);
    });

    window.addEventListener("focus", () => {
        hideOverlay();
    });

    // Also handle clicks anywhere in the app to ensure focus
    document.addEventListener("click", () => {
        hideOverlay();
    });

    // Start with overlay visible (webview may not have focus on launch)
    showOverlay();
}

// Update physicalMods from a keyboard event
function updatePhysicalMods(e) {
    physicalMods.shift = e.shiftKey;
    physicalMods.option = e.altKey;
    physicalMods.control = e.ctrlKey;
    physicalMods.caps = e.getModifierState ? e.getModifierState("CapsLock") : false;
}

// ── Overlay scrollbars ──────────────────────────────────────────
// Show the scrollbar thumb only while scrolling (macOS-style).
function setupScrollbars() {
    document.querySelectorAll(".remaps-sidebar, .keyboard-section, .sheet")
        .forEach(el => {
            let t;
            el.addEventListener("scroll", () => {
                el.classList.add("scrolling");
                clearTimeout(t);
                t = setTimeout(() => el.classList.remove("scrolling"), 600);
            }, { passive: true });
        });
}

// ── Init ────────────────────────────────────────────────────────

async function checkHammerspoon() {
    try {
        const res = await fetch("/api/hammerspoon");
        return await res.json();
    } catch (e) {
        return { installed: false, running: false, init_exists: false };
    }
}

async function createInitFile() {
    try {
        const res = await fetch("/api/create-init", { method: "POST" });
        return await res.json();
    } catch (e) {
        return { error: e.message };
    }
}

function updateOnboardingStatus(hs) {
    const stepInstall = document.getElementById("step-install");
    const stepInit = document.getElementById("step-init");

    const statusInstall = document.getElementById("status-install");
    const statusInit = document.getElementById("status-init");

    if (hs.installed) {
        stepInstall.classList.add("done");
        statusInstall.textContent = "✓ Installed";
    } else {
        statusInstall.textContent = "Not found";
    }

    if (hs.init_exists && hs.keyremaps_required) {
        stepInit.classList.add("done");
        statusInit.textContent = "✓ Configured";
    } else if (hs.init_exists) {
        statusInit.textContent = "Missing require(\"keyremaps\")";
    } else {
        statusInit.textContent = "Not created";
    }

    // Show "Continue anyway" if Hammerspoon is at least installed
    const continueBtn = document.getElementById("btn-continue-anyway");
    if (hs.installed && hs.init_exists && hs.keyremaps_required) {
        // Everything is ready, hide onboarding and stop watching.
        document.getElementById("onboarding").classList.add("hidden");
        stopOnboardingWatcher();
    } else if (hs.installed) {
        continueBtn.classList.remove("hidden");
    }
}

// Keep the setup checks fresh: poll every few seconds and re-check
// whenever the window regains focus — while onboarding is visible.
let onboardTimer = null;
let onboardRecheck = null;

function startOnboardingWatcher() {
    const recheck = async () => {
        if (document.getElementById("onboarding").classList.contains("hidden")) {
            stopOnboardingWatcher();
            return;
        }
        updateOnboardingStatus(await checkHammerspoon());
    };
    onboardRecheck = recheck;
    clearInterval(onboardTimer);
    onboardTimer = setInterval(recheck, 3000);
    window.addEventListener("focus", recheck);
    document.addEventListener("visibilitychange", recheck);
}

function stopOnboardingWatcher() {
    clearInterval(onboardTimer);
    onboardTimer = null;
    if (onboardRecheck) {
        window.removeEventListener("focus", onboardRecheck);
        document.removeEventListener("visibilitychange", onboardRecheck);
        onboardRecheck = null;
    }
}

async function init() {
    // Check if Hammerspoon is installed/running/configured.
    const hs = await checkHammerspoon();
    const hsReady = hs.installed && hs.init_exists && hs.keyremaps_required;

    if (!hsReady) {
        // Restart-once fallback: on first launch the Hammerspoon detection
        // can be flaky (timing). Show a welcome screen with an "Enter"
        // button; pressing it fully restarts the app (a detached watchdog
        // kills the process and reopens the bundle). The "already
        // restarted" flag is a server-side marker file because browser
        // storage is unreliable under the custom keyremapper:// scheme.
        if (!hs.just_restarted) {
            const welcome = document.getElementById("welcome");
            welcome.classList.remove("hidden");
            const restart = () => {
                fetch("/api/restart-app", { method: "POST" }).catch(() => {});
            };
            document.getElementById("btn-welcome-enter").addEventListener("click", restart);
            window.addEventListener("keydown", (e) => {
                if (e.key === "Enter") restart();
            });
            return;
        }

        // Already restarted once — show real onboarding.
        document.getElementById("onboarding").classList.remove("hidden");
        updateOnboardingStatus(hs);
        startOnboardingWatcher();

        document.getElementById("btn-refresh-check").addEventListener("click", async () => {
            const updated = await checkHammerspoon();
            updateOnboardingStatus(updated);
        });

        document.getElementById("btn-create-init").addEventListener("click", async () => {
            const result = await createInitFile();
            if (result.ok) {
                const updated = await checkHammerspoon();
                updateOnboardingStatus(updated);
            }
        });

        document.getElementById("btn-continue-anyway").addEventListener("click", () => {
            document.getElementById("onboarding").classList.add("hidden");
            stopOnboardingWatcher();
        });
    }

    await fetchLayout();
    await fetchRemaps();
    renderKeyboard();
    setupModifierButtons();
    setupKeyCapture();
    setupSettings();
    setupScrollbars();

    document.getElementById("remap-save").addEventListener("click", saveRemap);
    document.getElementById("remap-cancel").addEventListener("click", cancelRemap);


    document.getElementById("remap-output").addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
            e.preventDefault();
            saveRemap();
        } else if (e.key === "Escape") {
            e.preventDefault();
            cancelRemap();
        }
    });
}

init();
