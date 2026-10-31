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
ApplicationWindow {
    id: win

    required property var controller

    // bumped to re-evaluate remembered-monitor labels after "Forget"
    property int monitorsRevision: 0
    property var suggestions: []
    property var desktopIds: ({})
    readonly property real appColumnWidth: Kirigami.Units.gridUnit * 16
    readonly property real sectionColumnWidth: Kirigami.Units.gridUnit * 12

    title: "Remember App Monitor"
    width: 920
    height: 560
    // KWin's own windows get no decoration; the header below acts as the title bar
    flags: Qt.FramelessWindowHint | Qt.Window | Qt.BypassWindowManagerHint
    Kirigami.Theme.colorSet: Kirigami.Theme.Window
    color: Kirigami.Theme.backgroundColor

    function open() {
        draft.clear();
        for (const entry of controller.apps) draft.append({ app: entry.app, section: entry.section });
        refreshSuggestions();
        monitorsRevision++;
        // center on the monitor that has focus
        const area = Workspace.clientArea(KWin.MaximizeArea, Workspace.activeScreen, Workspace.currentDesktop);
        x = Math.round(area.x + (area.width - width) / 2);
        y = Math.round(area.y + (area.height - height) / 2);
        show();
        raise();
        requestActivate();
    }

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
            windows.push({ app: w.desktopFileName || w.resourceClass, label: w.caption });
        }
        const ids = [];
        for (const dir in desktopIds) ids.push(...desktopIds[dir]);
        ids.sort();
        suggestions = Logic.buildSuggestions(windows, ids);
    }

    ListModel { id: draft }

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

    Shortcut {
        sequence: "Escape"
        onActivated: win.close()
    }

    Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.color: Kirigami.ColorUtils.linearInterpolation(Kirigami.Theme.backgroundColor, Kirigami.Theme.textColor, 0.25)
        z: 10
    }

    header: ToolBar {
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

        RowLayout {
            Layout.fillWidth: true
            visible: draft.count > 0
            Label { text: "App"; font.bold: true; Layout.preferredWidth: win.appColumnWidth }
            Label { text: "Section"; font.bold: true; Layout.preferredWidth: win.sectionColumnWidth }
            Label { text: "Remembered monitor"; font.bold: true; Layout.fillWidth: true }
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

                        Layout.fillWidth: true

                        AppField {
                            Layout.preferredWidth: win.appColumnWidth
                            text: row.app
                            suggestions: win.suggestions
                            onAppChosen: value => draft.setProperty(row.index, "app", value.trim().toLowerCase())
                        }

                        ComboBox {
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
                            readonly property bool connected: !!Logic.findOutput(Workspace.screens, row.monitor)
                            text: row.monitor
                                ? Logic.monitorLabel(row.monitor) + (connected ? "" : " (not connected)")
                                : "None yet (opens on main monitor)"
                            opacity: row.monitor ? 1 : 0.6
                            ToolTip.text: row.monitor ? Logic.monitorDetails(row.monitor) : text
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
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Button {
                text: "Add app"
                icon.name: "list-add"
                onClicked: draft.append({ app: "", section: Logic.DEFAULT_SECTION })
            }
            Item { Layout.fillWidth: true }
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

    // Text field for an app id with a searchable list of open windows and installed
    // apps; any typed value is accepted as-is.
    component AppField: TextField {
        id: field

        property var suggestions: []
        signal appChosen(string value)

        placeholderText: "Search apps or type a window class"
        onTextEdited: {
            matches.model = Logic.filterSuggestions(suggestions, text, 50);
            popup.open();
        }
        onActiveFocusChanged: {
            if (activeFocus) {
                matches.model = Logic.filterSuggestions(suggestions, text, 50);
                popup.open();
            }
        }
        onEditingFinished: appChosen(text)
        Keys.onDownPressed: {
            popup.open();
            matches.forceActiveFocus();
        }

        Popup {
            id: popup
            y: field.height
            width: Math.max(field.width, Kirigami.Units.gridUnit * 22)
            height: Math.min(matches.contentHeight + topPadding + bottomPadding, Kirigami.Units.gridUnit * 14)
            padding: 1
            visible: false
            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

            ListView {
                id: matches
                anchors.fill: parent
                clip: true
                keyNavigationEnabled: true
                Keys.onReturnPressed: if (currentItem) currentItem.choose(currentItem.modelData.app)
                delegate: ItemDelegate {
                    required property var modelData
                    width: ListView.view.width
                    highlighted: ListView.isCurrentItem
                    contentItem: RowLayout {
                        Kirigami.Icon {
                            source: modelData.app
                            fallback: "application-x-executable"
                            implicitWidth: Kirigami.Units.iconSizes.small
                            implicitHeight: implicitWidth
                        }
                        Label {
                            text: modelData.label
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                        Label {
                            text: modelData.source === "open" ? modelData.app + " · open" : ""
                            opacity: 0.6
                            visible: text !== ""
                        }
                    }
                    onClicked: choose(modelData.app)
                    function choose(app) {
                        field.text = app;
                        field.appChosen(app);
                        popup.close();
                    }
                }
            }
        }
    }
}
