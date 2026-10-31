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

    readonly property int graceMs: 4000
    readonly property int screensSettleMs: 3000
    property double screensChangedAt: 0

    // [{app, section}]; edited through the settings window
    property var apps: []

    // Saved to ~/.config/kde.org/kwin.conf [RememberAppMonitor]:
    // "_apps" holds the app list as JSON, every other key is an app id -> remembered monitor id.
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
    }

    function loadApps() {
        // QSettings caches the file per process; pick up edits made while KWin was running
        store.sync();
        const json = store.value("_apps", "");
        if (json) {
            apps = Logic.parseApps(json);
        } else {
            // first run: import the old text setting from System Settings (kwinrc)
            setApps(Logic.parseLegacyApps(KWin.readConfig("apps", "")));
        }
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

    function handle(w) {
        if (!w.normalWindow || w.skipTaskbar || w.transient) return;
        const entry = Logic.findApp(apps, [w.resourceClass, w.resourceName, w.desktopFileName]);
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

        w.outputChanged.connect(() => {
            const now = Date.now();
            if (!Logic.shouldRemember(now - openedAt, now - screensChangedAt, graceMs, screensSettleMs)) return;
            // the app may have been removed from the list since it opened
            if (!Logic.findApp(apps, [entry.app])) return;
            const id = Logic.monitorId(w.output);
            if (id !== rememberedMonitor(entry.app)) setRememberedMonitor(entry.app, id);
        });
    }

    property var settingsWindow: null

    function toggleSettings() {
        if (settingsWindow && settingsWindow.visible) {
            settingsWindow.close();
            return;
        }
        if (!settingsWindow) settingsWindow = settingsComponent.createObject(root, { controller: root });
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
        function onScreensChanged() { root.screensChangedAt = Date.now(); }
    }

    Component.onCompleted: loadApps()
}
