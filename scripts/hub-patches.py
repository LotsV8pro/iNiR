#!/usr/bin/env python3
"""This fork's changes to the iRiS hub plugin.

The plugin is not in git: the hub installs it in $XDG_DATA_HOME/inir/plugins/iris and rewrites it on every update
(`setup update`, the Hub page, a reinstall). Anything this fork needs there has to be re-applied afterwards, so the
changes live here as literal searches with their replacement.

An anchor that the hub moved is reported and left alone; a wrong guess would leave QML that does not load. Every
entry is idempotent: once applied, the replacement is found and the file is not touched again.

`scripts/inir run` calls this before the shell starts, which is also the only safe moment. Writing plugin files under
a running shell makes Quickshell hot-reload a half-written tree and lose windows, one output's Island included.

    scripts/hub-patches.py --check   report what is in place
    scripts/hub-patches.py           apply what is missing
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

PLUGIN_ID = "iris"

GOOGLE_CARD = '''
    // Google Calendar: the account behind the Google events, the birthdays and the address book. One OAuth client
    // from Google Cloud is enough (a TV and Limited Input one, or a Desktop one with its secret); the code asks once
    // and every surface that shows events follows.
    ColumnLayout {
        Layout.fillWidth: true
        Layout.bottomMargin: Math.round(6 * root.d)
        spacing: Math.round(6 * root.d)

        RowLayout {
            Layout.fillWidth: true
            spacing: Math.round(8 * root.d)

            IrisText {
                Layout.fillWidth: true
                text: Translation.tr("Google Calendar")
                font.pixelSize: IrisStyle.typeLabel
                font.weight: IrisStyle.weight(Font.DemiBold)
            }
            IrisText {
                text: CalendarSync.googleChecking ? Translation.tr("Checking…")
                    : CalendarSync.googleConnected ? Translation.tr("Connected") : Translation.tr("Not connected")
                font.pixelSize: IrisStyle.typeFootnote
                color: CalendarSync.googleConnected ? IrisStyle.success : IrisStyle.subtext
            }
        }

        IrisText {
            Layout.fillWidth: true
            visible: CalendarSync.googleConnected
            text: String(CalendarSync.googleAccount?.email ?? "")
            font.pixelSize: IrisStyle.typeFootnote
            color: IrisStyle.subtext
            elide: Text.ElideRight
        }

        IrisField {
            id: googleClient
            Layout.fillWidth: true
            implicitHeight: Math.round(34 * root.d)
            font.pixelSize: IrisStyle.typeLabel
            placeholderText: Translation.tr("Client ID")
            text: String(Config.options?.calendar?.googleOAuth?.clientId ?? "")
            onEditingFinished: Config.setNestedValue("calendar.googleOAuth.clientId", googleClient.text.trim())
        }
        IrisField {
            id: googleSecret
            Layout.fillWidth: true
            implicitHeight: Math.round(34 * root.d)
            font.pixelSize: IrisStyle.typeLabel
            placeholderText: Translation.tr("Client secret (Desktop clients only)")
            echoMode: TextInput.Password
            text: String(Config.options?.calendar?.googleOAuth?.clientSecret ?? "")
            onEditingFinished: Config.setNestedValue("calendar.googleOAuth.clientSecret", googleSecret.text.trim())
        }

        IrisText {
            Layout.fillWidth: true
            visible: CalendarSync.googleUserCode.length > 0
            text: Translation.tr("Enter %1 in Google").arg(CalendarSync.googleUserCode)
            font.pixelSize: IrisStyle.typeLabel
            color: IrisStyle.text
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Math.round(8 * root.d)

            IrisButton {
                visible: !CalendarSync.googleConnected
                enabled: CalendarSync.googleClientId.length > 0 || googleClient.text.trim().length > 0
                text: CalendarSync.googleLoopbackRunning || CalendarSync.googleUserCode.length > 0
                    ? Translation.tr("Waiting for Google…") : Translation.tr("Connect")
                colBackground: IrisStyle.tintFill(IrisStyle.accent)
                colBackgroundHover: IrisStyle.tintFillHover(IrisStyle.accent)
                foreground: IrisStyle.accent
                onClicked: CalendarSync.startGoogleAuth()
            }
            IrisButton {
                visible: CalendarSync.googleUserCode.length > 0
                text: Translation.tr("Open Google")
                onClicked: CalendarSync.openGoogleDeviceUrl()
            }
            IrisButton {
                visible: CalendarSync.googleLoopbackRunning || CalendarSync.googleUserCode.length > 0
                text: Translation.tr("Cancel")
                onClicked: CalendarSync.cancelGoogleAuth()
            }
            IrisButton {
                visible: CalendarSync.googleConnected
                text: Translation.tr("Disconnect")
                danger: true
                onClicked: CalendarSync.forgetGoogle()
            }
        }

        IrisText {
            Layout.fillWidth: true
            visible: String(CalendarSync.googleError ?? "").length > 0
            text: String(CalendarSync.googleError ?? "")
            font.pixelSize: IrisStyle.typeFootnote
            color: IrisStyle.danger
            wrapMode: Text.Wrap
        }
    }
'''

GOOGLE_ROWS = '''        { section: "sources", group: "Calendar", label: "Write new events to Google", description: "An event made in iNiR lands in the account's main calendar too, once the account is connected in Calendars.", path: "calendar.googleOAuth.pushEnabled", visibleWhen: "calendar.externalSync.enable", kind: "switch", fallback: false, keywords: ["google", "push", "upload", "sync", "events", "calendario", "eventos"] },
        { section: "sources", group: "Calendar", label: "Google brings in", description: "How far ahead the Google calendars are read.", path: "calendar.googleOAuth.importDays", visibleWhen: "calendar.externalSync.enable", kind: "range", fallback: 365, min: 30, max: 730, step: 30, unit: " days", keywords: ["google", "import", "days", "ahead", "calendario", "dias"] },
'''

PATCHES = [
    # The widget look reads the palette the family solved for the session; each widget wears a view of it reseeded with
    # the picture under its own screen (DesktopWidgetLook.viewFor). Its chips and guides still asked IrisStyle for the
    # session accent, which follows the scheme and knows nothing about the wallpaper.
    {
        "id": "look-chip-edge",
        "file": "widgets/IrisWidgetLook.qml",
        "old": "    chipEdgeColor: IrisStyle.tintBorder(IrisStyle.accent)",
        "new": "    chipEdgeColor: IrisStyle.tintBorder(look.accent)",
        "summary": "chip edge in the widget accent",
    },
    {
        "id": "look-guide-fill",
        "file": "widgets/IrisWidgetLook.qml",
        "old": "    guideFill: IrisStyle.tintFill(IrisStyle.accent)",
        "new": "    guideFill: IrisStyle.tintFill(look.accent)",
        "summary": "drag guide in the widget accent",
    },
    {
        "id": "look-chip-glyph",
        "file": "widgets/IrisWidgetLook.qml",
        "old": "    function chipGlyphInk(selected: bool): color { return selected ? IrisStyle.accent : look.chipInk(selected) }",
        "new": "    function chipGlyphInk(selected: bool): color { return selected ? look.accent : look.chipInk(selected) }",
        "summary": "chosen chip glyph in the widget accent",
    },
    {
        "id": "look-chip-fill",
        "file": "widgets/IrisWidgetLook.qml",
        "old": "        return selected ? IrisStyle.tintFill(IrisStyle.accent) : hovered ? IrisStyle.fillHover : IrisStyle.fill",
        "new": "        return selected ? IrisStyle.tintFill(look.accent) : hovered ? IrisStyle.fillHover : IrisStyle.fill",
        "summary": "chosen chip fill in the widget accent",
    },
    {
        "id": "look-dark-plate",
        "file": "widgets/IrisWidgetLook.qml",
        "old": "        return widget.familyDesign && widget.forceDarkInk ? ColorUtils.mix(IrisStyle.text, IrisStyle.accent, 0.98)",
        "new": "        return widget.familyDesign && widget.forceDarkInk ? ColorUtils.mix(IrisStyle.text, look.accent, 0.98)",
        "summary": "dark plate carries the widget accent",
    },
    # The quick controls' stack page, its rotate switch and its chips.
    {
        "id": "stack-page-fill",
        "file": "widgets/IrisStackControls.qml",
        "old": "                color: page.shown ? IrisStyle.tintFill(IrisStyle.accent)",
        "new": "                color: page.shown ? IrisStyle.tintFill(root.widget.look.accent)",
        "summary": "stack page fill in the widget accent",
    },
    {
        "id": "stack-rotate-tint",
        "file": "widgets/IrisStackControls.qml",
        "old": "        tint: IrisStyle.accent",
        "new": "        tint: root.widget.look.accent",
        "summary": "rotate switch in the widget accent",
    },
    {
        "id": "stack-interval-accent",
        "file": "widgets/IrisStackControls.qml",
        "old": """            FaceChoice {
                required property int modelData
                Layout.fillWidth: true
                label: root.intervalLabel(modelData)""",
        "new": """            FaceChoice {
                required property int modelData
                Layout.fillWidth: true
                accent: root.widget.look.accent
                label: root.intervalLabel(modelData)""",
        "summary": "interval chips in the widget accent",
    },
    {
        "id": "stack-join-accent",
        "file": "widgets/IrisStackControls.qml",
        "old": """            FaceChoice {
                required property string modelData
                readonly property var facts: root.entry(modelData)""",
        "new": """            FaceChoice {
                required property string modelData
                accent: root.widget.look.accent
                readonly property var facts: root.entry(modelData)""",
        "summary": "join chips in the widget accent",
    },
    # The chip itself: a property the caller sets, the session accent when nobody does.
    {
        "id": "face-choice-accent",
        "file": "widgets/FaceChoice.qml",
        "old": """    property string icon: ""
    property string label: ""
    property bool selected: false""",
        "new": """    property string icon: ""
    property string label: ""
    property bool selected: false
    // Set by the caller to the accent of the widget the chip stands on: the session's follows the scheme.
    property color accent: IrisStyle.accent""",
        "summary": "FaceChoice takes an accent",
    },
    {
        "id": "face-choice-edge",
        "file": "widgets/FaceChoice.qml",
        "old": "    border.color: IrisStyle.tintBorder(IrisStyle.accent)",
        "new": "    border.color: IrisStyle.tintBorder(root.accent)",
        "summary": "FaceChoice edge in the chip accent",
    },
    {
        "id": "screentime-choice-accent",
        "file": "widgets/IrisScreenTimeFace.qml",
        "old": """        FaceChoice {
            icon: "toggle_on"
            label: Translation.tr("Turn on")""",
        "new": """        FaceChoice {
            icon: "toggle_on"
            accent: root.accent
            label: Translation.tr("Turn on")""",
        "summary": "screen time chip in the widget accent",
    },
    {
        "id": "news-choice-accent",
        "file": "widgets/IrisNewsFace.qml",
        "old": """                FaceChoice {
                    visible: blankNews.failed""",
        "new": """                FaceChoice {
                    visible: blankNews.failed
                    accent: root.accent""",
        "summary": "news retry chip in the widget accent",
    },
    # Today's marks: the solid fill under its own ink, as the month calendar and the week strip draw it.
    {
        "id": "clock-today",
        "file": "widgets/IrisClockFace.qml",
        "old": '                color: weekday.today ? (root.nothing ? root.signal : IrisStyle.accentFill) : "transparent"',
        "new": '                color: weekday.today ? (root.nothing ? root.signal : root.accent) : "transparent"',
        "summary": "today in the week strip in the widget accent",
    },
    {
        "id": "calendar-today-fill",
        "file": "widgets/IrisCalendarFace.qml",
        "old": "    readonly property color todayFill: root.nothing ? root.signal : IrisStyle.accentFill",
        "new": "    readonly property color todayFill: root.nothing ? root.signal : root.accent",
        "summary": "today's bubble in the widget accent",
    },
    {
        "id": "calendar-today-ink",
        "file": "widgets/IrisCalendarFace.qml",
        "old": "    readonly property color todayInk: root.nothing ? IrisStyle.onTintFor(root.signal) : IrisStyle.inkOnAccentFill",
        "new": "    readonly property color todayInk: root.nothing ? IrisStyle.onTintFor(root.signal) : IrisStyle.onTintFor(root.accent)",
        "summary": "ink on today's bubble follows its fill",
    },
    {
        "id": "agenda-today-fill",
        "file": "widgets/IrisAgendaFace.qml",
        "old": "    readonly property color todayFill: root.nothing ? root.signal : IrisStyle.accentFill",
        "new": "    readonly property color todayFill: root.nothing ? root.signal : root.accent",
        "summary": "today in the agenda in the widget accent",
    },
    {
        "id": "agenda-today-ink",
        "file": "widgets/IrisAgendaFace.qml",
        "old": "    readonly property color todayInk: root.nothing ? IrisStyle.onTintFor(root.signal) : IrisStyle.inkOnAccentFill",
        "new": "    readonly property color todayInk: root.nothing ? IrisStyle.onTintFor(root.signal) : IrisStyle.onTintFor(root.accent)",
        "summary": "ink on today's agenda mark follows its fill",
    },
    # The plate of a widget with no face of its own read the session look, not the one its own screen seeded.
    {
        "id": "plate-screen-look",
        "file": "widgets/IrisWidgetPlate.qml",
        "old": "    readonly property var look: DesktopWidgetLook.look",
        "new": "    readonly property var look: DesktopWidgetLook.lookFor(plate.widget)",
        "summary": "plate reads its own screen's look",
    },
    {
        "id": "plate-dark-ink",
        "file": "widgets/IrisWidgetPlate.qml",
        "old": "        : ColorUtils.applyAlpha(plate.surface.colorMode === \"dark\" ? ColorUtils.mix(IrisStyle.text, IrisStyle.accent, 0.98)",
        "new": "        : ColorUtils.applyAlpha(plate.surface.colorMode === \"dark\" ? ColorUtils.mix(IrisStyle.text, plate.look.accent, 0.98)",
        "summary": "dark plate carries the widget accent",
    },
    {
        "id": "size-grip-accent",
        "file": "widgets/IrisSizeGrip.qml",
        "old": "        border.color: IrisStyle.tintBorder(IrisStyle.accent)",
        "new": "        border.color: IrisStyle.tintBorder(root.widget.look.accent)",
        "summary": "size grip in the widget accent",
    },
    # A local event has no end, so nextEntry dropped it the moment its time arrived: the Island said "in 1 min" and
    # then nothing, and an event created here never showed as started. A feed's event is still looked for first; one
    # kept by this desktop covers the rest, counting as running for the minute it begins.
    {
        "id": "face-data-local-running",
        "file": "widgets/IrisFaceData.qml",
        "old": """        const here = new Date(at)
        const running = Array.from(CalendarSync.getEventsForDate(here) ?? []).find(event => !event.allDay && event.endDate
            && new Date(event.startDate).getTime() <= at && at < new Date(event.endDate).getTime())
        if (running) {
            const end = new Date(running.endDate).getTime()""",
        "new": """        const here = new Date(at)
        // A feed's event says when it ends; one this desktop keeps does not, and it counts as running for the minute it
        // begins, so the Island can say it started instead of dropping it once its time arrives.
        const running = Array.from(CalendarSync.getEventsForDate(here) ?? []).find(event => !event.allDay && event.endDate
            && new Date(event.startDate).getTime() <= at && at < new Date(event.endDate).getTime())
            ?? Array.from(Events.getAllEventsForDate(here) ?? []).find(event => !event.allDay
                && root.eventDate(event).getTime() <= at && at < root.eventDate(event).getTime() + 60000)
        if (running) {
            const end = running.endDate ? new Date(running.endDate).getTime() : root.eventDate(running).getTime() + 60000
            // A local event carries its time in dateTime; a feed's in startDate.
            const began = running.startDate ? new Date(running.startDate).getTime() : root.eventDate(running).getTime()
            return { title: root.eventTitle(running), running: true, start: began, end: end,""",
        "summary": "a local event counts as running when it starts",
    },
    # The lead marks were all it said: an event that begins got no notice of its own. It now says "Starting now" once,
    # when the clock reaches it, and the lead marks say how long is left instead of borrowing that sentence a minute
    # early. It also rings when it takes the line, at the last lead mark and at the start, so a person away from the
    # screen hears the event instead of having to look; alert sounds off turns the ring off with the rest.
    {
        "id": "island-event-start",
        "file": "bar/IrisIsland.qml",
        "old": """        onTriggered: {
            const entry = IrisFaces.IrisFaceData.nextEntry(Date.now(), 11)
            if (entry.running || entry.title.length === 0 || entry.start <= 0) return
            const mark = [10, 5, 1].filter(at => at <= root.upcomingLead).find(at => entry.left <= at && entry.left > at - 1)
            const key = entry.start + ":" + mark
            if (mark === undefined || root.eventSaid === key) return
            root.eventSaid = key
            root.showEvent("event", IrisStyle.danger, entry.title,
                entry.left <= 1 ? Translation.tr("Starting now") : Translation.tr("In %1 min").arg(entry.left), 1 - entry.left / root.upcomingLead, "soon")
        }""",
        "new": """        onTriggered: {
            const now = Date.now()
            const entry = IrisFaces.IrisFaceData.nextEntry(now, 11)
            if (entry.title.length === 0 || entry.start <= 0) return
            // The event has begun: said once, at its start, after the lead marks said it was coming.
            if (entry.running) {
                const started = entry.start + ":0"
                if (now - entry.start > 45000 || root.eventSaid === started) return
                root.eventSaid = started
                root.showEvent("event", IrisStyle.danger, entry.title, Translation.tr("Starting now"), -1, "soon")
                if (root.eventShown && (Config.options?.sounds?.notifications ?? true)) Audio.playEvent("calendarEvent")
                return
            }
            const mark = [10, 5, 1].filter(at => at <= root.upcomingLead).find(at => entry.left <= at && entry.left > at - 1)
            const key = entry.start + ":" + mark
            if (mark === undefined || root.eventSaid === key) return
            root.eventSaid = key
            root.showEvent("event", IrisStyle.danger, entry.title,
                Translation.tr("In %1 min").arg(entry.left), 1 - entry.left / root.upcomingLead, "soon")
            if (mark <= 1 && root.eventShown && (Config.options?.sounds?.notifications ?? true)) Audio.playEvent("calendarEvent")
        }""",
        "summary": "an event says it starts when it does",
    },
    # Google Calendar had no surface in Settings: configure the client, press Connect, read the code.
    {
        "id": "settings-google-card",
        "file": "settings/IrisCalendarAccounts.qml",
        "old": """    spacing: Math.round(4 * root.d)

    Repeater {
        model: root.sources""",
        "new": "    spacing: Math.round(4 * root.d)\n" + GOOGLE_CARD + """
    Repeater {
        model: root.sources""",
        "summary": "Google card in Settings > Sources > Calendar",
    },
    {
        "id": "settings-google-rows",
        "file": "settings/IrisOptions.qml",
        "old": '        { section: "sources", group: "Calendar", label: "Refresh every", path: "calendar.externalSync.refreshMinutes", visibleWhen: "calendar.externalSync.enable", kind: "range", fallback: 15, min: 5, max: 120, step: 5, unit: " min" },\n',
        "new": '        { section: "sources", group: "Calendar", label: "Refresh every", path: "calendar.externalSync.refreshMinutes", visibleWhen: "calendar.externalSync.enable", kind: "range", fallback: 15, min: 5, max: 120, step: 5, unit: " min" },\n'
        + GOOGLE_ROWS,
        "summary": "Google push and import rows next to the feed ones",
    },
]


def plugin_root(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).expanduser()
    data = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    return Path(data) / "inir" / "plugins" / PLUGIN_ID


def apply_one(root: Path, entry: dict, check_only: bool) -> str:
    path = root / entry["file"]
    if not path.is_file():
        return "no-file"
    text = path.read_text(encoding="utf-8")
    # The replacement is checked first: several entries add lines to the anchor they were cut from, so the search
    # text is still there after the patch and a second run would add the lines again.
    if entry["new"] in text:
        return "in-place"
    if entry["old"] not in text:
        return "moved"
    if text.count(entry["old"]) > 1:
        return "ambiguous"
    if check_only:
        return "pending"
    # Rename into place: a watcher on the plugin folder sees the old file or the new one, never half of either.
    staging = path.with_name(path.name + ".lotus-new")
    staging.write_text(text.replace(entry["old"], entry["new"], 1), encoding="utf-8")
    os.replace(staging, path)
    return "applied"


def main() -> int:
    parser = argparse.ArgumentParser(description="Re-apply this fork's changes to the iRiS hub plugin.")
    parser.add_argument("--check", action="store_true", help="report only, write nothing")
    parser.add_argument("--root", default=None, help="plugin folder (default: $XDG_DATA_HOME/inir/plugins/iris)")
    parser.add_argument("--quiet", action="store_true", help="print only what needs attention")
    args = parser.parse_args()

    root = plugin_root(args.root)
    if not root.is_dir():
        if not args.quiet:
            print(f"{root} is not there: the iRiS plugin is not installed, nothing to patch")
        return 0

    counts = {"applied": 0, "in-place": 0, "pending": 0}
    problems = []
    if not args.quiet:
        print(f"iRiS plugin at {root}")

    for entry in PATCHES:
        state = apply_one(root, entry, args.check)
        if state in counts:
            counts[state] += 1
        if state in ("applied", "in-place", "pending"):
            if not args.quiet:
                mark = "ok" if state == "in-place" else "todo" if state == "pending" else "fix"
                print(f"  {mark:<4} {entry['id']:<26} {entry['summary']}")
            continue
        problems.append((entry, state))

    for entry, state in problems:
        why = {
            "moved": "the hub moved this line, patch it by hand",
            "no-file": "the hub renamed or removed this file",
            "ambiguous": "the anchor appears more than once, the patch needs more context",
        }[state]
        print(f"  FAIL {entry['id']}: {entry['file']}: {why}", file=sys.stderr)

    if args.check and not args.quiet:
        print(f"{counts['in-place']} in place, {counts['pending']} waiting")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
