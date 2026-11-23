// The Mac look for GTK 4: one shared stylesheet that restyles GTK's own
// widgets after AppKit's controls (Sonoma metrics and the macOS system
// palette, light and dark), so a SwiftUI app keeps its Mac appearance.
//
// GTK's default theme stays loaded underneath for everything not listed
// here (file choosers, dialogs' internals); each control styled here
// starts from `all: unset` so none of the default theme's borders,
// gradients or backdrop states leak through. Glyphs GTK draws from icons
// (pop-up chevrons, checkmarks, the spinner) are small inline SVGs.
//
// Set RUNWAY_NATIVE_LOOK=1 to keep the desktop's own GTK theme instead.

#if os(Linux)
import Foundation

enum MacTheme {
    /// SF can't ship with Runway; the closest installed face wins.
    static let fontFamilies = ["SF Pro Text", "SF Pro", ".AppleSystemUIFont", "Inter Variable", "Inter", "Cantarell",
                               "Noto Sans", "Helvetica Neue", "Helvetica", "Liberation Sans", "Arial", "sans-serif"]

    static var pangoFamilies: String { fontFamilies.joined(separator: ",") }

    struct Palette {
        var dark: Bool
        var accent: String, accentPressed: String, accentRing: String, accentBorder: String
        var red: String
        var window: String, text: String, secondary: String, tertiary: String, quaternary: String, separator: String
        // Push buttons.
        var face: String, facePressed: String, faceChecked: String, faceDisabled: String
        var buttonShadow: String, buttonShadowDisabled: String
        // Text fields.
        var field: String, fieldBorder: String, fieldTopBorder: String, fieldDisabled: String, placeholder: String, selection: String
        // Tracks (slider, progress, switch off) and knobs.
        var track: String, trackBorder: String, knob: String, knobOff: String, knobShadow: String
        // Checkboxes.
        var check: String, checkShadow: String
        // Segmented controls.
        var segTrack: String, segSelected: String, segShadow: String, segSeparator: String
        // Menus, popovers, tooltips.
        var menu: String, menuBorder: String, menuShadow: String, tooltip: String
        var textBackground: String
        var titlebar: String
        var glyph: String
    }

    static let light = Palette(
        dark: false,
        accent: "#007aff", accentPressed: "#0064d6", accentRing: "rgba(0, 122, 255, 0.5)", accentBorder: "rgba(0, 122, 255, 0.75)",
        red: "#ff3b30",
        window: "#ececec", text: "rgba(0, 0, 0, 0.85)", secondary: "rgba(0, 0, 0, 0.5)", tertiary: "rgba(0, 0, 0, 0.26)",
        quaternary: "rgba(0, 0, 0, 0.1)", separator: "rgba(0, 0, 0, 0.1)",
        face: "#ffffff", facePressed: "#e3e3e3", faceChecked: "#d9d9d9", faceDisabled: "rgba(255, 255, 255, 0.6)",
        buttonShadow: "0 0 0 0.5px rgba(0, 0, 0, 0.12), 0 0.5px 1.5px rgba(0, 0, 0, 0.16), 0 0.5px 0.5px rgba(0, 0, 0, 0.05)",
        buttonShadowDisabled: "0 0 0 0.5px rgba(0, 0, 0, 0.08), 0 0.5px 1px rgba(0, 0, 0, 0.06)",
        field: "#ffffff", fieldBorder: "rgba(0, 0, 0, 0.12)", fieldTopBorder: "rgba(0, 0, 0, 0.17)", fieldDisabled: "rgba(255, 255, 255, 0.5)",
        placeholder: "rgba(0, 0, 0, 0.26)", selection: "rgba(0, 122, 255, 0.28)",
        track: "rgba(0, 0, 0, 0.09)", trackBorder: "rgba(0, 0, 0, 0.04)", knob: "#ffffff", knobOff: "#ffffff",
        knobShadow: "0 0 0 0.5px rgba(0, 0, 0, 0.1), 0 0.5px 2px rgba(0, 0, 0, 0.28), 0 1px 1px rgba(0, 0, 0, 0.06)",
        check: "#ffffff", checkShadow: "0 0 0 0.5px rgba(0, 0, 0, 0.26), 0 0.5px 1px rgba(0, 0, 0, 0.12)",
        segTrack: "rgba(0, 0, 0, 0.065)", segSelected: "#ffffff",
        segShadow: "0 0 0 0.5px rgba(0, 0, 0, 0.08), 0 0.5px 1.5px rgba(0, 0, 0, 0.16)", segSeparator: "rgba(0, 0, 0, 0.13)",
        menu: "rgba(246, 246, 246, 0.97)", menuBorder: "rgba(0, 0, 0, 0.14)",
        menuShadow: "0 0 0 0.5px rgba(0, 0, 0, 0.14), 0 10px 28px rgba(0, 0, 0, 0.16), 0 2px 7px rgba(0, 0, 0, 0.1)",
        tooltip: "#f6f6f6", textBackground: "#ffffff", titlebar: "#e8e8e8", glyph: "#000000")

    static let dark = Palette(
        dark: true,
        accent: "#0a84ff", accentPressed: "#3c9cff", accentRing: "rgba(10, 132, 255, 0.5)", accentBorder: "rgba(10, 132, 255, 0.85)",
        red: "#ff453a",
        window: "#323232", text: "rgba(255, 255, 255, 0.86)", secondary: "rgba(255, 255, 255, 0.55)", tertiary: "rgba(255, 255, 255, 0.25)",
        quaternary: "rgba(255, 255, 255, 0.1)", separator: "rgba(255, 255, 255, 0.1)",
        face: "rgba(255, 255, 255, 0.2)", facePressed: "rgba(255, 255, 255, 0.3)", faceChecked: "rgba(255, 255, 255, 0.34)",
        faceDisabled: "rgba(255, 255, 255, 0.08)",
        buttonShadow: "inset 0 0.5px 0 rgba(255, 255, 255, 0.1), 0 0 0 0.5px rgba(0, 0, 0, 0.22), 0 0.5px 1.5px rgba(0, 0, 0, 0.35)",
        buttonShadowDisabled: "0 0 0 0.5px rgba(0, 0, 0, 0.15)",
        field: "rgba(255, 255, 255, 0.06)", fieldBorder: "rgba(255, 255, 255, 0.13)", fieldTopBorder: "rgba(255, 255, 255, 0.1)",
        fieldDisabled: "rgba(255, 255, 255, 0.02)", placeholder: "rgba(255, 255, 255, 0.25)", selection: "rgba(10, 132, 255, 0.45)",
        track: "rgba(255, 255, 255, 0.13)", trackBorder: "rgba(255, 255, 255, 0.04)", knob: "#ffffff", knobOff: "#d9d9d9",
        knobShadow: "0 0 0 0.5px rgba(0, 0, 0, 0.25), 0 0.5px 2px rgba(0, 0, 0, 0.45)",
        check: "rgba(255, 255, 255, 0.12)", checkShadow: "inset 0 0.5px 0 rgba(255, 255, 255, 0.08), 0 0 0 0.5px rgba(0, 0, 0, 0.35), 0 0.5px 1px rgba(0, 0, 0, 0.25)",
        segTrack: "rgba(0, 0, 0, 0.16)", segSelected: "rgba(255, 255, 255, 0.24)",
        segShadow: "inset 0 0.5px 0 rgba(255, 255, 255, 0.1), 0 0 0 0.5px rgba(0, 0, 0, 0.2), 0 0.5px 1.5px rgba(0, 0, 0, 0.3)",
        segSeparator: "rgba(255, 255, 255, 0.14)",
        menu: "rgba(40, 40, 40, 0.97)", menuBorder: "rgba(255, 255, 255, 0.16)",
        menuShadow: "inset 0 0 0 0.5px rgba(255, 255, 255, 0.14), 0 0 0 0.5px rgba(0, 0, 0, 0.6), 0 10px 28px rgba(0, 0, 0, 0.4), 0 2px 7px rgba(0, 0, 0, 0.3)",
        tooltip: "#2c2c2c", textBackground: "#1e1e1e", titlebar: "#2c2c2c", glyph: "#ffffff")

    // MARK: Glyphs

    /// An SVG as a CSS image, with a 2× rendition for HiDPI.
    static func svg(_ body: String, _ w: Int, _ h: Int) -> String {
        func url(_ scale: Int) -> String {
            let s = "<svg xmlns='http://www.w3.org/2000/svg' width='\(w * scale)' height='\(h * scale)' viewBox='0 0 \(w) \(h)'>\(body)</svg>"
            return "url(\"data:image/svg+xml;base64,\(Data(s.utf8).base64EncodedString())\")"
        }
        return "-gtk-scaled(\(url(1)), \(url(2)))"
    }

    static func stroke(_ d: String, _ color: String, width: Double) -> String {
        "<path d='\(d)' fill='none' stroke='\(color)' stroke-width='\(width)' stroke-linecap='round' stroke-linejoin='round'/>"
    }

    /// ⌃⌄ for pop-up buttons.
    static func popupChevrons(_ color: String, _ w: Int, _ h: Int, width: Double = 1.5) -> String {
        let cx = Double(w) / 2, cy = Double(h) / 2
        let dx = 2.6, gap = 1.6, dy = 2.6
        let up = "M\(cx - dx) \(cy - gap) L\(cx) \(cy - gap - dy) L\(cx + dx) \(cy - gap)"
        let down = "M\(cx - dx) \(cy + gap) L\(cx) \(cy + gap + dy) L\(cx + dx) \(cy + gap)"
        return svg(stroke(up, color, width: width) + stroke(down, color, width: width), w, h)
    }

    static func chevronDown(_ color: String) -> String {
        svg(stroke("M2 4 L5 7 L8 4", color, width: 1.5), 10, 10)
    }

    static func chevronRight(_ color: String) -> String {
        svg(stroke("M4 2 L7 5 L4 8", color, width: 1.5), 10, 10)
    }

    static func checkmark(_ color: String, width: Double = 2) -> String {
        svg(stroke("M3.6 7.4 L6 9.8 L10.6 4.4", color, width: width), 14, 14)
    }

    static func dash(_ color: String) -> String {
        svg(stroke("M4 7 L10 7", color, width: 2), 14, 14)
    }

    static func stepperArrow(up: Bool, _ color: String) -> String {
        svg(stroke(up ? "M2.5 6 L5 3.5 L7.5 6" : "M2.5 4 L5 6.5 L7.5 4", color, width: 1.4), 10, 10)
    }

    /// The Mac's twelve-spoke activity indicator.
    static func spinner(_ color: String) -> String {
        var body = ""
        for i in 0..<12 {
            let a = Double(i) * .pi / 6 - .pi / 2
            let (r0, r1) = (8.2, 14.0)
            let x0 = 16 + r0 * cos(a), y0 = 16 + r0 * sin(a), x1 = 16 + r1 * cos(a), y1 = 16 + r1 * sin(a)
            let opacity = 0.18 + 0.82 * Double(i) / 11
            body += "<line x1='\(f(x0))' y1='\(f(y0))' x2='\(f(x1))' y2='\(f(y1))' stroke='\(color)' stroke-opacity='\(f(opacity))' stroke-width='2.7' stroke-linecap='round'/>"
        }
        return svg(body, 32, 32)
    }

    private static func f(_ v: Double) -> String { String(format: "%.2f", v) }

    static func mobileControlCSS(dark isDark: Bool) -> String {
        let p = isDark ? dark : light
        let menuBackground = isDark ? "#2c2c2e" : "#fafafa"
        let highlight = isDark ? "rgba(255, 255, 255, 0.12)" : "rgba(0, 0, 0, 0.065)"
        return """

        box.rw-mobile-segmented { border-radius: 9px; padding: 2px; box-shadow: none; }
        box.rw-mobile-segmented > button { border-radius: 7px; min-height: 28px; padding: 0 6px; font-size: 13px; }
        menubutton.rw-mobile-menu > button, dropdown.rw-mobile-dropdown > button {
          border-radius: 999px; min-height: 0; padding: 0 10px; box-shadow: none;
        }
        menubutton.rw-mobile-menu > button.flat { padding: 0 10px; }
        dropdown.rw-mobile-dropdown > button { min-height: 30px; font-size: 15px; }
        menubutton.rw-mobile-menu > button:checked, dropdown.rw-mobile-dropdown > button:checked { background-color: \(highlight); }
        menubutton.rw-mobile-menu popover.menu > contents, dropdown.rw-mobile-dropdown popover.background > contents {
          background-color: \(menuBackground); border-radius: 14px; min-width: 160px; padding: 4px 0;
        }
        menubutton.rw-mobile-menu popover.menu modelbutton, dropdown.rw-mobile-dropdown popover listview row {
          min-height: 44px; padding: 0 12px; margin: 0 4px; border-radius: 8px; font-size: 16px;
        }
        menubutton.rw-mobile-menu popover.menu modelbutton:hover,
        menubutton.rw-mobile-menu popover.menu modelbutton:selected,
        menubutton.rw-mobile-menu popover.menu modelbutton:focus-visible {
          background-color: \(highlight); color: \(p.text);
        }
        menubutton.rw-mobile-menu popover.menu modelbutton:hover > check:checked,
        menubutton.rw-mobile-menu popover.menu modelbutton:hover > radio:checked {
          background-image: \(checkmark(p.glyph, width: 1.6));
        }
        menubutton.rw-mobile-menu popover.menu modelbutton:hover > arrow { background-image: \(chevronRight(p.secondary)); }
        """
    }

    // MARK: The stylesheet

    static func fontFamilyCSS(_ families: [String]) -> String {
        families.map { family in
            if family == "sans-serif" { return family }
            let escaped = family.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: ", ")
    }

    static func css(dark isDark: Bool, nativeFont: Bool, families: [String]? = nil) -> String {
        let p = isDark ? dark : light
        let fonts = fontFamilyCSS(families ?? fontFamilies)
        let font = nativeFont ? "" : "font-family: \(fonts); font-size: 13px;"
        let accentGloss = "linear-gradient(to bottom, rgba(255, 255, 255, 0.16), rgba(255, 255, 255, 0))"
        let white = "#ffffff"
        let menuCheck = checkmark(p.glyph, width: 1.6)
        return """
        /* ---- Window and text ---- */
        window { background-color: \(p.window); color: \(p.text); \(font) }
        window.background { background-color: \(p.window); color: \(p.text); }
        popover.background, tooltip { \(font) }
        label > selection, text > selection, textview > text > selection { background-color: \(p.selection); color: inherit; }
        label:disabled { color: \(p.tertiary); }
        button label:disabled { color: inherit; }
        .rw-tap { all: unset; }
        .rw-container { background: none; }
        scrolledwindow.rw-scroll { background: none; }
        undershoot, overshoot { background: none; }

        /* ---- Push buttons ---- */
        button {
          all: unset;
          min-height: 22px; min-width: 0;
          padding: 0 12px;
          border-radius: 5px;
          background-color: \(p.face);
          color: \(p.text);
          box-shadow: \(p.buttonShadow);
          outline: 0 solid transparent; outline-offset: 0;
          -gtk-icon-size: 14px;
        }
        button:active, button.keyboard-activating { background-color: \(p.facePressed); }
        button:checked { background-color: \(p.faceChecked); }
        button:disabled { color: \(p.tertiary); background-color: \(p.faceDisabled); box-shadow: \(p.buttonShadowDisabled); }
        button:focus-visible { outline: 3px solid \(p.accentRing); outline-offset: 0; }
        button > label { padding: 0; }

        button.rw-default, button.suggested-action, button.default {
          background-color: \(p.accent); background-image: \(accentGloss);
          color: \(white);
          box-shadow: inset 0 0.5px 0 rgba(255, 255, 255, 0.18), 0 0 0 0.5px rgba(0, 0, 0, 0.06), 0 0.5px 1.5px rgba(0, 0, 0, 0.22);
        }
        button.rw-default:active, button.suggested-action:active, button.default:active { background-color: \(p.accentPressed); background-image: none; }
        button.rw-default:disabled, button.suggested-action:disabled, button.default:disabled {
          background-color: \(p.faceDisabled); background-image: none; color: \(p.tertiary); box-shadow: \(p.buttonShadowDisabled);
        }
        button.rw-default:focus-visible, button.suggested-action:focus-visible { outline-color: \(p.accentRing); }
        button.rw-destructive, button.destructive-action { color: \(p.red); }
        button.rw-destructive:disabled { color: \(p.tertiary); }
        button.rw-default.rw-destructive { background-color: \(p.red); color: \(white); }

        button.rw-small { min-height: 18px; padding: 0 8px; border-radius: 4px; font-size: 11px; }
        button.rw-large { min-height: 28px; padding: 0 14px; border-radius: 6px; }
        button.rw-content { min-height: 0; padding: 3px 8px; }
        button.rw-content.rw-small { padding: 2px 6px; }
        button.rw-content.rw-large { padding: 6px 12px; }
        button.rw-capsule-button { border-radius: 999px; }

        /* Borderless: no bezel; the content darkens while pressed. */
        button.flat { background: none; box-shadow: none; padding: 0 4px; }
        button.flat:hover { background-color: \(isDark ? "rgba(255, 255, 255, 0.07)" : "rgba(0, 0, 0, 0.05)"); }
        button.flat:active, button.flat:checked { background-color: \(p.quaternary); }
        button.flat:disabled { background: none; }

        /* Links. */
        button.link { all: unset; color: \(p.accent); }
        button.link > label { color: \(p.accent); text-decoration-line: none; }
        button.link:hover > label { text-decoration-line: underline; }
        button.link:visited, button.link:visited > label { color: \(p.accent); }
        button.link:disabled, button.link:disabled > label { color: \(p.tertiary); }
        button.link:focus-visible { outline: 3px solid \(p.accentRing); border-radius: 3px; }

        /* ---- Segmented controls ---- */
        box.rw-segmented {
          background-color: \(p.segTrack);
          border-radius: 6px;
          padding: 1px;
          box-shadow: inset 0 0 0 0.5px \(isDark ? "rgba(0, 0, 0, 0.12)" : "rgba(0, 0, 0, 0.035)");
        }
        box.rw-segmented > button {
          all: unset;
          min-height: 20px; padding: 0 10px;
          border-radius: 5px;
          color: \(p.text);
          background-image: image(\(p.segSeparator));
          background-size: 1px 12px; background-position: left center; background-repeat: no-repeat;
        }
        box.rw-segmented > button:first-child,
        box.rw-segmented > button:checked,
        box.rw-segmented > button:checked + button { background-image: none; }
        box.rw-segmented > button:active:not(:checked) { background-color: \(isDark ? "rgba(255, 255, 255, 0.06)" : "rgba(0, 0, 0, 0.05)"); }
        box.rw-segmented > button:checked { background-color: \(p.segSelected); box-shadow: \(p.segShadow); }
        box.rw-segmented > button:focus-visible { outline: 3px solid \(p.accentRing); }
        box.rw-segmented > button:disabled { color: \(p.tertiary); }
        box.rw-segmented.rw-small > button { min-height: 16px; padding: 0 8px; font-size: 11px; border-radius: 4px; }
        box.rw-segmented.rw-small { border-radius: 5px; }
        box.rw-segmented.rw-large > button { min-height: 26px; padding: 0 12px; }

        /* ---- Switches ---- */
        switch {
          all: unset;
          padding: 1px 3px;
          border-radius: 999px;
          background-color: \(p.track);
          box-shadow: inset 0 0 0 0.5px \(p.trackBorder);
          transition: background-color 150ms ease-out;
          outline: 0 solid transparent;
        }
        switch:checked { background-color: \(p.accent); box-shadow: none; }
        switch:disabled { opacity: 0.5; }
        switch:focus-visible { outline: 3px solid \(p.accentRing); outline-offset: 0; }
        switch > image { all: unset; -gtk-icon-size: 8px; color: transparent; opacity: 0; }
        switch > slider {
          all: unset;
          min-width: 20px; min-height: 20px;
          margin: 0 -2px;
          border-radius: 999px;
          background-color: \(p.knobOff);
          box-shadow: \(p.knobShadow);
        }
        switch:checked > slider { background-color: \(p.knob); }
        switch:active > slider { background-color: \(isDark ? "#c8c8c8" : "#f2f2f2"); }
        switch.rw-small { padding: 1px 2px; }
        switch.rw-small > slider { min-width: 16px; min-height: 16px; margin: 0 -1px; }

        /* ---- Checkboxes ---- */
        checkbutton { all: unset; border-spacing: 6px; outline: 0 solid transparent; }
        checkbutton > check {
          all: unset;
          min-width: 14px; min-height: 14px;
          border-radius: 4px;
          background-color: \(p.check);
          box-shadow: \(p.checkShadow);
          -gtk-icon-size: 14px; -gtk-icon-source: none;
        }
        checkbutton > check:checked, checkbutton > check:indeterminate {
          background-color: \(p.accent); background-image: \(accentGloss);
          box-shadow: inset 0 0.5px 0 rgba(255, 255, 255, 0.15), 0 0 0 0.5px rgba(0, 0, 0, 0.12), 0 0.5px 1px rgba(0, 0, 0, 0.15);
        }
        checkbutton > check:checked { -gtk-icon-source: \(checkmark(white)); }
        checkbutton > check:indeterminate { -gtk-icon-source: \(dash(white)); }
        checkbutton > check:active { filter: brightness(0.93); }
        checkbutton:disabled > check { opacity: 0.5; }
        checkbutton:disabled > label { color: \(p.tertiary); }
        checkbutton:focus-visible > check { outline: 3px solid \(p.accentRing); outline-offset: 0; }
        checkbutton > radio {
          all: unset; min-width: 14px; min-height: 14px; border-radius: 999px;
          background-color: \(p.check); box-shadow: \(p.checkShadow);
          -gtk-icon-source: none;
        }
        checkbutton > radio:checked {
          background-color: \(p.accent);
          background-image: radial-gradient(circle closest-side, \(white) 34%, transparent 42%), \(accentGloss);
          box-shadow: 0 0 0 0.5px rgba(0, 0, 0, 0.12), 0 0.5px 1px rgba(0, 0, 0, 0.15);
        }

        /* ---- Text fields ---- */
        entry, spinbutton {
          all: unset;
          min-height: 20px;
          padding: 0 6px;
          border: 1px solid \(p.fieldBorder);
          border-top-color: \(p.fieldTopBorder);
          border-radius: 5px;
          background-color: \(p.field);
          color: \(p.text);
          caret-color: \(p.accent);
          box-shadow: 0 0 0 0 transparent;
          transition: box-shadow 160ms ease-out, border-color 160ms ease-out;
        }
        entry:focus-within, spinbutton:focus-within { border-color: \(p.accentBorder); box-shadow: 0 0 0 3px \(p.accentRing); }
        entry:disabled, spinbutton:disabled { color: \(p.tertiary); background-color: \(p.fieldDisabled); }
        entry placeholder, spinbutton placeholder { color: \(p.placeholder); opacity: 1; }
        entry > text, spinbutton > text { all: unset; }
        entry > image { color: \(p.secondary); -gtk-icon-size: 14px; }
        entry > image.left { margin-right: 4px; }
        entry > image.right { margin-left: 4px; }
        entry.rw-plain, entry.rw-plain:focus-within { border: none; background: none; box-shadow: none; padding: 0; }
        entry.rw-small { min-height: 17px; font-size: 11px; padding: 0 5px; }
        entry.rw-large { min-height: 26px; padding: 0 8px; border-radius: 6px; }
        spinbutton > button { all: unset; padding: 0 4px; color: \(p.secondary); }

        /* Multi-line text (TextEditor). */
        scrolledwindow.rw-editor { background-color: \(p.textBackground); }
        textview, textview > text { background-color: transparent; color: \(p.text); caret-color: \(p.accent); }
        textview > border { background: none; }

        /* ---- Sliders ---- */
        scale { all: unset; padding: 9px 0; outline: 0 solid transparent; }
        scale > trough {
          all: unset;
          min-height: 4px; min-width: 20px;
          border-radius: 2px;
          background-color: \(p.track);
          box-shadow: inset 0 0 0 0.5px \(p.trackBorder);
        }
        scale > trough > highlight { all: unset; border-radius: 2px; background-color: \(p.accent); }
        scale > trough > fill { all: unset; }
        scale > trough > slider {
          all: unset;
          min-width: 20px; min-height: 20px;
          margin: -8px 0;
          border-radius: 999px;
          background-color: \(p.knob);
          box-shadow: \(p.knobShadow);
        }
        scale > trough > slider:active { background-color: \(isDark ? "#dedede" : "#f4f4f4"); }
        scale:focus-visible > trough > slider { box-shadow: 0 0 0 3px \(p.accentRing), \(p.knobShadow); }
        scale:disabled > trough > highlight { background-color: \(p.tertiary); }
        scale:disabled > trough > slider { background-color: \(isDark ? "#8a8a8a" : "#fafafa"); box-shadow: 0 0 0 0.5px rgba(0, 0, 0, 0.12); }
        scale.rw-small { padding: 7px 0; }
        scale.rw-small > trough > slider { min-width: 16px; min-height: 16px; margin: -6px 0; }
        scale.vertical { padding: 0 9px; }
        scale.vertical > trough { min-width: 4px; min-height: 20px; }
        scale.vertical > trough > slider { margin: 0 -8px; }
        scale marks, scale mark { color: \(p.tertiary); }

        /* ---- Progress ---- */
        progressbar { all: unset; }
        progressbar > text { all: unset; color: \(p.secondary); font-size: 11px; }
        progressbar > trough {
          all: unset;
          min-height: 6px; min-width: 20px;
          border-radius: 3px;
          background-color: \(p.track);
          box-shadow: inset 0 0 0 0.5px \(p.trackBorder);
        }
        progressbar > trough > progress { all: unset; min-height: 6px; border-radius: 3px; background-color: \(p.accent); }
        progressbar:disabled > trough > progress { background-color: \(p.tertiary); }
        progressbar.rw-small > trough, progressbar.rw-small > trough > progress { min-height: 4px; border-radius: 2px; }

        @keyframes rw-spin { to { transform: rotate(1turn); } }
        spinner {
          all: unset;
          min-width: 32px; min-height: 32px;
          -gtk-icon-source: \(spinner(isDark ? "#ffffff" : "#000000"));
          -gtk-icon-size: 32px;
          opacity: 0;
        }
        spinner:checked { opacity: \(isDark ? 0.7 : 0.55); animation: rw-spin 1s steps(12) infinite; }
        spinner.rw-small { min-width: 16px; min-height: 16px; -gtk-icon-size: 16px; }
        spinner.rw-large { min-width: 48px; min-height: 48px; -gtk-icon-size: 48px; }

        /* ---- Pop-up buttons (Picker) ---- */
        dropdown { all: unset; }
        dropdown > button { padding: 0 3px 0 9px; }
        dropdown > button > box { border-spacing: 7px; }
        dropdown > button > box > stack > row, dropdown > button > box > stack > row:hover { all: unset; }
        dropdown > button > box > arrow {
          all: unset;
          min-width: 16px; min-height: 16px;
          border-radius: 4px;
          background-color: \(p.accent);
          background-image: \(popupChevrons(white, 16, 16)), \(accentGloss);
          background-size: 16px 16px, auto;
          background-repeat: no-repeat; background-position: center;
          box-shadow: 0 0.5px 1px rgba(0, 0, 0, 0.15);
          -gtk-icon-source: none;
        }
        dropdown > button:disabled > box > arrow { background-color: \(p.quaternary); background-image: \(popupChevrons(isDark ? "rgba(255,255,255,0.4)" : "rgba(0,0,0,0.3)", 16, 16)); box-shadow: none; }
        dropdown.rw-small > button { padding: 0 2px 0 7px; }
        dropdown.rw-small > button > box > arrow { min-width: 13px; min-height: 13px; border-radius: 3px; background-image: \(popupChevrons(white, 13, 13, width: 1.3)), \(accentGloss); background-size: 13px 13px, auto; }
        /* In grouped forms: borderless, value and chevrons only. */
        dropdown.rw-borderless > button { background: none; box-shadow: none; padding: 0 3px 0 6px; }
        dropdown.rw-borderless > button:hover { background-color: \(isDark ? "rgba(255, 255, 255, 0.07)" : "rgba(0, 0, 0, 0.05)"); }
        dropdown.rw-borderless > button:active, dropdown.rw-borderless > button:checked { background-color: \(p.quaternary); }
        dropdown.rw-borderless > button > box { border-spacing: 4px; }
        dropdown.rw-borderless > button > box > arrow {
          min-width: 10px; background-color: transparent; box-shadow: none;
          background-image: \(popupChevrons(p.secondary, 10, 16, width: 1.4));
          background-size: 10px 16px; background-position: center;
        }

        /* ---- Pull-down menus (Menu) ---- */
        menubutton { all: unset; }
        menubutton > button { padding: 0 7px 0 10px; }
        menubutton > button > box { border-spacing: 5px; }
        menubutton > button > box > arrow, menubutton > button > arrow {
          all: unset; min-width: 10px; min-height: 10px;
          background-image: \(chevronDown(p.secondary)); background-size: 10px 10px; background-repeat: no-repeat;
          background-position: center; -gtk-icon-source: none;
        }
        menubutton > button.image-button { padding: 0 6px; }
        menubutton > button.flat { padding: 0 4px; }

        /* ---- Steppers ---- */
        box.rw-stepper {
          min-width: 15px;
          border-radius: 5px;
          background-color: \(p.face);
          box-shadow: \(p.buttonShadow);
        }
        box.rw-stepper > button {
          all: unset;
          min-width: 15px; min-height: 11px;
          background-size: 10px 10px; background-position: center; background-repeat: no-repeat;
        }
        box.rw-stepper > button:first-child { border-radius: 5px 5px 0 0; background-image: \(stepperArrow(up: true, p.text)); }
        box.rw-stepper > button:last-child { border-radius: 0 0 5px 5px; background-image: \(stepperArrow(up: false, p.text)); }
        box.rw-stepper > button:active { background-color: \(p.quaternary); }
        box.rw-stepper > button:disabled { opacity: 0.4; }
        box.rw-stepper:disabled { background-color: \(p.faceDisabled); box-shadow: \(p.buttonShadowDisabled); }

        /* ---- Colour wells ---- */
        colorbutton > button, button.color { padding: 3px; min-height: 0; }
        colorbutton > button > colorswatch, button.color > colorswatch {
          min-width: 36px; min-height: 15px; border-radius: 3px; box-shadow: none;
        }
        colorbutton colorswatch > overlay, button.color colorswatch > overlay {
          border: none; border-radius: 3px; box-shadow: inset 0 0 0 1px rgba(0, 0, 0, 0.08);
        }

        /* ---- Menus and popovers ---- */
        popover.background { background: none; padding: 0; color: \(p.text); }
        popover.background > arrow { all: unset; }
        popover.background > contents {
          all: unset;
          padding: 5px 0;
          border-radius: 7px;
          background-color: \(p.menu);
          color: \(p.text);
          box-shadow: \(p.menuShadow);
        }
        popover.background > contents separator { all: unset; min-height: 1px; margin: 5px 10px; background-color: \(p.separator); }
        popover.menu modelbutton {
          all: unset;
          min-height: 22px;
          padding: 0 10px 0 8px;
          margin: 0 5px;
          border-radius: 4px;
          border-spacing: 4px;
          color: \(p.text);
        }
        popover.menu modelbutton:hover, popover.menu modelbutton:selected, popover.menu modelbutton:focus-visible { background-color: \(p.accent); color: \(white); }
        popover.menu modelbutton:disabled { background: none; color: \(p.tertiary); }
        popover.menu modelbutton > label { padding: 0; }
        popover.menu modelbutton > check, popover.menu modelbutton > radio {
          all: unset; min-width: 12px; min-height: 12px; margin: 0 2px 0 0;
          -gtk-icon-source: none; -gtk-icon-size: 12px;
        }
        popover.menu modelbutton > check:checked, popover.menu modelbutton > radio:checked {
          background-image: \(menuCheck); background-size: 12px 12px; background-repeat: no-repeat; background-position: center;
        }
        popover.menu modelbutton:hover > check:checked, popover.menu modelbutton:hover > radio:checked {
          background-image: \(checkmark(white, width: 1.6));
        }
        popover.menu modelbutton > arrow { all: unset; min-width: 10px; min-height: 10px; -gtk-icon-source: none;
          background-image: \(chevronRight(p.secondary)); background-size: 10px 10px; background-repeat: no-repeat; background-position: center; }
        popover.menu modelbutton:hover > arrow { background-image: \(chevronRight(white)); }
        popover.menu modelbutton > accelerator { color: \(p.tertiary); margin-left: 16px; }
        popover.menu modelbutton:hover > accelerator { color: rgba(255, 255, 255, 0.7); }
        popover.menu box.inline-buttons, popover.menu box.circular-buttons { padding: 0 10px; }

        /* Pop-up button lists. */
        dropdown popover { margin-top: 2px; padding: 0; }
        dropdown popover.background > contents { padding: 5px 0; }
        dropdown popover scrolledwindow, dropdown popover listview { all: unset; background: none; }
        dropdown popover listview > row {
          all: unset;
          min-height: 22px;
          padding: 0 14px 0 4px;
          margin: 0 5px;
          border-radius: 4px;
          color: \(p.text);
        }
        dropdown popover listview > row:hover, dropdown popover listview > row:selected:hover, dropdown popover listview > row:focus-visible {
          background-color: \(p.accent); color: \(white);
        }
        dropdown popover listview > row:selected { background: none; }
        dropdown popover listview > row image { color: inherit; -gtk-icon-size: 12px; }
        dropdown popover .rw-menu-check { min-width: 12px; min-height: 12px; margin-right: 5px; -gtk-icon-source: none; }
        dropdown popover listview > row:selected .rw-menu-check {
          background-image: \(menuCheck); background-size: 12px 12px; background-repeat: no-repeat; background-position: center;
        }
        dropdown popover listview > row:selected:hover .rw-menu-check { background-image: \(checkmark(white, width: 1.6)); }
        dropdown popover .dropdown-searchbar { padding: 4px 8px; border-bottom: 1px solid \(p.separator); }

        /* ---- Tooltips ---- */
        tooltip.background, tooltip {
          background-color: \(p.tooltip);
          color: \(p.text);
          border-radius: 5px;
          padding: 3px 7px;
          box-shadow: 0 0 0 0.5px \(p.menuBorder), 0 3px 10px rgba(0, 0, 0, 0.15);
          font-size: 11px;
          border: none;
        }
        tooltip > box { border-spacing: 4px; }

        /* ---- Scroll bars: thin overlay capsules ---- */
        scrollbar { background: none; border: none; box-shadow: none; }
        scrollbar > range > trough { background: none; border: none; }
        scrollbar > range > trough > slider {
          min-width: 7px; min-height: 7px; margin: 0; border: 3px solid transparent; border-radius: 999px;
          background-clip: padding-box; background-color: \(isDark ? "rgba(255, 255, 255, 0.4)" : "rgba(0, 0, 0, 0.4)");
        }
        scrollbar > range > trough > slider:hover, scrollbar > range > trough > slider:active { background-color: \(isDark ? "rgba(255, 255, 255, 0.55)" : "rgba(0, 0, 0, 0.55)"); }
        scrollbar.overlay-indicator:not(.dragging):not(.hovering) > range > trough > slider {
          min-width: 5px; min-height: 5px; margin: 0; border: 2px solid transparent;
          background-color: \(isDark ? "rgba(255, 255, 255, 0.35)" : "rgba(0, 0, 0, 0.35)");
        }

        /* ---- Separators ---- */
        separator { background-color: \(p.separator); min-width: 1px; min-height: 1px; }

        /* ---- Title bars (client-side decorations) ---- */
        window.csd { border-radius: 10px; }
        /* Without a compositor GTK draws resize borders inside the window
           (padding), taking them from the size the app asked for: none,
           as on the Mac, with a hairline edge instead. */
        window.solid-csd { padding: 0; margin: 0; border-radius: 0; box-shadow: none; border: none; }
        window.solid-csd > .titlebar { border-radius: 0; }
        headerbar, .titlebar:not(headerbar) {
          min-height: 28px;
          padding: 0 8px;
          border: none;
          background: \(p.titlebar);
          box-shadow: inset 0 -1px \(p.separator);
          color: \(p.text);
        }
        headerbar:backdrop, .titlebar:backdrop:not(headerbar) { background: \(p.window); }
        headerbar .title { font-weight: bold; font-size: 13px; padding: 0 12px; }
        headerbar:backdrop .title { color: \(p.tertiary); filter: none; }
        headerbar entry, headerbar spinbutton, headerbar button, headerbar menubutton, headerbar separator:not(.sidebar) { margin-top: 3px; margin-bottom: 3px; }
        /* Toolbar items: bezel-less until hovered. */
        headerbar box.start > button:not(.suggested-action):not(.destructive-action),
        headerbar box.end > button:not(.suggested-action):not(.destructive-action),
        headerbar menubutton > button { background: none; box-shadow: none; padding: 0 6px; }
        headerbar box.start > button:not(.suggested-action):hover, headerbar box.end > button:not(.suggested-action):hover,
        headerbar menubutton > button:hover { background-color: \(isDark ? "rgba(255, 255, 255, 0.07)" : "rgba(0, 0, 0, 0.05)"); }
        headerbar box.start > button:not(.suggested-action):active, headerbar box.end > button:not(.suggested-action):active,
        headerbar box.start > button:not(.suggested-action):checked, headerbar box.end > button:not(.suggested-action):checked,
        headerbar menubutton > button:checked { background-color: \(p.quaternary); }
        windowcontrols { border-spacing: 8px; margin: 0 6px; }
        windowcontrols > button, windowcontrols button {
          all: unset;
          min-width: 12px; min-height: 12px; margin: 0;
          border-radius: 999px;
          box-shadow: inset 0 0 0 0.5px rgba(0, 0, 0, 0.14);
          -gtk-icon-size: 8px;
        }
        windowcontrols button > image { color: transparent; }
        windowcontrols:hover button > image { color: rgba(0, 0, 0, 0.55); }
        windowcontrols button.close { background-color: #ff5f57; }
        windowcontrols button.minimize { background-color: #febc2e; }
        windowcontrols button.maximize { background-color: #28c840; }
        windowcontrols button:active { filter: brightness(0.85); }
        window:backdrop windowcontrols:not(:hover) button { background-color: \(isDark ? "rgba(255, 255, 255, 0.18)" : "rgba(0, 0, 0, 0.13)"); box-shadow: none; }
        /* The titlebar row: window buttons, the menu bar (the Mac's, at the
           top of the screen there), the title. */
        windowhandle.rw-titlebar { min-height: 28px; padding: 0 8px 0 10px; }
        windowhandle.rw-titlebar.rw-titlebar-merged { min-height: 0; padding: 0; border: none; box-shadow: none; }
        windowcontrols.rw-band-controls { margin: 0; }
        windowhandle.rw-titlebar windowcontrols { margin: 0 12px 0 0; }
        .rw-titlebar-title { font-weight: bold; font-size: 13px; padding: 0 12px; }
        window:backdrop .rw-titlebar-title { color: \(p.tertiary); }
        .rw-menu-slot menubar { background: none; box-shadow: none; padding: 0; margin: 0; }
        .rw-menu-slot menubar > item { padding: 2px 8px; margin: 0; border-radius: 5px; min-height: 18px; color: \(p.text); }
        .rw-menu-slot menubar > item:first-child { font-weight: bold; }
        .rw-menu-slot menubar > item:hover, .rw-menu-slot menubar > item:selected { background-color: \(p.quaternary); }
        window:backdrop .rw-menu-slot menubar > item { color: \(p.secondary); }
        .titlebar.rw-titlebar-none, .rw-titlebar-none { min-height: 0; padding: 0; background: none; box-shadow: none; border: none; }

        /* ---- Alerts ---- */
        window.dialog.message .titlebar { min-height: 12px; background: none; box-shadow: none; }
        window.dialog.message box.dialog-vbox { border-spacing: 8px; }
        window.dialog.message label.title { font-weight: bold; font-size: 13px; }
        window.dialog.message .message-area { padding: 8px 20px 4px; border-spacing: 6px; }
        window.dialog.message .message-area label:not(.title) { font-size: 11px; }
        window.dialog.message .dialog-action-area { padding: 12px 16px 16px; border-spacing: 8px; }
        window.dialog.message .dialog-action-area > button { min-height: 22px; border-radius: 5px; }
        """
    }

    /// The minimal stylesheet used with RUNWAY_NATIVE_LOOK: the desktop's
    /// own theme, with Runway's layout helpers only.
    static func nativeCSS(nativeFont: Bool) -> String {
        (nativeFont ? "" : "window { font-size: 13px; }\n") + """
        .rw-tap { background: none; border: none; box-shadow: none; padding: 0; min-height: 0; min-width: 0; outline: none; }
        .titlebar.rw-titlebar-none, .rw-titlebar-none { min-height: 0; padding: 0; background: none; box-shadow: none; border: none; }
        .rw-titlebar-title { font-weight: bold; padding: 0 12px; }
        .rw-container { background: none; }
        button.rw-content { padding: 3px 10px; min-height: 0; }
        button.rw-capsule-button { border-radius: 999px; }
        button.rw-small { padding: 1px 6px; min-height: 18px; font-size: 11px; }
        button.rw-large { padding: 5px 14px; min-height: 26px; }
        .rw-segmented > button { padding: 2px 10px; min-height: 0; }
        entry.rw-plain { border: none; box-shadow: none; background: none; outline: none; }
        dropdown > button { padding: 2px 8px; min-height: 0; }
        progressbar > trough, progressbar > trough > progress { min-height: 5px; }
        scrolledwindow.rw-scroll { background: none; }
        .rw-stepper > button { min-height: 0; min-width: 0; padding: 0 3px; -gtk-icon-size: 10px; border-radius: 0; }
        .rw-stepper > button:first-child { border-radius: 5px 5px 0 0; }
        .rw-stepper > button:last-child { border-radius: 0 0 5px 5px; border-top-width: 0; }
        """
    }
}
#endif
