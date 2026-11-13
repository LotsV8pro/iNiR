pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.services
import "root:modules/common/functions/LyricsMath.js" as LyricsMath

// The same reading as the player: the line being sung fills word by word (laid out by a TextEdit, the sung part drawn
// by clipped copies of it), and a stretch without voice is three dots that light one by one. The times come from
// LyricsMath.stage(): a lyrics file only says when a LINE starts, so the words share the line's time.
Item {
    id: root

    property color textColor: Appearance.zzzEverywhere ? Appearance.zzz.inkMuted : Appearance.inirEverywhere ? Appearance.inir.colTextSecondary : Appearance.colors.colSubtext
    property color activeColor: Appearance.zzzEverywhere ? Appearance.zzz.ink : Appearance.inirEverywhere ? Appearance.inir.colText : Appearance.colors.colOnLayer0
    property color indicatorColor: Appearance.colors.colPrimaryContainer
    property int textAlignment: Text.AlignHCenter
    property int lineSpacing: 8

    property int baseSize: Appearance.font.pixelSize.normal
    property real activeScale: 1.18
    property int falloff: 4
    property bool showPlaceholder: true

    implicitWidth: 160
    implicitHeight: 72

    // The lines staged once per track: words timed, instrumental stretches as gap entries.
    property var stagedLines: []
    // The song's time, a frame at a time while it plays and is seen.
    property real songTime: 0

    readonly property bool hasLyrics: LyricsService.status === "ok" && root.stagedLines.length > 0
    readonly property bool singing: root.hasLyrics
    // The line that is on: the last one whose time has come (a gap lights its dots while it lasts).
    readonly property int activeIndex: root.hasLyrics ? LyricsMath.indexAt(root.stagedLines, root.songTime) : -1
    // With no word timings the whole phrase is already ink; with them the phrase waits dim and lights as it is sung.
    readonly property color waitingColor: ColorUtils.mix(root.activeColor, root.textColor, 0.5)

    property bool _subscribed: false

    function restage(): void {
        const source = LyricsService.status === "ok" ? LyricsService.lyricsLines : [];
        root.stagedLines = (source && source.length > 0 && !LyricsMath.isNotice(source))
            ? LyricsMath.stage(source) : [];
        root.songTime = LyricsService.clockAt(Date.now());
    }

    function syncSubscription(): void {
        const shouldSubscribe = root.visible;
        if (shouldSubscribe === root._subscribed)
            return;

        root._subscribed = shouldSubscribe;
        if (shouldSubscribe)
            LyricsService.subscribe(root);
        else
            LyricsService.unsubscribe(root);
    }

    onVisibleChanged: {
        root.syncSubscription();
        root.songTime = LyricsService.clockAt(Date.now());
    }
    Component.onCompleted: {
        root.syncSubscription();
        root.restage();
    }
    Component.onDestruction: {
        if (root._subscribed) {
            root._subscribed = false;
            LyricsService.unsubscribe(root);
        }
    }

    Connections {
        target: LyricsService
        function onLyricsLinesChanged() { root.restage() }
        function onStatusChanged() { root.restage() }
        function onPlayingChanged() { root.songTime = LyricsService.clockAt(Date.now()) }
    }

    // A seek or a pause moves the anchor: the held time follows it even while the frame timer is stopped.
    readonly property var _clock: [LyricsService.clockPos, LyricsService.clockMs, LyricsService.playing, root.visible]
    on_ClockChanged: root.songTime = LyricsService.clockAt(Date.now())

    // The fill's front is smooth, so the clock is read a frame at a time while the song plays and is seen.
    Timer {
        interval: 33
        repeat: true
        triggeredOnStart: true
        running: root.visible && root.singing && LyricsService.playing
        onTriggered: root.songTime = LyricsService.clockAt(Date.now())
    }

    // One line laid out for the karaoke: the three layers (waited, sung, soft edge) all match this one.
    component KaraokeText: TextEdit {
        required property Item line
        width: line.width
        text: line.lineText
        readOnly: true
        enabled: false
        focus: false
        selectByMouse: false
        activeFocusOnPress: false
        textFormat: TextEdit.PlainText
        textMargin: 0
        wrapMode: TextEdit.Wrap
        horizontalAlignment: root.textAlignment
        renderType: TextEdit.NativeRendering
        font.family: Appearance.font.family.main
        font.pixelSize: root.baseSize
        font.weight: Font.Medium
        font.hintingPreference: Font.PreferDefaultHinting
        font.variableAxes: Appearance.font.variableAxes.main
        font.letterSpacing: Appearance.zzzEverywhere ? (Appearance.zzz.tracking ?? 0)
            : Appearance.regaliaEverywhere ? 0.12 : 0
    }

    Item {
        id: placeholder
        anchors.fill: parent
        opacity: (root.hasLyrics || !root.showPlaceholder) ? 0 : 1
        visible: opacity > 0

        Behavior on opacity {
            enabled: Appearance.animationsEnabled
            NumberAnimation {
                duration: Appearance.animation.elementMoveFast.duration
                easing.type: Appearance.animation.elementMoveFast.type
                easing.bezierCurve: Appearance.animation.elementMoveFast.bezierCurve
            }
        }

        readonly property bool isLoading: LyricsService.status === "loading" || LyricsService.status === "idle"
        readonly property bool isNoTrack: LyricsService.status === "no_info"
        readonly property bool isOffline: LyricsService.status === "offline"

        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(parent.width, 260)
            spacing: 10

            MaterialLoadingIndicator {
                Layout.alignment: Qt.AlignHCenter
                visible: placeholder.isLoading
                loading: visible
                color: root.indicatorColor
                implicitSize: 30
            }

            MaterialSymbol {
                Layout.alignment: Qt.AlignHCenter
                visible: !placeholder.isLoading
                text: placeholder.isNoTrack ? "music_off" : placeholder.isOffline ? "cloud_off" : "lyrics"
                iconSize: 28
                color: ColorUtils.applyAlpha(root.textColor, 0.55)
            }

            StyledText {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: ColorUtils.applyAlpha(root.textColor, 0.85)
                text: placeholder.isLoading ? Translation.tr("Looking for lyrics")
                    : placeholder.isNoTrack ? Translation.tr("Nothing playing")
                    : placeholder.isOffline ? Translation.tr("Lyrics need an internet connection")
                    : Translation.tr("No synced lyrics for this track")
            }
        }
    }

    Item {
        id: viewport
        anchors.fill: parent
        clip: true
        opacity: root.hasLyrics ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            enabled: Appearance.animationsEnabled
            NumberAnimation {
                duration: Appearance.animation.elementMoveFast.duration
                easing.type: Appearance.animation.elementMoveFast.type
                easing.bezierCurve: Appearance.animation.elementMoveFast.bezierCurve
            }
        }

        Column {
            id: lyricColumn
            width: Math.floor(viewport.width / Math.max(1, root.activeScale))
            x: root.textAlignment === Text.AlignHCenter
                ? Math.round((viewport.width - width) / 2)
                : root.textAlignment === Text.AlignRight
                    ? viewport.width - width
                    : 0
            spacing: root.lineSpacing

            readonly property real targetY: {
                const count = lyricRepeater.count;
                if (count === 0)
                    return 0;
                const item = lyricRepeater.itemAt(Math.max(0, Math.min(root.activeIndex, count - 1)));
                if (!item)
                    return 0;
                return Math.round(viewport.height / 2 - (item.y + item.height / 2));
            }

            y: lyricColumn.targetY

            Behavior on y {
                enabled: Appearance.animationsEnabled
                NumberAnimation {
                    duration: Appearance.animation.elementMove.duration
                    easing.type: Appearance.animation.elementMove.type
                    easing.bezierCurve: Appearance.animation.elementMove.bezierCurve
                }
            }

            Repeater {
                id: lyricRepeater
                model: root.stagedLines

                delegate: Item {
                    id: lineRow
                    required property int index
                    required property var modelData

                    readonly property bool gap: lineRow.modelData.gap === true
                    readonly property string lineText: lineRow.gap ? "" : String(lineRow.modelData.text ?? "")
                    readonly property bool isActive: lineRow.index === root.activeIndex
                    // Word by word only when the source stamped the words. A line that only knows when it starts
                    // lights whole, as the app draws those; no sweep is invented from its syllables.
                    readonly property bool karaoke: lineRow.isActive && !lineRow.gap && lineRow.lineText.length > 0
                        && lineRow.modelData.synced === true
                        && lineRow.modelData.words !== undefined
                        && lineRow.modelData.words !== null
                        && lineRow.modelData.words.length > 0
                    // Where the singing is inside the phrase, in characters (fractional inside the word being sung).
                    readonly property real sung: lineRow.karaoke ? LyricsMath.sungTo(lineRow.modelData.words, root.songTime) : 0
                    // The rows above the front are sung whole; its own row is sung up to here.
                    readonly property rect caret: {
                        void (karaokeBase.text + karaokeBase.lineCount + karaokeBase.contentWidth
                            + karaokeBase.contentHeight + karaokeBase.font.pixelSize + karaokeBase.width)
                        if (!lineRow.karaoke || lineRow.sung <= 0 || karaokeBase.length === 0
                                || karaokeBase.text !== lineRow.lineText)
                            return Qt.rect(0, 0, 0, 0)
                        const i = Math.min(Math.floor(lineRow.sung), karaokeBase.length)
                        const f = lineRow.sung - i
                        const a = karaokeBase.positionToRectangle(i)
                        if (f <= 0 || i >= karaokeBase.length)
                            return a
                        const b = karaokeBase.positionToRectangle(i + 1)
                        return b.y === a.y ? Qt.rect(a.x + (b.x - a.x) * f, a.y, 0, a.height) : a
                    }
                    readonly property real softEdge: Math.max(6, Math.round(root.baseSize * 0.6))

                    readonly property int distance: Math.abs(lineRow.index - root.activeIndex)

                    width: lyricColumn.width
                    height: lineRow.gap
                        ? Math.ceil(root.baseSize * 1.7)
                        : Math.ceil(lineRow.karaoke ? karaokeBase.contentHeight : plainLine.implicitHeight)

                    opacity: {
                        if (lineRow.distance === 0)
                            return 1.0;
                        if (lineRow.distance > root.falloff)
                            return 0.0;
                        return Math.max(0.06, 0.55 - (lineRow.distance - 1) * 0.16);
                    }

                    transformOrigin: root.textAlignment === Text.AlignHCenter ? Item.Center
                        : root.textAlignment === Text.AlignRight ? Item.Right : Item.Left
                    scale: lineRow.isActive ? root.activeScale : 1.0

                    Behavior on opacity {
                        enabled: Appearance.animationsEnabled
                        NumberAnimation {
                            duration: Appearance.animation.elementMove.duration
                            easing.type: Appearance.animation.elementMove.type
                            easing.bezierCurve: Appearance.animation.elementMove.bezierCurve
                        }
                    }
                    Behavior on scale {
                        enabled: Appearance.animationsEnabled
                        NumberAnimation {
                            duration: Appearance.animation.elementMoveEnter.duration
                            easing.type: Appearance.animation.elementMoveEnter.type
                            easing.bezierCurve: Appearance.animation.elementMoveEnter.bezierCurve
                        }
                    }

                    // Every line that is not being sung: one Text, no more.
                    StyledText {
                        id: plainLine
                        visible: !lineRow.karaoke
                        width: parent.width
                        horizontalAlignment: root.textAlignment
                        wrapMode: Text.WordWrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                        text: lineRow.lineText
                        renderType: Text.QtRendering
                        font.pixelSize: root.baseSize
                        font.weight: Font.Medium
                        color: lineRow.isActive ? root.activeColor : root.textColor

                        Behavior on color {
                            enabled: Appearance.animationsEnabled
                            ColorAnimation {
                                duration: Appearance.animation.elementMoveFast.duration
                                easing.type: Appearance.animation.elementMoveFast.type
                                easing.bezierCurve: Appearance.animation.elementMoveFast.bezierCurve
                            }
                        }
                    }

                    // The sung line: the phrase waits in the dim ink, the sung part lights above it.
                    KaraokeText {
                        id: karaokeBase
                        line: lineRow
                        visible: lineRow.karaoke
                        color: root.waitingColor
                    }

                    Item {
                        id: fillLayer
                        anchors.fill: parent
                        visible: lineRow.karaoke && lineRow.sung > 0
                        opacity: lineRow.sung > 0 ? 1 : 0

                        Behavior on opacity {
                            enabled: Appearance.animationsEnabled
                            NumberAnimation {
                                duration: Appearance.animation.elementMoveFast.duration
                                easing.type: Appearance.animation.elementMoveFast.type
                                easing.bezierCurve: Appearance.animation.elementMoveFast.bezierCurve
                            }
                        }

                        Item {
                            width: parent.width
                            height: Math.max(0, lineRow.caret.y)
                            clip: true
                            KaraokeText { line: lineRow; color: root.activeColor }
                        }
                        Item {
                            y: lineRow.caret.y
                            width: Math.max(0, lineRow.caret.x)
                            height: Math.max(1, lineRow.caret.height)
                            clip: true
                            KaraokeText { line: lineRow; y: -lineRow.caret.y; color: root.activeColor }
                        }
                        Item {
                            x: lineRow.caret.x
                            y: lineRow.caret.y
                            width: lineRow.softEdge
                            height: Math.max(1, lineRow.caret.height)
                            clip: true
                            opacity: 0.45
                            visible: lineRow.caret.x > 0 && lineRow.sung < lineRow.lineText.length
                            KaraokeText { line: lineRow; x: -lineRow.caret.x; y: -lineRow.caret.y; color: root.activeColor }
                        }
                    }

                    // A stretch without voice: three dots that light one by one, and fold away as the singing returns.
                    Row {
                        id: dots
                        visible: lineRow.gap
                        x: root.textAlignment === Text.AlignHCenter
                            ? Math.round((lineRow.width - width) / 2)
                            : root.textAlignment === Text.AlignRight ? lineRow.width - width : 0
                        y: Math.round((lineRow.height - height) / 2)
                        spacing: Math.round(root.baseSize * 0.55)

                        readonly property real dotSize: Math.max(5, Math.round(root.baseSize * 0.34))
                        readonly property real start: Number(lineRow.modelData.time ?? 0)
                        readonly property real end: Math.max(dots.start + 0.4, Number(lineRow.modelData.until ?? 0))
                        readonly property real p: dots.end > dots.start
                            ? Math.max(0, Math.min(1, (root.songTime - dots.start) / (dots.end - dots.start))) : 0
                        readonly property real away: LyricsMath.smooth(1 - (dots.end - root.songTime) / 0.5)

                        Repeater {
                            model: 3
                            delegate: Rectangle {
                                required property int index
                                readonly property real lit: LyricsMath.smooth(dots.p * 3.3 - index)
                                width: dots.dotSize
                                height: width
                                radius: width / 2
                                antialiasing: true
                                color: root.activeColor
                                opacity: 0.28 + 0.72 * lit
                                scale: (0.82 + 0.18 * lit) * (1 - dots.away)
                            }
                        }
                    }
                }
            }
        }
    }
}
