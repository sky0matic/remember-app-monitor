import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQml
import QtCore
import Qt.labs.folderlistmodel
import org.kde.kwin
import org.kde.kirigami as Kirigami
import "../code/logic.js" as Logic

// Settings window, shown inside KWin (Meta+Ctrl+M by default). Edits a draft of the
// app list; "Save" hands it to the controller (main.qml). "Forget" acts immediately.
// KWin doesn't deliver keyboard input to its own windows, so everything here is
// mouse-driven; app ids that can't be picked go in the System Settings page.
ApplicationWindow {
    id: win

    required property var controller

    // bumped to re-evaluate remembered-monitor labels after "Forget"
    property int monitorsRevision: 0
    property var suggestions: []
    property var desktopIds: ({})
    // draft row waiting for a window to be clicked, or -1
    property int pickingRow: -1
    readonly property real appColumnWidth: Kirigami.Units.gridUnit * 16
    readonly property real sectionColumnWidth: Kirigami.Units.gridUnit * 11
    readonly property var manualOnly: monitorsRevision >= 0 ? Logic.manualOnly(controller.apps, controller.manualApps()) : []

    title: "Remember App Monitor"
    width: 980
    height: 560
    // KWin's own windows get no decoration; the header below acts as the title bar
    flags: Qt.FramelessWindowHint | Qt.Window | Qt.BypassWindowManagerHint
    // Inside KWin, Kirigami.Theme doesn't pick up the color scheme (it falls back to black),
    // but the Qt palette does; hand the palette colors to Kirigami components too.
    Kirigami.Theme.inherit: false
    Kirigami.Theme.backgroundColor: palette.window
    Kirigami.Theme.textColor: palette.windowText
    Kirigami.Theme.disabledTextColor: palette.placeholderText
    Kirigami.Theme.highlightColor: palette.highlight
    Kirigami.Theme.highlightedTextColor: palette.highlightedText
    color: palette.window

    function open() {
        draft.clear();
        for (const entry of controller.apps) draft.append({ app: entry.app, section: entry.section });
        pickingRow = -1;
        refreshSuggestions();
        monitorsRevision++;
        // center on the monitor that has focus
        const area = Workspace.clientArea(KWin.MaximizeArea, Workspace.activeScreen, Workspace.currentDesktop);
        x = Math.round(area.x + (area.width - width) / 2);
        y = Math.round(area.y + (area.height - height) / 2);
        show();
        raise();
    }

    onVisibleChanged: if (!visible && pickingRow >= 0) finishPick(null)

    function save() {
        const list = [];
        for (let i = 0; i < draft.count; i++) list.push({ app: draft.get(i).app, section: draft.get(i).section });
        controller.setApps(list);
        close();
    }

    function refreshSuggestions() {
        const windows = [];
        for (const w of Workspace.windows) {
            if (!w.normalWindow || w.skipTaskbar) continue;
            windows.push({ app: Logic.appIdOf(w.desktopFileName, w.resourceClass, w.resourceName), label: w.caption });
        }
        const ids = [];
        for (const dir in desktopIds) ids.push(...desktopIds[dir]);
        ids.sort();
        suggestions = Logic.buildSuggestions(windows, ids);
    }

    function pickWindow(row) {
        pickingRow = row;
        const g = Workspace.virtualScreenGeometry;
        pickOverlay.x = g.x;
        pickOverlay.y = g.y;
        pickOverlay.width = g.width;
        pickOverlay.height = g.height;
        pickOverlay.show();
        pickOverlay.raise();
    }

    // pos: global position of the click, or null when cancelled
    function finishPick(pos) {
        pickOverlay.hide();
        if (pos && pickingRow >= 0 && pickingRow < draft.count) {
            // topmost app window under the click; KWin's own windows (like this one) have no class
            const target = Workspace.windowAt(pos, 10).find(w => w.normalWindow
                && Logic.appIdOf(w.desktopFileName, w.resourceClass, w.resourceName));
            if (target) {
                refreshSuggestions();
                draft.setProperty(pickingRow, "app", Logic.appIdOf(target.desktopFileName, target.resourceClass, target.resourceName));
                monitorsRevision++;
            }
        }
        pickingRow = -1;
    }

    function describeMonitor(id) {
        const remembered = [];
        for (let i = 0; i < draft.count; i++) {
            const m = controller.rememberedMonitor(draft.get(i).app);
            if (m) remembered.push(m);
        }
        const ambiguous = Logic.ambiguousModels(remembered, Workspace.screens);
        const d = Logic.describeMonitor(id, Workspace.screens, Workspace.screenOrder, controller.seen, ambiguous);
        let text = d.name + " · ";
        if (d.connected) text += d.position;
        else if (d.lastSeen) text += "last seen " + Qt.formatDate(new Date(d.lastSeen), Locale.ShortFormat);
        else text += "not connected";
        return { text: text, details: d.details };
    }

    ListModel { id: draft }

    // Picking an app by clicking its window: a transparent window over all screens catches
    // the click, then KWin says which window is under it. (KWin's own queryWindowInfo can't
    // be used: its D-Bus reply is delayed, which doesn't work for calls from within KWin.)
    Window {
        id: pickOverlay
        flags: Qt.FramelessWindowHint | Qt.BypassWindowManagerHint | Qt.WindowStaysOnTopHint
        // a fully transparent window would let clicks through
        color: Qt.rgba(0, 0, 0, 0.01)
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.CrossCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => win.finishPick(mouse.button === Qt.LeftButton
                ? Qt.point(pickOverlay.x + mouse.x, pickOverlay.y + mouse.y) : null)
        }
    }

    // Installed apps: desktop entry ids from the usual application directories
    Instantiator {
        model: [
            "file:///usr/share/applications",
            "file:///usr/local/share/applications",
            "file:///var/lib/flatpak/exports/share/applications",
            StandardPaths.writableLocation(StandardPaths.GenericDataLocation) + "/applications",
            StandardPaths.writableLocation(StandardPaths.GenericDataLocation) + "/flatpak/exports/share/applications"
        ]
        delegate: FolderListModel {
            required property string modelData
            folder: modelData
            nameFilters: ["*.desktop"]
            showDirs: false
            onStatusChanged: {
                if (status !== FolderListModel.Ready) return;
                const ids = [];
                for (let i = 0; i < count; i++) ids.push(String(get(i, "fileName")).replace(/\.desktop$/, ""));
                const all = Object.assign({}, win.desktopIds);
                all[modelData] = ids;
                win.desktopIds = all;
                win.refreshSuggestions();
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.color: Kirigami.ColorUtils.linearInterpolation(win.palette.window, win.palette.windowText, 0.25)
        z: 10
    }

    header: ToolBar {
        Kirigami.Theme.inherit: false
        Kirigami.Theme.backgroundColor: win.palette.window
        Kirigami.Theme.textColor: win.palette.windowText
        MouseArea {
            anchors.fill: parent
            property point pressPos
            onPressed: mouse => pressPos = Qt.point(mouse.x, mouse.y)
            onPositionChanged: mouse => {
                win.x += mouse.x - pressPos.x;
                win.y += mouse.y - pressPos.y;
            }
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Kirigami.Units.largeSpacing
            Kirigami.Icon {
                source: "preferences-desktop-display"
                implicitWidth: Kirigami.Units.iconSizes.smallMedium
                implicitHeight: implicitWidth
            }
            Kirigami.Heading {
                text: win.title
                level: 3
                Layout.fillWidth: true
            }
            ToolButton {
                icon.name: "window-close"
                onClicked: win.close()
                ToolTip.text: "Close without saving"
                ToolTip.visible: hovered
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.largeSpacing

        Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: "Apps listed here open on the monitor they were last moved to, in the section you choose. "
                + "If that monitor isn't connected, they open on the main monitor as usual. "
                + "Moving an app to another monitor makes it remember that one."
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: win.pickingRow >= 0
            type: Kirigami.MessageType.Information
            text: "Click the window of the app to add. Right-click, or click this window, to cancel."
        }

        RowLayout {
            Layout.fillWidth: true
            visible: draft.count > 0
            Label { text: "App"; font.bold: true; Layout.preferredWidth: win.appColumnWidth + pickButtonWidth.width + Kirigami.Units.smallSpacing }
            Label { text: "Section"; font.bold: true; Layout.preferredWidth: win.sectionColumnWidth }
            Label { text: "Remembered monitor"; font.bold: true; Layout.fillWidth: true }
            ToolButton { id: pickButtonWidth; visible: false; icon.name: "crosshairs" }
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth

            ColumnLayout {
                width: parent.width
                spacing: Kirigami.Units.smallSpacing

                Kirigami.PlaceholderMessage {
                    Layout.fillWidth: true
                    Layout.topMargin: Kirigami.Units.gridUnit * 3
                    visible: draft.count === 0
                    icon.name: "preferences-desktop-display"
                    text: "No apps yet"
                    explanation: "Click \"Add app\" to choose where an app opens."
                }

                Repeater {
                    model: draft
                    delegate: RowLayout {
                        id: row
                        required property int index
                        required property string app
                        required property string section
                        readonly property string monitor: win.monitorsRevision >= 0 && app ? win.controller.rememberedMonitor(app) : ""
                        readonly property var monitorInfo: monitor ? win.describeMonitor(monitor) : null

                        Layout.fillWidth: true

                        ThemedComboBox {
                            id: appBox
                            Layout.preferredWidth: win.appColumnWidth
                            model: Logic.appOptions(win.suggestions, row.app)
                            textRole: "text"
                            valueRole: "app"
                            displayText: row.app || "Choose an app…"
                            currentIndex: model.findIndex(o => o.app === row.app)
                            onActivated: index => draft.setProperty(row.index, "app", model[index].app)
                        }

                        ToolButton {
                            icon.name: "crosshairs"
                            checkable: false
                            highlighted: win.pickingRow === row.index
                            enabled: win.pickingRow < 0
                            onClicked: win.pickWindow(row.index)
                            ToolTip.text: "Pick the app by clicking its window"
                            ToolTip.visible: hovered
                        }

                        ThemedComboBox {
                            Layout.preferredWidth: win.sectionColumnWidth
                            model: Logic.SECTIONS
                            textRole: "label"
                            valueRole: "id"
                            currentIndex: Logic.sectionIndex(row.section)
                            onActivated: draft.setProperty(row.index, "section", currentValue)
                        }

                        Label {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: row.monitorInfo ? row.monitorInfo.text : "None yet: remembered when the app is moved or closed"
                            opacity: row.monitor ? 1 : 0.6
                            ToolTip.text: row.monitorInfo ? row.monitorInfo.details : text
                            ToolTip.visible: hoverHandler.hovered
                            HoverHandler { id: hoverHandler }
                        }

                        ToolButton {
                            icon.name: "edit-clear-history"
                            enabled: !!row.monitor
                            onClicked: {
                                win.controller.setRememberedMonitor(row.app, "");
                                win.monitorsRevision++;
                            }
                            ToolTip.text: "Forget the remembered monitor"
                            ToolTip.visible: hovered
                        }

                        ToolButton {
                            icon.name: "list-remove"
                            onClicked: draft.remove(row.index)
                            ToolTip.text: "Remove this app"
                            ToolTip.visible: hovered
                        }
                    }
                }

                Label {
                    Layout.fillWidth: true
                    Layout.topMargin: Kirigami.Units.largeSpacing
                    visible: win.manualOnly.length > 0
                    wrapMode: Text.WordWrap
                    opacity: 0.7
                    text: "Also set in System Settings → KWin Scripts → Remember App Monitor: "
                        + win.manualOnly.map(m => m.app + " (" + Logic.sectionById(m.section).label.toLowerCase() + ")").join(", ")
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Button {
                text: "Add app"
                icon.name: "list-add"
                onClicked: draft.append({ app: "", section: Logic.DEFAULT_SECTION })
            }
            Label {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.largeSpacing
                wrapMode: Text.WordWrap
                opacity: 0.6
                font: Kirigami.Theme.smallFont
                text: "App not listed? Open it and use the crosshair, or type it in System Settings → KWin Scripts → Remember App Monitor."
            }
            Button {
                text: "Cancel"
                icon.name: "dialog-cancel"
                onClicked: win.close()
            }
            Button {
                text: "Save"
                icon.name: "document-save"
                highlighted: true
                onClicked: win.save()
            }
        }
    }

    // Combo boxes and their popups use the "View"/"Button" colors, which also fall back
    // to black inside KWin; give them the palette's colors.
    component ThemedComboBox: ComboBox {
        Kirigami.Theme.inherit: false
        Kirigami.Theme.backgroundColor: win.palette.button
        Kirigami.Theme.textColor: win.palette.buttonText
        Kirigami.Theme.highlightColor: win.palette.highlight
        Kirigami.Theme.highlightedTextColor: win.palette.highlightedText
        popup.background: Rectangle {
            color: win.palette.base
            border.color: Kirigami.ColorUtils.linearInterpolation(win.palette.base, win.palette.text, 0.25)
        }
    }
}
