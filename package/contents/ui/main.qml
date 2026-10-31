import QtQuick
import QtCore
import org.kde.kwin
import "../code/logic.js" as Logic

// Opens configured apps on the monitor they were last moved to (identified by
// manufacturer, model and serial number), in a chosen section of it. If that
// monitor isn't connected, the app is sent to the main monitor and left wherever
// and however it places itself. Placement rules live in ../code/logic.js.
Item {
    id: root

    // undo apps maximizing themselves this long after opening
    readonly property int graceMs: 4000
    // monitor changes this soon after opening may be the app placing itself, unless dragged
    readonly property int rememberGraceMs: 1500
    readonly property int screensSettleMs: 3000
    property double screensChangedAt: 0

    // [{app, section}]; edited through the settings window
    property var apps: []
    // monitor id -> last time it was connected (ms), for the settings window
    property var seen: ({})
    property var connectedIds: []

    // Saved to ~/.config/kde.org/kwin.conf [RememberAppMonitor]: "_apps" holds the app list
    // and "_seen" the last-seen times, as JSON; every other key is an app id -> remembered monitor id.
    Settings {
        id: store
        category: "RememberAppMonitor"
    }

    function rememberedMonitor(app) {
        return store.value(app, "");
    }

    function setRememberedMonitor(app, id) {
        store.setValue(app, id);
        store.sync();
    }

    function setApps(list) {
        apps = Logic.normalizeApps(list);
        store.setValue("_apps", JSON.stringify(apps));
        store.sync();
        trackOpenWindows();
    }

    // Entries typed in System Settings → KWin Scripts → Remember App Monitor, for app ids
    // that can't be picked in the settings window (it can't receive typing)
    function manualApps() {
        return Logic.parseManualApps(KWin.readConfig("apps", ""));
    }

    function loadApps() {
        // QSettings caches the file per process; pick up edits made while KWin was running
        store.sync();
        apps = Logic.parseApps(store.value("_apps", ""));
        try {
            seen = JSON.parse(store.value("_seen", "{}"));
        } catch (e) {
            seen = {};
        }
        updateSeen();
        trackOpenWindows();
    }

    // Adds the serial number to remembered monitors saved without one, once connected
    function upgradeMonitorIds() {
        for (const entry of Logic.mergeApps(apps, manualApps())) {
            const saved = rememberedMonitor(entry.app);
            const upgraded = Logic.upgradeMonitorId(saved, Workspace.screens);
            if (upgraded !== saved) setRememberedMonitor(entry.app, upgraded);
        }
    }

    function updateSeen() {
        upgradeMonitorIds();
        const current = Workspace.screens.map(o => Logic.monitorId(o));
        seen = Logic.updateSeen(seen, connectedIds, current, Date.now());
        connectedIds = current;
        store.setValue("_seen", JSON.stringify(seen));
        store.sync();
    }

    function applySection(w, output, section) {
        if (w.output !== output) Workspace.sendClientToScreen(w, output);
        if (section === "keep") return;
        if (section === "maximized") {
            w.setMaximize(true, true);
            return;
        }
        w.setMaximize(false, false);
        const area = Workspace.clientArea(KWin.MaximizeArea, output, Workspace.currentDesktop);
        const g = Logic.sectionGeometry(section, area, w.frameGeometry);
        if (g) w.frameGeometry = Qt.rect(g.x, g.y, g.width, g.height);
    }

    // The list entry for a window's app, or null if the app isn't in the list
    function appEntry(w) {
        if (!w.normalWindow || w.skipTaskbar || w.transient) return null;
        return Logic.findApp(Logic.mergeApps(apps, manualApps()), [w.resourceClass, w.resourceName, w.desktopFileName]);
    }

    function handle(w) {
        const entry = appEntry(w);
        if (!entry) return;
        const openedAt = Date.now();

        const saved = rememberedMonitor(entry.app);
        const plan = Logic.planPlacement(saved, Workspace.screens, Workspace.screenOrder);
        if (plan.kind === "section") {
            // upgrade ids saved without a serial number
            const id = Logic.monitorId(plan.output);
            if (id !== saved) setRememberedMonitor(entry.app, id);
            applySection(w, plan.output, entry.section);
            w.maximizedChanged.connect(() => {
                if (Logic.shouldUndoMaximize(entry.section, Date.now() - openedAt, w.maximizeMode, graceMs))
                    applySection(w, plan.output, entry.section);
            });
        } else if (plan.output && w.output !== plan.output) {
            Workspace.sendClientToScreen(w, plan.output);
        }

        track(w, entry.app, openedAt);
    }

    // windows followed for monitor changes, by internalId
    property var tracked: ({})

    // Remembers the monitor when the user moves the window to another one
    function track(w, app, openedAt) {
        const key = String(w.internalId);
        if (tracked[key]) return;
        tracked[key] = true;
        const remember = (byUser) => {
            const now = Date.now();
            if (!w.output || !Logic.shouldRemember(byUser, now - openedAt, now - screensChangedAt, rememberGraceMs, screensSettleMs)) return;
            // the app may have been removed from the list since it opened
            if (!Logic.findApp(Logic.mergeApps(apps, manualApps()), [app])) return;
            const id = Logic.monitorId(w.output);
            if (id !== rememberedMonitor(app)) setRememberedMonitor(app, id);
        };
        w.outputChanged.connect(() => remember(w.move));
        // a drag that started before the grace ended still counts once it's dropped
        w.interactiveMoveResizeFinished.connect(() => remember(true));
    }

    // Follows windows of listed apps that were already open (when the script starts or
    // an app is added to the list)
    function trackOpenWindows() {
        for (const w of Workspace.windows) {
            const entry = appEntry(w);
            if (entry) track(w, entry.app, 0);
        }
    }

    function windowClosed(w) {
        delete tracked[String(w.internalId)];
        const entry = appEntry(w);
        if (!entry || !w.output) return;
        if (Logic.shouldRememberOnClose(rememberedMonitor(entry.app), Date.now() - screensChangedAt, screensSettleMs))
            setRememberedMonitor(entry.app, Logic.monitorId(w.output));
    }

    property var settingsWindow: null
    property double lastShortcutAt: 0

    function toggleSettings() {
        // Holding the shortcut repeats it (kglobalaccel triggers auto-repeating actions on
        // key repeat), which would close the window right after opening it. Repeats come
        // every few tens of ms, so ignore activations that closely follow the previous one.
        // The first open blocks for a while (creating the window), so the gap is measured
        // from when the previous activation was done with, not when it started.
        const repeated = Date.now() - lastShortcutAt < 400;
        lastShortcutAt = Date.now();
        if (repeated) return;
        toggleSettingsNow();
        lastShortcutAt = Date.now();
    }

    function toggleSettingsNow() {
        if (settingsWindow && settingsWindow.visible) {
            settingsWindow.close();
            return;
        }
        if (!settingsWindow) settingsWindow = settingsComponent.createObject(root, { controller: root });
        updateSeen();
        settingsWindow.open();
    }

    Component {
        id: settingsComponent
        SettingsWindow {}
    }

    ShortcutHandler {
        name: "Remember App Monitor: Settings"
        text: "Remember App Monitor: Open Settings"
        sequence: "Meta+Ctrl+M"
        onActivated: root.toggleSettings()
    }

    Connections {
        target: Workspace
        function onWindowAdded(w) { root.handle(w); }
        function onWindowRemoved(w) { root.windowClosed(w); }
        function onScreensChanged() {
            root.screensChangedAt = Date.now();
            root.updateSeen();
        }
    }

    Component.onCompleted: loadApps()
    Component.onDestruction: updateSeen()
}
