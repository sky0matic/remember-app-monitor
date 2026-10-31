.pragma library
// Pure placement logic for Remember App Monitor. Kept free of KWin/QML APIs so it
// can be unit tested (see tests/test_logic.py); the QML files only wire it to KWin.

// rect: fractions of the monitor's usable area, [x, y, width, height]
var SECTIONS = [
    { id: "left",         label: "Left half",                rect: [0, 0, 1/2, 1] },
    { id: "right",        label: "Right half",               rect: [1/2, 0, 1/2, 1] },
    { id: "top",          label: "Top half",                 rect: [0, 0, 1, 1/2] },
    { id: "bottom",       label: "Bottom half",              rect: [0, 1/2, 1, 1/2] },
    { id: "top-left",     label: "Top-left quarter",         rect: [0, 0, 1/2, 1/2] },
    { id: "top-right",    label: "Top-right quarter",        rect: [1/2, 0, 1/2, 1/2] },
    { id: "bottom-left",  label: "Bottom-left quarter",      rect: [0, 1/2, 1/2, 1/2] },
    { id: "bottom-right", label: "Bottom-right quarter",     rect: [1/2, 1/2, 1/2, 1/2] },
    { id: "left-third",   label: "Left third",               rect: [0, 0, 1/3, 1] },
    { id: "center-third", label: "Center third",             rect: [1/3, 0, 1/3, 1] },
    { id: "right-third",  label: "Right third",              rect: [2/3, 0, 1/3, 1] },
    { id: "maximized",    label: "Maximized" },
    { id: "center",       label: "Centered (keep size)" },
    { id: "keep",         label: "Anywhere (monitor only)" }
];

var DEFAULT_SECTION = "left";

function sectionById(id) {
    return SECTIONS.find(s => s.id === id) || null;
}

function sectionIndex(id) {
    return SECTIONS.findIndex(s => s.id === id);
}

// Cleans a list of {app, section}: trims/lowercases app ids, drops empty and
// duplicate apps (first wins) and maps unknown sections to "keep".
function normalizeApps(list) {
    const seen = {};
    const out = [];
    for (const entry of list || []) {
        const app = String((entry && entry.app) || "").trim().toLowerCase();
        if (!app || seen[app]) continue;
        seen[app] = true;
        const section = String((entry && entry.section) || "").trim().toLowerCase();
        out.push({ app: app, section: sectionById(section) ? section : "keep" });
    }
    return out;
}

function parseApps(json) {
    try {
        const list = JSON.parse(json || "[]");
        return Array.isArray(list) ? normalizeApps(list) : [];
    } catch (e) {
        return [];
    }
}

function serializeApps(list) {
    return JSON.stringify(normalizeApps(list));
}

// Manual entries from the System Settings page: one "app = section" per line, # comments.
// (KWin's own windows can't receive typing, so app ids that can't be picked go there.)
function parseManualApps(text) {
    const list = [];
    for (const raw of String(text || "").split("\n")) {
        const line = raw.trim();
        if (!line || line.startsWith("#")) continue;
        const parts = line.split("=");
        list.push({ app: parts[0], section: parts.length > 1 ? parts[1] : "keep" });
    }
    return normalizeApps(list);
}

// The settings window's list first; manual entries only for apps it doesn't have.
function mergeApps(apps, manual) {
    return normalizeApps((apps || []).concat(manual || []));
}

// Manual entries that aren't overridden by the settings window's list
function manualOnly(apps, manual) {
    return (manual || []).filter(m => !(apps || []).some(a => a.app === m.app));
}

// App id for a window or a queryWindowInfo result: desktop file name when there is one,
// else its class (both are checked by findApp when matching windows)
function appIdOf(desktopFile, resourceClass, resourceName) {
    return String(desktopFile || resourceClass || resourceName || "").trim().toLowerCase();
}

// names: the window's identifiers (resource class, resource name, desktop file name)
function findApp(apps, names) {
    for (const name of names) {
        const key = String(name || "").toLowerCase();
        if (!key) continue;
        const entry = apps.find(a => a.app === key);
        if (entry) return entry;
    }
    return null;
}

// Monitors are remembered as "manufacturer|model|serial". The serial tells apart two
// monitors of the same model (e.g. at different desks); monitors that report no serial
// fall back to manufacturer + model.
function monitorId(output) {
    return [output.manufacturer || "", output.model || "", output.serialNumber || ""].join("|");
}

function parseMonitorId(id) {
    const parts = String(id || "").split("|");
    return { manufacturer: parts[0] || "", model: parts[1] || "", serial: parts[2] || "" };
}

function monitorMatches(output, id) {
    const saved = parseMonitorId(id);
    if (!saved.manufacturer && !saved.model && !saved.serial) return false;
    if ((output.manufacturer || "") !== saved.manufacturer || (output.model || "") !== saved.model) return false;
    // ids saved before serials were used have no serial part and match on model alone
    return !saved.serial || (output.serialNumber || "") === saved.serial;
}

function findOutput(screens, id) {
    return (screens || []).find(o => monitorMatches(o, id)) || null;
}

// Model names shared by monitors with different serials, among the given ids and outputs;
// those need part of the serial to be told apart. Ids without a serial (saved before
// serials were used, or from monitors that report none) don't make a model ambiguous.
function ambiguousModels(ids, screens) {
    const serials = {};
    const add = (m) => {
        if (!m.model || !m.serial) return;
        const key = m.manufacturer + "|" + m.model;
        serials[key] = serials[key] || {};
        serials[key][m.serial] = true;
    };
    for (const id of ids || []) add(parseMonitorId(id));
    for (const o of screens || []) add(parseMonitorId(monitorId(o)));
    return Object.keys(serials).filter(k => Object.keys(serials[k]).length > 1);
}

// "VG27A", or "VG27A (…0612)" when another remembered/connected VG27A exists
function monitorShortName(id, ambiguous) {
    const m = parseMonitorId(id);
    const name = m.model || m.manufacturer;
    const clash = (ambiguous || []).indexOf(m.manufacturer + "|" + m.model) !== -1;
    return clash && m.serial ? name + " (…" + m.serial.slice(-4) + ")" : name;
}

// Where an output sits relative to the main monitor, e.g. "above main monitor"
function relativePosition(output, main) {
    if (!main || output === main || monitorId(output) === monitorId(main)) return "main monitor";
    const a = output.geometry, b = main.geometry;
    const dx = (a.x + a.width / 2) - (b.x + b.width / 2);
    const dy = (a.y + a.height / 2) - (b.y + b.height / 2);
    if (Math.abs(dx) * b.height >= Math.abs(dy) * b.width) return dx < 0 ? "left of main monitor" : "right of main monitor";
    return dy < 0 ? "above main monitor" : "below main monitor";
}

// Last-seen times (ms) by monitor id. Connected monitors are seen now, and so are
// monitors that were connected until now (previousIds).
function updateSeen(seen, previousIds, currentIds, now) {
    const out = Object.assign({}, seen || {});
    for (const id of (previousIds || []).concat(currentIds || [])) if (id) out[id] = now;
    return out;
}

// Everything the settings window shows about a remembered monitor; the caller formats lastSeen.
function describeMonitor(id, screens, screenOrder, seen, ambiguous) {
    const output = findOutput(screens, id);
    const main = (screenOrder && screenOrder.length) ? screenOrder[0] : null;
    return {
        name: monitorShortName(id, ambiguous),
        connected: !!output,
        position: output ? relativePosition(output, main) : "",
        lastSeen: (seen && seen[id]) || 0,
        details: monitorDetails(id)
    };
}

// The full id (with serial) for a remembered id that lacks one, if its monitor is
// connected; otherwise the id unchanged.
function upgradeMonitorId(id, screens) {
    if (!id || parseMonitorId(id).serial) return id;
    const output = findOutput(screens, id);
    return output ? monitorId(output) : id;
}

// Short name for lists ("VG27A (ASUSTek COMPUTER INC)"); monitorDetails adds the serial.
function monitorLabel(id) {
    const m = parseMonitorId(id);
    if (!m.model) return m.manufacturer;
    return m.manufacturer ? m.model + " (" + m.manufacturer + ")" : m.model;
}

function monitorDetails(id) {
    const m = parseMonitorId(id);
    const label = monitorLabel(id);
    return m.serial ? label + ", S/N " + m.serial : label;
}

// Where a newly opened window should go:
//   {kind: "section", output} - the remembered monitor, in the app's section
//   {kind: "main", output}    - remembered monitor missing (or none yet): main monitor, as the app placed itself
function planPlacement(savedId, screens, screenOrder) {
    const output = findOutput(screens, savedId);
    if (output) return { kind: "section", output: output };
    const main = (screenOrder && screenOrder.length) ? screenOrder[0] : null;
    return { kind: "main", output: main };
}

// Frame geometry for a section inside a monitor's usable area. Returns null when
// the section doesn't set geometry ("keep", "maximized").
function sectionGeometry(sectionId, area, current) {
    const section = sectionById(sectionId);
    if (section && section.rect) {
        const f = section.rect;
        return {
            x: Math.round(area.x + area.width * f[0]),
            y: Math.round(area.y + area.height * f[1]),
            width: Math.round(area.width * f[2]),
            height: Math.round(area.height * f[3])
        };
    }
    if (sectionId === "center") {
        const width = Math.min(current.width, area.width);
        const height = Math.min(current.height, area.height);
        return {
            x: Math.round(area.x + (area.width - width) / 2),
            y: Math.round(area.y + (area.height - height) / 2),
            width: width,
            height: height
        };
    }
    return null;
}

// Apps like Discord restore their own maximized state shortly after opening; within
// the grace period that is undone so the chosen section sticks. Afterwards the user
// can maximize freely.
function shouldUndoMaximize(sectionId, msSinceOpen, maximizeMode, graceMs) {
    if (sectionId === "maximized" || sectionId === "keep") return false;
    return maximizeMode !== 0 && msSinceOpen < graceMs;
}

// Whether a window's monitor change is the user's choice. Ones right after monitors were
// plugged/unplugged are KWin evacuating windows. Moves by the user dragging the window
// always count; other moves only after the first moments, when apps that position
// themselves (X11 apps) do so.
function shouldRemember(byUser, msSinceOpen, msSinceScreensChanged, graceMs, settleMs) {
    if (msSinceScreensChanged < settleMs) return false;
    return byUser || msSinceOpen >= graceMs;
}

// When an app's window closes, its monitor is remembered only if none is yet: an app
// that opened on the main monitor because its remembered one is unplugged must not
// lose it. Closes right after monitors were plugged/unplugged are ignored too.
function shouldRememberOnClose(savedId, msSinceScreensChanged, settleMs) {
    return !savedId && msSinceScreensChanged >= settleMs;
}

// Suggestions for the app picker: open windows first (with their caption), then
// installed desktop entries, one per app id.
function buildSuggestions(windows, desktopIds) {
    const seen = {};
    const out = [];
    const add = (app, label, source) => {
        const key = String(app || "").trim().toLowerCase();
        if (!key || seen[key]) return;
        seen[key] = true;
        out.push({ app: key, label: label || app, source: source });
    };
    for (const w of windows || []) add(w.app, w.label, "open");
    for (const id of desktopIds || []) add(id, id, "installed");
    return out;
}

// Options for an app dropdown: the suggestions, plus the row's current app if it's
// neither open nor installed (e.g. picked from a window of an app without a desktop file).
// "text" is what the dropdown shows: open windows add their title.
function appOptions(suggestions, current) {
    const app = String(current || "").trim().toLowerCase();
    const list = (!app || suggestions.some(s => s.app === app))
        ? suggestions
        : [{ app: app, label: app, source: "custom" }].concat(suggestions);
    return list.map(s => Object.assign({ text: s.source === "open" ? s.app + "  ·  " + s.label : s.app }, s));
}

function filterSuggestions(suggestions, query, limit) {
    const q = String(query || "").trim().toLowerCase();
    const matches = q
        ? suggestions.filter(s => s.app.indexOf(q) !== -1 || String(s.label).toLowerCase().indexOf(q) !== -1)
        : suggestions;
    return matches.slice(0, limit || 50);
}
