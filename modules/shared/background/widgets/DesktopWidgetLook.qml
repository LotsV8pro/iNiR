pragma Singleton
pragma ComponentBehavior: Bound
import Quickshell
import qs.modules.common
import qs.services

// The active family's WidgetLook, or the plain one.
Singleton {
    id: root
    FamilyPartLoader { id: provider; part: "widgetLook" }
    WidgetLook { id: plain }
    readonly property var look: provider.item ?? plain

    // One hue per desk. The family solves its widget palette once for the whole session, seeded with the wallpaper
    // applied last, and that application belongs to the screen in use: a widget on the other monitor wore the hues of
    // the picture beside it, and its colour changed whenever the desk it was not on got a new wallpaper. A widget is
    // therefore reseeded from the picture under its own screen, keeping one hue per desk instead of following the
    // pointer. Only a look that says its widget colours come from the wallpaper is reseeded: a fixed palette is a
    // choice, not a reading.
    function lookFor(widget: var): var {
        const base = root.look
        if (!base || String(base.paletteName ?? "") !== "wallpaper") return base
        const output = String(widget?.outputName ?? "")
        if (output.length === 0) return base
        const seed = root.screenSeed(output)
        if (seed.length === 0) return base
        return root.viewFor(base, output, seed)
    }
    // The mean colour of the picture an output draws, read from the grid the desktop widgets already keep. A clip's
    // still is its first frame, so a video that plays seeds from the frame on screen instead.
    function screenSeed(output: string): string {
        const screen = Quickshell.screens.find(s => s.name === output)
        if (!screen) return ""
        const moving = Wallpapers.movingSeed(output)
        if (moving.length > 0) return moving
        const sample = Lume.read(output, 0, 0, screen.width, screen.height)
        const mean = sample ? Qt.color(sample.color) : null
        // A picture that is mostly dark keeps its colour in a small lit subject. The full-screen mean then has no
        // chroma and the widgets stay on the family's fixed accent; the lit cells carry the wallpaper's hue instead.
        if (!mean || Math.max(mean.r, mean.g, mean.b) - Math.min(mean.r, mean.g, mean.b) < 0.06) {
            const accent = Lume.accentOf(output)
            if (accent) return String(Qt.color(accent))
        }
        return mean ? String(Qt.color(mean)) : ""
    }
    // The token keeps the tone the family solved (lightness, alpha): only the hue and the chroma come from the
    // picture. A picture with no chroma leaves the mark neutral rather than inventing a tint from three units of
    // channel spread, which is the same 6 % the wallpaper palette roles go by.
    function seeded(token: var, seed: var): var {
        const t = Qt.color(token)
        const s = Qt.color(seed)
        if (!t.valid || !s.valid) return t
        const chroma = Math.max(s.r, s.g, s.b) - Math.min(s.r, s.g, s.b)
        if (chroma < 0.06) return Qt.hsla(t.hslHue, 0, t.hslLightness, t.a)
        return Qt.hsla(s.hslHue, Math.min(1, Math.max(t.hslSaturation * 0.55, s.hslSaturation)), t.hslLightness, t.a)
    }
    // A view over the family's look with those colours reseeded: its prototype is the look itself, so every other
    // answer (density, radii, the family's own functions) stays the family's.
    property var _views: ({})
    readonly property var _seededKeys: ["accent", "accent2", "accent3", "palette", "tintedPlate", "guideFill",
        "chipEdgeColor"]
    function viewFor(base: var, output: string, seed: string): var {
        const key = output + "|" + seed
        const kept = root._views[key]
        if (kept && kept.base === base) return kept.view
        const view = Object.create(base)
        for (const name of root._seededKeys) {
            const token = base[name]
            if (token === undefined) continue
            const value = name === "palette" ? Array.from(token).map(c => root.seeded(c, seed))
                : root.seeded(token, seed)
            Object.defineProperty(view, name, { value: value, writable: false, enumerable: true })
        }
        root._views[key] = { base: base, view: view }
        return view
    }

    // Whether a widget holding `held` (its own `look`) may draw what its family lays over it (a face, a plate): that
    // look asks things only the family's answers, so it must be the family's, or the family has none. Asked of the
    // widget's own copy, never of this singleton: a notice from here reached the face's loader before the widget's
    // copy moved, and every face read the plain look and threw on a reload.
    function holds(held: var): bool {
        return Plugins.ready && (held !== plain || Plugins.part(Plugins.active, "widgetLook").length === 0)
    }
}
