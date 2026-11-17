// SF Symbols names → glyphs of Segoe Fluent Icons (Windows 11) or Segoe
// MDL2 Assets (Windows 10), which share these code points.

#if os(Windows)
import Foundation
import RunwayCore

enum Symbols {
    static let map: [String: UInt32] = [
        // Editing and actions.
        "plus": 0xE710, "minus": 0xE738, "xmark": 0xE711, "checkmark": 0xE73E,
        "xmark.circle.fill": 0xEB90, "xmark.circle": 0xEA39, "checkmark.circle.fill": 0xEC61, "checkmark.circle": 0xE930,
        "plus.circle": 0xECC8, "plus.circle.fill": 0xECC8, "minus.circle": 0xECC9, "minus.circle.fill": 0xECC9,
        "trash": 0xE74D, "trash.fill": 0xE74D, "pencil": 0xE70F, "square.and.pencil": 0xE70F, "scissors": 0xE8C6,
        "doc.on.doc": 0xE8C8, "doc.on.clipboard": 0xE77F, "clipboard": 0xE77F,
        "arrow.uturn.backward": 0xE7A7, "arrow.uturn.forward": 0xE7A6,
        "arrow.clockwise": 0xE72C, "arrow.counterclockwise": 0xE72C, "arrow.triangle.2.circlepath": 0xE895,
        "square.and.arrow.up": 0xE72D, "square.and.arrow.down": 0xE74E, "square.and.arrow.up.on.square": 0xE72D,
        "arrow.down.circle": 0xE896, "arrow.down.to.line": 0xE896, "arrow.up.to.line": 0xE898, "icloud.and.arrow.up": 0xE898,
        "magnifyingglass": 0xE721, "plus.magnifyingglass": 0xE8A3, "minus.magnifyingglass": 0xE71F,
        "line.3.horizontal.decrease": 0xE71C, "line.3.horizontal.decrease.circle": 0xE71C, "arrow.up.arrow.down": 0xE8CB,
        "paperclip": 0xE723, "link": 0xE71B, "pin": 0xE718, "pin.fill": 0xE718, "flag": 0xE7C1, "flag.fill": 0xE7C1,
        "tag": 0xE8EC, "tag.fill": 0xE8EC, "bookmark": 0xE8A4, "bookmark.fill": 0xE8A4,
        "crop": 0xE7A8, "rectangle.dashed": 0xE8B3, "selection.pin.in.out": 0xE8B3,
        "bold": 0xE8DD, "italic": 0xE8DB, "underline": 0xE8DC, "textformat": 0xE8D2, "textformat.size": 0xE8E9,
        "text.alignleft": 0xE8E4, "text.aligncenter": 0xE8E3, "text.alignright": 0xE8E2,
        // Navigation.
        "chevron.left": 0xE76B, "chevron.right": 0xE76C, "chevron.up": 0xE70E, "chevron.down": 0xE70D,
        "chevron.up.chevron.down": 0xEC8F, "arrow.left": 0xE72B, "arrow.right": 0xE72A, "arrow.up": 0xE74A, "arrow.down": 0xE74B,
        "house": 0xE80F, "house.fill": 0xE80F, "sidebar.left": 0xE90C, "sidebar.right": 0xE90D,
        "line.3.horizontal": 0xE700, "ellipsis": 0xE712, "ellipsis.circle": 0xE712, "list.bullet": 0xE8FD,
        "square.grid.2x2": 0xF0E2, "square.grid.3x3": 0xF0E2, "rectangle.grid.2x2": 0xF0E2,
        "arrow.up.left.and.arrow.down.right": 0xE740, "arrow.down.right.and.arrow.up.left": 0xE73F,
        // Media.
        "play": 0xE768, "play.fill": 0xE768, "pause": 0xE769, "pause.fill": 0xE769, "stop": 0xE71A, "stop.fill": 0xE71A,
        "play.circle": 0xE768, "play.circle.fill": 0xE768, "record.circle": 0xE7C8, "record.circle.fill": 0xE7C8,
        "backward.fill": 0xEB9E, "forward.fill": 0xEB9D, "backward.end.fill": 0xE892, "forward.end.fill": 0xE893,
        "shuffle": 0xE8B1, "repeat": 0xE8EE,
        "speaker.wave.2": 0xE767, "speaker.wave.2.fill": 0xE767, "speaker.wave.3": 0xE767, "speaker.wave.3.fill": 0xE767,
        "speaker.slash": 0xE74F, "speaker.slash.fill": 0xE74F, "speaker": 0xE767, "speaker.fill": 0xE767,
        "mic": 0xE720, "mic.fill": 0xE720, "mic.slash": 0xEC54, "mic.slash.fill": 0xEC54,
        "video": 0xE714, "video.fill": 0xE714, "camera": 0xE722, "camera.fill": 0xE722,
        "photo": 0xEB9F, "photo.fill": 0xEB9F, "photo.on.rectangle": 0xE8B9, "film": 0xE8B2, "music.note": 0xEC4F,
        "waveform": 0xE8D6, "headphones": 0xE7F6, "slider.horizontal.3": 0xE9E9, "captions.bubble": 0xE7F0,
        // Devices and windows.
        "display": 0xE7F4, "desktopcomputer": 0xE977, "laptopcomputer": 0xE7F8, "iphone": 0xE8EA, "keyboard": 0xE765,
        "cursorarrow": 0xE962, "printer": 0xE749, "macwindow": 0xE737, "rectangle.on.rectangle": 0xE737,
        "square.stack": 0xE8F1, "rectangle.split.3x1": 0xE8A9, "wifi": 0xE701, "network": 0xE968, "globe": 0xE774,
        "bolt": 0xE945, "bolt.fill": 0xE945, "power": 0xE7E8, "battery.100": 0xE83F,
        // Status.
        "info.circle": 0xE946, "info.circle.fill": 0xE946, "questionmark.circle": 0xE897, "questionmark.circle.fill": 0xE897,
        "exclamationmark.triangle": 0xE7BA, "exclamationmark.triangle.fill": 0xE7BA,
        "exclamationmark.circle": 0xEA39, "exclamationmark.circle.fill": 0xEA39,
        "star": 0xE734, "star.fill": 0xE735, "heart": 0xEB51, "heart.fill": 0xEB52, "bell": 0xEA8F, "bell.fill": 0xEA8F,
        "lock": 0xE72E, "lock.fill": 0xE72E, "lock.open": 0xE785, "lock.open.fill": 0xE785, "shield": 0xEA18,
        "eye": 0xE890, "eye.slash": 0xED1A, "lightbulb": 0xEA80, "moon": 0xE708, "moon.fill": 0xE708, "sun.max": 0xE706,
        "sun.max.fill": 0xE706, "circle": 0xEA3A, "circle.fill": 0xEA3B, "square": 0xE739, "checkmark.square": 0xE73A,
        "checkmark.square.fill": 0xE73A, "sparkles": 0xE945, "wand.and.stars": 0xE945,
        // Files and people.
        "folder": 0xE8B7, "folder.fill": 0xE8B7, "doc": 0xE8A5, "doc.fill": 0xE8A5, "doc.text": 0xE8A5, "doc.text.fill": 0xE8A5,
        "folder.badge.plus": 0xE8F4, "externaldrive": 0xEDA2, "archivebox": 0xE7B8, "tray": 0xE7B8, "book": 0xE82D,
        "person": 0xE77B, "person.fill": 0xE77B, "person.crop.circle": 0xE77B, "person.crop.circle.fill": 0xE77B,
        "person.2": 0xE716, "person.2.fill": 0xE716, "envelope": 0xE715, "envelope.fill": 0xE715, "paperplane": 0xE724,
        "paperplane.fill": 0xE724, "bubble.left": 0xE8BD, "bubble.left.fill": 0xE8BD, "text.bubble": 0xE8BD,
        "bubble.left.and.bubble.right": 0xE8F2, "phone": 0xE717, "phone.fill": 0xE717,
        "calendar": 0xE787, "clock": 0xE823, "clock.fill": 0xE823, "timer": 0xE916, "stopwatch": 0xE916, "alarm": 0xE7ED,
        "gear": 0xE713, "gearshape": 0xE713, "gearshape.fill": 0xE713, "gearshape.2": 0xE713, "wrench": 0xE90F,
        "hammer": 0xE90F, "location": 0xE81D, "location.fill": 0xE81D, "map": 0xE707, "mappin": 0xE707,
        "cart": 0xE7BF, "bag": 0xE719, "creditcard": 0xE8C7, "gift": 0xE88C, "chart.bar": 0xE9D2, "chart.bar.fill": 0xE9D2,
        "chevron.left.forwardslash.chevron.right": 0xE943, "terminal": 0xE756, "ant": 0xEBE8, "ladybug": 0xEBE8,
        "cloud": 0xE753, "cloud.fill": 0xE753, "icloud": 0xE753, "paintbrush": 0xE771, "paintpalette": 0xE790,
    ]

    static func codepoint(_ name: String) -> UInt32? {
        if let c = map[name] { return c }
        // Fall back from variants (".fill", ".circle"…) to the base symbol.
        var parts = name.split(separator: ".")
        while parts.count > 1 {
            parts.removeLast()
            if let c = map[parts.joined(separator: ".")] { return c }
        }
        return nil
    }

    /// Lays out a symbol's glyph in `box`.
    static func set(_ box: TextBox, _ name: String, size: CGFloat, alignment: TextAlignmentValue = .leading) {
        guard let c = codepoint(name), let u = UnicodeScalar(c) else {
            box.set(StyledText(runs: []))
            return
        }
        box.set(StyledText(runs: [TextRun(string: String(Character(u)), font: FontSpec(size: size, family: Fonts.icon), color: nil)],
                           alignment: alignment, lineLimit: 1))
    }
}
#endif
