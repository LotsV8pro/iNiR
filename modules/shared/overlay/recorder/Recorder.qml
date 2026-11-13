pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.shared.overlay
import qs.services

// Capture: the two recordings lead (a region, the whole screen), or the running one with its time and Stop; then the
// stills, what audio goes in, and where it all lands.
StyledOverlayWidget {
    id: root
    resizable: false

    readonly property bool recording: RecorderStatus.isRecording
    factColor: OverlayLook.colError

    readonly property string savePath: {
        const configured = String(Config.getNestedValue("screenRecord.savePath", ""))
        if (configured.length > 0) return configured
        const videos = FileUtils.trimFileProtocol(Directories.videos)
        return videos || `${FileUtils.trimFileProtocol(Directories.home)}/Videos`
    }
    readonly property string screenshotPath: Directories.screenshotsPath
    readonly property string audioMode: RecorderStatus.configuredAudioMode
    readonly property string liveAudioMode: root.recording ? RecorderStatus.effectiveAudioMode : root.audioMode
    readonly property var audioModes: OverlayContext.audioModes
    function audioLabel(mode: string): string { return OverlayContext.audioLabel(mode) }

    // Which device the recording takes its sound from. An empty name means "whatever the system default is when it
    // starts", so changing the default in the mixer is enough; a name pins that one device until Default is picked.
    property var _micSources: []
    property var _systemSources: []
    property string _defaultSourceName: ""
    property string _defaultSinkName: ""
    // Which inline device list is open: "mic", "system" or "".
    property string _openDevicePicker: ""

    readonly property var _micOptions: {
        const list = [{ name: "", label: Translation.tr("Default") + " · " + root.defaultDeviceLabel(true) }]
        return list.concat(root._micSources ?? [])
    }
    readonly property var _systemOptions: {
        const list = [{ name: "", label: Translation.tr("Default") + " · " + root.defaultDeviceLabel(false) }]
        return list.concat(root._systemSources ?? [])
    }

    function refreshAudioDevices(): void {
        if (!audioSourcesProcess.running) audioSourcesProcess.running = true
        if (!defaultDevicesProcess.running) defaultDevicesProcess.running = true
    }

    function deviceLabel(name: string): string {
        const all = (root._micSources ?? []).concat(root._systemSources ?? [])
        const hit = all.find(entry => entry.name === name)
        if (hit) return hit.label
        return name.length > 0 ? name : Translation.tr("System default")
    }

    function defaultDeviceLabel(isMic: bool): string {
        const name = isMic ? root._defaultSourceName : root._defaultSinkName
        return name.length > 0 ? root.deviceLabel(name) : Translation.tr("System default")
    }

    function toggleDevicePicker(kind: string): void {
        const willOpen = root._openDevicePicker !== kind
        root._openDevicePicker = willOpen ? kind : ""
        if (willOpen) root.placeDeviceMenu(kind)
    }

    // The list floats over the panel: it must not take part in the layout, or opening it shoves every control below
    // it downwards. Position it under its picker whenever it opens.
    function placeDeviceMenu(kind: string): void {
        const picker = kind === "mic" ? micPicker : systemPicker
        const menu = kind === "mic" ? micMenu : systemMenu
        if (!picker || !menu) return
        const point = picker.mapToItem(root.contentItem, 0, 0)
        menu.x = Math.max(8, point.x)
        menu.y = point.y + picker.height + 4
        menu.width = Math.max(picker.width, Math.round(220 * root.d))
    }

    // The system default changing under an open list (or the devices themselves) does not close it, it refreshes.
    Connections {
        target: RecorderStatus
        function onConfiguredAudioModeChanged() { root._openDevicePicker = "" }
    }

    // Free space where recordings land, read while the bench is open.
    property string diskFree: ""
    Process {
        id: diskQuery
        command: ["df", "-BG", "--output=avail", root.savePath]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.trim().split("\n")
                root.diskFree = lines.length > 1 ? lines[lines.length - 1].trim() : ""
            }
        }
    }
    Timer {
        interval: 10000
        running: root.benchOpen && root.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!diskQuery.running) diskQuery.running = true
    }

    // The devices the mixer offers, split the way the recorder uses them: microphones (and the processed voice chain,
    // which is a source too) for the mic side, each sink's monitor for the system side.
    Process {
        id: audioSourcesProcess
        command: ["/usr/bin/pactl", "-f", "json", "list", "sources"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const list = JSON.parse(text)
                    const mics = []
                    const systems = []
                    for (const source of list) {
                        const name = String(source.name ?? "")
                        if (name.length === 0) continue
                        const description = String(source.description ?? name)
                        if (name.endsWith(".monitor"))
                            systems.push({ name: name, label: description.replace(/^Monitor of /, "") })
                        else if (name !== "obs_virtual_source")
                            mics.push({ name: name, label: description })
                    }
                    root._micSources = mics
                    root._systemSources = systems
                } catch (e) { /* pactl without JSON support: Default rows still work */ }
            }
        }
    }
    Process {
        id: defaultDevicesProcess
        command: ["/usr/bin/bash", "-c", "pactl get-default-source; pactl get-default-sink"]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.trim().split("\n")
                root._defaultSourceName = String(lines[0] ?? "").trim()
                root._defaultSinkName = String(lines[1] ?? "").trim()
            }
        }
    }
    Component.onCompleted: root.refreshAudioDevices()
    onVisibleChanged: {
        if (visible) root.refreshAudioDevices()
        else root._openDevicePicker = ""
    }
    Timer {
        interval: 8000
        repeat: true
        running: root.visible
        onTriggered: root.refreshAudioDevices()
    }

    property string folderTarget: "recordings"
    property bool _dialogShown: false
    function chooseFolder(target: string): void {
        root.folderTarget = target
        folderDialog.open()
    }
    function syncDialog(): void {
        const shown = Boolean(folderDialog.visible)
        if (shown === root._dialogShown) return
        root._dialogShown = shown
        OverlayContext.setNativeDialogVisible("recorder-folder", shown)
    }
    function openFolder(path: string, label: string): void {
        GlobalStates.overlayOpen = false
        ShellExec.openDirectory(path, label)
    }

    FilePickerDialog {

        selectFolder: true
        id: folderDialog
        title: root.folderTarget === "screenshots" ? Translation.tr("Select screenshots folder") : Translation.tr("Select recordings folder")
        currentFolder: `file://${root.folderTarget === "screenshots" ? root.screenshotPath : root.savePath}`
        onAccepted: {
            const path = FileUtils.trimFileProtocol(selectedFolder.toString())
            Config.setNestedValue(root.folderTarget === "screenshots" ? "regionSelector.savePath" : "screenRecord.savePath", path)
        }
        onVisibleChanged: root.syncDialog()
    }
    Component.onDestruction: if (root._dialogShown) OverlayContext.setNativeDialogVisible("recorder-folder", false)

    contentItem: Item {
        anchors.fill: parent
        implicitWidth: Math.round(340 * root.d)
        implicitHeight: column.implicitHeight

        ColumnLayout {
            id: column
            anchors.fill: parent
            spacing: Math.round(8 * root.d)

            // The lead: two recordings, or the one running.
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.round(92 * root.d)

                RowLayout {
                    anchors.fill: parent
                    spacing: Math.round(8 * root.d)
                    opacity: root.recording ? 0 : 1
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: FamilyStyle.revealDuration } }
                    OverlayCaptureTile {
                        glyph: "screen_record"
                        label: Translation.tr("Record region")
                        detail: root.audioLabel(root.audioMode)
                        onClicked: OverlayContext.recordRegion()
                    }
                    OverlayCaptureTile {
                        glyph: "capture"
                        label: Translation.tr("Record screen")
                        detail: root.audioLabel(root.audioMode)
                        onClicked: OverlayContext.recordScreen()
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    opacity: root.recording ? 1 : 0
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: FamilyStyle.revealDuration } }
                    radius: OverlayLook.roundingNormal
                    color: OverlayLook.colErrorContainer

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Math.round(16 * root.d)
                        anchors.rightMargin: Math.round(12 * root.d)
                        spacing: Math.round(12 * root.d)

                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            implicitWidth: Math.round(10 * root.d)
                            implicitHeight: implicitWidth
                            radius: width / 2
                            color: OverlayLook.colError
                            SequentialAnimation on opacity {
                                running: root.recording && root.visible
                                loops: Animation.Infinite
                                NumberAnimation { to: 0.25; duration: 700; easing.type: Easing.InOutSine }
                                NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 0
                            StyledText {
                                text: OverlayContext.elapsed(RecorderStatus.elapsedSeconds)
                                color: OverlayLook.colOnErrorContainer
                                font.family: OverlayLook.fontNumbers
                                font.features: ({ "tnum": 1 })
                                font.pixelSize: OverlayLook.typeFigure
                                font.weight: Font.DemiBold
                            }
                            StyledText {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                text: Translation.tr("Recording") + " · " + root.audioLabel(root.liveAudioMode)
                                    + (RecorderStatus.audioFallback ? " · " + Translation.tr("Fallback") : "")
                                color: OverlayLook.colOnErrorContainer
                                opacity: 0.75
                                font.family: OverlayLook.fontMain
                                font.pixelSize: OverlayLook.typeMeta
                            }
                        }
                        OverlayButton {
                            Layout.alignment: Qt.AlignVCenter
                            size: Math.round(36 * root.d)
                            strong: true
                            tint: OverlayLook.colError
                            glyph: "stop"
                            label: Translation.tr("Stop")
                            tip: Translation.tr("Stop recording")
                            onClicked: OverlayContext.stopRecording()
                        }
                    }
                }
            }

            // Stills
            RowLayout {
                Layout.fillWidth: true
                spacing: Math.round(8 * root.d)
                OverlayButton {
                    Layout.fillWidth: true
                    filled: true
                    size: Math.round(36 * root.d)
                    glyphSize: Math.round(18 * root.d)
                    glyph: "screenshot_region"
                    label: Translation.tr("Screenshot")
                    tip: Translation.tr("Screenshot region")
                    onClicked: OverlayContext.screenshotRegion()
                }
                OverlayButton {
                    Layout.fillWidth: true
                    filled: true
                    size: Math.round(36 * root.d)
                    glyphSize: Math.round(18 * root.d)
                    glyph: "content_copy"
                    label: Translation.tr("Copy screen")
                    tip: Translation.tr("Clipboard only")
                    onClicked: OverlayContext.copyScreen()
                }
            }

            // Audio, and what it will pick up
            OverlaySegments {
                Layout.fillWidth: true
                Layout.topMargin: Math.round(4 * root.d)
                enabled: !root.recording
                opacity: enabled ? 1 : 0.5
                accessibleName: Translation.tr("Audio")
                options: root.audioModes
                current: root.audioMode
                onPicked: value => RecorderStatus.setConfiguredAudioMode(value)
            }
            Row {
                Layout.alignment: Qt.AlignHCenter
                spacing: Math.round(14 * root.d)
                Fact {
                    visible: root.liveAudioMode === "system" || root.liveAudioMode === "both"
                    glyph: Audio.sink?.audio?.muted ? "volume_off" : "volume_up"
                    text: Math.round((Audio.sink?.audio?.volume ?? 1) * 100) + "%"
                    warn: Audio.sink?.audio?.muted ?? false
                }
                Fact {
                    visible: root.liveAudioMode === "microphone" || root.liveAudioMode === "both"
                    glyph: Audio.micMuted ? "mic_off" : "mic"
                    text: Audio.micMuted ? Translation.tr("OFF") : Translation.tr("ON")
                    warn: Audio.micMuted
                }
                Fact {
                    visible: root.diskFree.length > 0
                    glyph: "storage"
                    text: root.diskFree + " " + Translation.tr("free")
                }
            }

            // Which device each side records from. Hidden for the sides the chosen mode does not use.
            RowLayout {
                Layout.fillWidth: true
                spacing: Math.round(8 * root.d)
                visible: root.audioMode !== "none"
                DevicePicker {
                    id: micPicker
                    Layout.fillWidth: true
                    visible: root.audioMode === "microphone" || root.audioMode === "both"
                    glyph: "mic"
                    caption: Translation.tr("Microphone source")
                    options: root._micOptions
                    selectedName: RecorderStatus.configuredMicrophoneSource
                    expanded: root._openDevicePicker === "mic"
                    onToggleRequested: root.toggleDevicePicker("mic")
                }
                DevicePicker {
                    id: systemPicker
                    Layout.fillWidth: true
                    visible: root.audioMode === "system" || root.audioMode === "both"
                    glyph: "volume_up"
                    caption: Translation.tr("System audio source")
                    options: root._systemOptions
                    selectedName: RecorderStatus.configuredSystemAudioSource
                    expanded: root._openDevicePicker === "system"
                    onToggleRequested: root.toggleDevicePicker("system")
                }
            }

            Item { Layout.fillHeight: true }

            // Where it lands
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                color: OverlayLook.colHairline
            }
            FolderRow {
                glyph: "movie"
                title: Translation.tr("Recordings")
                path: root.savePath
                onOpenRequested: root.openFolder(root.savePath, Translation.tr("Open recordings folder"))
                onChangeRequested: root.chooseFolder("recordings")
            }
            FolderRow {
                glyph: "image"
                title: Translation.tr("Screenshots")
                path: root.screenshotPath
                onOpenRequested: root.openFolder(root.screenshotPath, Translation.tr("Open screenshots folder"))
                onChangeRequested: root.chooseFolder("screenshots")
            }
        }

        // The device lists float over the panel, under their picker: they are not part of the column, so opening one
        // does not move the controls below it.
        DeviceList {
            id: micMenu
            visible: root._openDevicePicker === "mic"
            options: root._micOptions
            selectedName: RecorderStatus.configuredMicrophoneSource
            onPicked: function(name) {
                RecorderStatus.setConfiguredMicrophoneSource(name)
                root._openDevicePicker = ""
            }
        }
        DeviceList {
            id: systemMenu
            visible: root._openDevicePicker === "system"
            options: root._systemOptions
            selectedName: RecorderStatus.configuredSystemAudioSource
            onPicked: function(name) {
                RecorderStatus.setConfiguredSystemAudioSource(name)
                root._openDevicePicker = ""
            }
        }
    }

    // The device shown as a row: its glyph, the chosen one, and whether the list is open.
    component DevicePicker: RippleButton {
        id: picker
        property string glyph
        property string caption
        property var options: []
        property string selectedName: ""
        property bool expanded: false
        signal toggleRequested()

        implicitHeight: Math.round(34 * root.d)
        buttonRadius: OverlayLook.roundingSmall
        colBackground: OverlayLook.colLayer2
        colBackgroundHover: OverlayLook.colLayer2Hover
        colRipple: OverlayLook.colLayer2Active

        function labelFor(name: string): string {
            for (const option of picker.options) {
                if (option.name === name) return option.label
            }
            return name.length > 0 ? name : Translation.tr("System default")
        }

        contentItem: RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Math.round(10 * root.d)
            anchors.rightMargin: Math.round(8 * root.d)
            spacing: Math.round(6 * root.d)
            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                text: picker.glyph
                iconSize: Math.round(16 * root.d)
                color: OverlayLook.colSubtext
            }
            StyledText {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                text: picker.labelFor(picker.selectedName)
                elide: Text.ElideRight
                font.family: OverlayLook.fontMain
                font.pixelSize: OverlayLook.typeMeta
                color: OverlayLook.colOnLayer1
            }
            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                text: picker.expanded ? "expand_less" : "expand_more"
                iconSize: Math.round(16 * root.d)
                color: OverlayLook.colSubtext
            }
        }

        Accessible.name: picker.caption + ": " + picker.labelFor(picker.selectedName)
        downAction: () => picker.toggleRequested()
    }

    // One device per row, the chosen one marked; the same plate the panel's own sheets use.
    component DeviceList: Rectangle {
        id: pickList
        property var options: []
        property string selectedName: ""
        signal picked(string name)

        implicitHeight: pickColumn.implicitHeight + Math.round(8 * root.d)
        radius: OverlayLook.roundingNormal
        color: OverlayLook.colLayer2
        border.width: 1
        border.color: OverlayLook.colHairline

        Column {
            id: pickColumn
            anchors.fill: parent
            anchors.margins: Math.round(4 * root.d)
            spacing: Math.round(2 * root.d)

            Repeater {
                model: pickList.options

                delegate: RippleButton {
                    required property var modelData
                    width: pickColumn.width
                    implicitHeight: Math.round(30 * root.d)
                    readonly property bool isSelected: String(modelData.name ?? "") === pickList.selectedName
                    colBackground: isSelected ? ColorUtils.applyAlpha(OverlayLook.colPrimary, 0.18) : "transparent"
                    colBackgroundHover: isSelected ? ColorUtils.applyAlpha(OverlayLook.colPrimary, 0.26) : OverlayLook.colLayer2Hover
                    colRipple: isSelected ? ColorUtils.applyAlpha(OverlayLook.colPrimary, 0.34) : OverlayLook.colLayer2Active
                    buttonRadius: OverlayLook.roundingSmall

                    contentItem: RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Math.round(8 * root.d)
                        anchors.rightMargin: Math.round(8 * root.d)
                        spacing: Math.round(6 * root.d)
                        MaterialSymbol {
                            Layout.alignment: Qt.AlignVCenter
                            text: "check"
                            iconSize: Math.round(15 * root.d)
                            color: OverlayLook.colPrimary
                            opacity: isSelected ? 1 : 0
                        }
                        StyledText {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            text: String(modelData.label ?? modelData.name ?? "")
                            elide: Text.ElideRight
                            font.family: OverlayLook.fontMain
                            font.pixelSize: OverlayLook.typeMeta
                            color: OverlayLook.colOnLayer1
                        }
                    }

                    onClicked: pickList.picked(String(modelData.name ?? ""))
                }
            }
        }
    }

    component Fact: Row {
        id: factRow
        property string glyph
        property string text
        property bool warn: false
        spacing: Math.round(4 * root.d)
        MaterialSymbol {
            anchors.verticalCenter: parent.verticalCenter
            text: factRow.glyph
            iconSize: Math.round(14 * root.d)
            color: factRow.warn ? OverlayLook.colError : OverlayLook.colSubtext
        }
        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: factRow.text
            color: factRow.warn ? OverlayLook.colError : OverlayLook.colSubtext
            font.family: OverlayLook.fontNumbers
            font.features: ({ "tnum": 1 })
            font.pixelSize: OverlayLook.typeMeta
        }
    }

    component FolderRow: RowLayout {
        id: folderRow
        property string glyph
        property string title
        property string path
        signal openRequested()
        signal changeRequested()
        Layout.fillWidth: true
        spacing: Math.round(8 * root.d)
        MaterialSymbol {
            Layout.leftMargin: Math.round(4 * root.d)
            text: folderRow.glyph
            iconSize: Math.round(16 * root.d)
            color: OverlayLook.colSubtext
        }
        StyledText {
            text: folderRow.title
            color: OverlayLook.colOnLayer1
            font.family: OverlayLook.fontMain
            font.pixelSize: OverlayLook.typeMeta
            font.weight: Font.Medium
        }
        StyledText {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideMiddle
            text: Directories.shortHomePath(folderRow.path)
            color: OverlayLook.colSubtext
            font.family: OverlayLook.fontMain
            font.pixelSize: OverlayLook.typeMeta
        }
        OverlayButton {
            size: Math.round(26 * root.d)
            glyph: "folder_open"
            tip: Translation.tr("Open folder")
            onClicked: folderRow.openRequested()
        }
        OverlayButton {
            size: Math.round(26 * root.d)
            glyph: "drive_file_move"
            tip: Translation.tr("Change folder")
            onClicked: folderRow.changeRequested()
        }
    }
}
