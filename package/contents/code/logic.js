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

// Old text format from the System Settings page: one "app = section" per line, # comments.
function parseLegacyApps(text) {
    const list = [];
    for (const raw of String(text || "").split("\n")) {
        const line = raw.trim();
        if (!line || line.startsWith("#")) continue;
        const parts = line.split("=");
        list.push({ app: parts[0], section: parts.length > 1 ? parts[1] : "keep" });
    }
    return normalizeApps(list);
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

// Monitor changes right after opening are our own placement, and ones right after
// monitors were plugged/unplugged are KWin evacuating windows; neither is the user's choice.
function shouldRemember(msSinceOpen, msSinceScreensChanged, graceMs, settleMs) {
    return msSinceOpen >= graceMs && msSinceScreensChanged >= settleMs;
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

function filterSuggestions(suggestions, query, limit) {
    const q = String(query || "").trim().toLowerCase();
    const matches = q
        ? suggestions.filter(s => s.app.indexOf(q) !== -1 || String(s.label).toLowerCase().indexOf(q) !== -1)
        : suggestions;
    return matches.slice(0, limit || 50);
}
