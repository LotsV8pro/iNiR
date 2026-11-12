pragma ComponentBehavior: Bound

import QtQuick
import qs.modules.common
import qs.modules.common.functions

// How desktop widgets read in a family: their colours, type and shapes. One object for every widget, asked about the
// widget it is handed. A family says what it does differently through its part `widgetLook`, a WidgetLook; these are the
// plain generated tones and shell fonts for a family that says nothing.
QtObject {
    id: base

    // Over the wallpaper
    property bool adaptsToWallpaper: true
    property bool schemeInk: false
    property bool legibleAlways: false
    property bool shadowsBare: false
    property bool unreadIsLight: !Appearance.m3colors.darkmode
    property color unreadInk: Appearance.colors.colOnLayer0
    property color restBackdrop: Appearance.colors.colLayer0
    property color inkLight: Appearance.m3colors.darkmode ? Appearance.colors.colOnLayer0
        : ColorUtils.mix(Appearance.m3colors.m3inverseOnSurface, Qt.rgba(1, 1, 1, 1), 0.3)
    property color inkDark: Appearance.m3colors.darkmode
        ? ColorUtils.mix(Appearance.m3colors.m3inverseOnSurface, Qt.rgba(0, 0, 0, 1), 0.55)
        : Appearance.colors.colOnLayer0

    // Type
    property bool editorial: false
    function bodyFamily(widget: var): string { return Appearance.font.family.main }
    function numbersFamily(widget: var): string { return Appearance.font.family.numbers }
    function titleFamily(widget: var): string { return Appearance.font.family.main }
    function titleWeight(widget: var): int { return Font.DemiBold }
    function titleTracking(widget: var): real { return 0 }
    function titleScale(widget: var): real { return 1 }
    function spacingScale(widget: var): real { return 1 }
    function labelWeight(widget: var): int { return Font.Medium }
    function metadataTracking(widget: var): real { return 0 }
    function capitalization(widget: var): int { return Font.AllUppercase }
    function caseOf(widget: var, text: string): string { return text.toUpperCase() }

    // The sheet's keys, rows and labels, and the arranging guides
    property real density: 1
    property real labelSize: Appearance.font.pixelSize.smaller
    property real metaSize: Appearance.font.pixelSize.smallest
    property real valueSize: Appearance.font.pixelSize.smaller
    property real sheetTitleSize: Appearance.font.pixelSize.normal
    property int metaCapitalization: Font.AllUppercase
    property real metaSpacing: 1
    property color controlInk: Appearance.colors.colOnLayer2
    property color valueInk: Appearance.colors.colOnLayer2
    property color quietInk: Appearance.colors.colSubtext
    property int feedbackDuration: Appearance.animation.elementMoveFast.duration
    property real rowRadius: Appearance.rounding.small
    property bool tintedKeys: false
    property real chipEdge: 0
    property color chipEdgeColor: "transparent"
    property color tagFill: Appearance.colors.colPrimaryContainer
    property color tagInk: Appearance.colors.colOnPrimaryContainer
    property real tagSize: Appearance.font.pixelSize.smaller
    property real guideRadius: Appearance.rounding.small
    property color guideFill: ColorUtils.applyAlpha(Appearance.colors.colPrimary, 0.08)
    function rowFill(hovered: bool): color { return ColorUtils.applyAlpha(Appearance.colors.colOnLayer2, hovered ? 0.09 : 0.045) }
    function markRadius(size: real): real { return Appearance.rounding.small }
    function chipRadius(height: real): real { return height / 2 }
    function chipInk(selected: bool): color { return selected ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer2 }
    function chipGlyphInk(selected: bool): color { return base.chipInk(selected) }
    // The chosen key is the accent, as in Settings' button groups: the secondary container sat a hair off the idle keys.
    function chipFill(selected: bool, hovered: bool): color {
        return selected ? (hovered ? Appearance.colors.colPrimaryHover : Appearance.colors.colPrimary)
            : ColorUtils.applyAlpha(Appearance.colors.colOnLayer2, hovered ? 0.1 : 0.055)
    }

    // What single widgets ask of a look: room inside a clipped frame, depth under raised shapes, an edge on a shaped pill,
    // what a player's glass reads as over the wallpaper.
    property real clipInset: 0
    property bool glassPlates: false
    property bool softDepth: true
    property bool tileDepth: true
    property bool flatFaces: false
    property color tagHover: Appearance.colors.colSecondaryContainerHover
    property color onAccentContainer: Appearance.colors.colOnPrimaryContainer
    property bool ornaments: true
    property string serifFamily: "serif"
    property real cardInset: 20
    property Component tilePlate: null
    property color pillRing: "transparent"
    property real pillRingWidth: 0
    function emphasisWeight(weight: int): int { return weight }
    function labelTracking(pixelSize: real): real { return pixelSize * 0.08 }
    function glassOver(backdrop: color): color { return Appearance.colors.colLayer0 }

    // What resetting a widget also clears, and the verbs over a shared widget material, where the family has one.
    function resetValues(widget: var): var { return ({}) }
    // Who stands on a plate until they say otherwise: the manifest's `bare`, and what the family adds to it.
    function plateByDefault(widget: var): bool { return !widget.bare }
    function materialAction(action: string): string { return "This family has no shared widget material" }

    // Shape and plate
    function controlRadius(widget: var): real { return Appearance.rounding.normal }
    function cardRadius(widget: var): real { return Appearance.rounding.extralarge }
    function blurAvailable(widget: var): bool { return false }
    function plated(widget: var): bool { return widget.widgetHasSurface && (widget.backgroundOpacity > 0 || widget.effectiveBlur) }
    function readsRegion(widget: var): bool { return false }
    function plateColor(widget: var): color { return widget.widgetSemanticContainer(widget.widgetSurfaceRole) }

    // What a palette role resolves to: { color, onColor, container, onContainer }.
    function semanticSet(widget: var, role: string): var {
        return String(role).startsWith("wallpaper") ? wallpaperSet(widget, role) : plainSet(widget, role)
    }
    // The wallpaper-region palette: the accent is the colour the wallpaper shows under the widget itself, so a widget on
    // a grey patch takes grey, one on a sunset takes its orange. Only lightness moves, and only as far as the region
    // needs for the ink to read: a flat region gives three steps of its own tone, never an invented hue.
    function wallpaperSet(widget: var, role: string): var {
        const known = Boolean(widget._hasBrightness) && widget._regionBg !== undefined
        // Until the wallpaper under this widget is read (the preview and its grid take a moment after a restart), stand
        // on the family's unread ink, never on the wallpaper's global dominant: that one belongs to another part of the
        // picture and showed a teal clock on a grey patch until the widget was moved.
        const region = Qt.color(known ? widget.dominantColor : base.unreadInk)
        const backdrop = known ? Qt.color(widget._regionBg) : Appearance.colors.colLayer0
        // The region's own brightness decides the polarity, not the forced ink mode: a dark patch takes a light accent
        // even when the widget's text is forced dark.
        const lightRegion = known && Number(widget.regionLuminance) >= 0.18
        const toward = lightRegion ? base.inkDark : base.inkLight
        // A near-black (or near-white) patch has no trustworthy hue: its few units of channel spread turn into a strong
        // tint once lightness moves, which is why the grey clock came out teal. Its hue is only kept when there is chroma.
        const chroma = Math.max(region.r, region.g, region.b) - Math.min(region.r, region.g, region.b)
        const hue = chroma >= 0.06 ? region.hslHue : 0
        const saturation = chroma >= 0.06 ? region.hslSaturation : 0
        // Soft sits closest to the backdrop, deep furthest: the pair keeps a hierarchy on a single-tone region.
        const anchor = role === "wallpaperSoft" ? (lightRegion ? 0.44 : 0.66)
            : role === "wallpaperDeep" ? (lightRegion ? 0.22 : 0.88)
            : (lightRegion ? 0.31 : 0.78)
        const seed = Qt.hsla(hue, saturation, anchor, 1)
        const color = ColorUtils.readableAccentInk(seed, backdrop, role === "wallpaperSoft" ? 3.0 : 4.5, toward)
        // The container is the same tone held back toward the region: PixelClock paints whole glyphs with it, so it must
        // stay visible on the wallpaper (a plate-coloured container left half the digits black on black).
        const container = ColorUtils.readableAccentInk(
            Qt.hsla(hue, saturation, lightRegion ? 0.58 : 0.55, 1), backdrop, 2.2, toward)
        return {
            color: color,
            onColor: lightRegion ? base.inkLight : base.inkDark,
            container: container,
            onContainer: ColorUtils.readableAccentInk(color, container, 3.0, toward)
        }
    }
    function plainSet(widget: var, role: string): var {
        const c = Appearance.colors
        // Bare on a light region in a dark theme, an accent takes its container tone: the same
        // generated hue, deep enough to read on the wallpaper instead of the pastel meant for dark.
        const deep = widget.inkOnLight && !widget.widgetHasSurface && Appearance.m3colors.darkmode
        switch (role) {
        case "secondary":
            return { color: deep ? c.colSecondaryContainer : c.colSecondary, onColor: c.colOnSecondary,
                container: c.colSecondaryContainer, onContainer: c.colOnSecondaryContainer }
        case "tertiary":
            return { color: deep ? c.colTertiaryContainer : c.colTertiary, onColor: c.colOnTertiary,
                container: c.colTertiaryContainer, onContainer: c.colOnTertiaryContainer }
        case "warning":
            return { color: deep ? c.colWarningContainer : c.colWarning, onColor: c.colOnTertiary,
                container: c.colWarningContainer, onContainer: c.colOnWarningContainer }
        case "signal":
            return { color: deep ? c.colErrorContainer : c.colError, onColor: c.colOnError,
                container: c.colErrorContainer, onContainer: c.colOnErrorContainer }
        case "surface":
            return { color: c.colOnSurfaceVariant, onColor: c.colLayer2, container: c.colLayer1, onContainer: c.colOnLayer1 }
        default:
            return { color: deep ? c.colPrimaryContainer : c.colPrimary, onColor: c.colOnPrimary,
                container: c.colPrimaryContainer, onContainer: c.colOnPrimaryContainer }
        }
    }
}
