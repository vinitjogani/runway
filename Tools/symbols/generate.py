#!/usr/bin/env python3
"""Generates Sources/RunwayCore/SymbolArt+Table.swift: SF Symbols names drawn
with Lucide icons (ISC licence, https://lucide.dev), which share the SF
look: rounded strokes on a 24 pt grid.

    npm pack lucide-static@0.460.0 && tar xzf lucide-static-0.460.0.tgz
    python3 -I Tools/symbols/generate.py package/icons

Only the base glyph is stored per name. Variants (".fill", ".circle",
".circle.fill", ".square", ".slash"…) are composed at run time by
SymbolArt, so every SF name built from a mapped base works.
"""
import os, re, sys

# SF base name → Lucide icon. Bases are SF names with variant suffixes
# (.fill .circle .square .slash .badge…) removed; see SymbolArt.resolve.
BASE = {
    # Actions
    "plus": "plus", "minus": "minus", "xmark": "x", "multiply": "x", "checkmark": "check",
    "plusminus": "diff", "info": "info", "questionmark": "help-circle-inner", "exclamationmark": "alert-inner",
    "magnifyingglass": "search", "plus.magnifyingglass": "zoom-in", "minus.magnifyingglass": "zoom-out",
    "exclamationmark.magnifyingglass": "search-x", "exclamationmark.triangle": "triangle-alert",
    "exclamationmark.octagon": "octagon-alert", "xmark.octagon": "octagon-x", "exclamationmark.circle": "circle-alert",
    "trash": "trash-2", "pencil": "pencil", "square.and.pencil": "square-pen", "pencil.and.scribble": "signature",
    "pencil.and.list.clipboard": "clipboard-pen-line", "scissors": "scissors", "link": "link", "pin": "pin",
    "paperplane": "send", "envelope": "mail", "tray": "inbox", "tray.and.arrow.down": "inbox",
    "square.and.arrow.up": "share", "square.and.arrow.down": "download", "square.and.arrow.up.on.square": "share",
    "arrow.up.forward.square": "square-arrow-out-up-right", "arrow.up.right.square": "square-arrow-out-up-right",
    "doc.on.doc": "copy", "document.on.document": "copy", "doc.on.clipboard": "clipboard-copy",
    "square.on.square": "copy", "rectangle.on.rectangle": "copy", "plus.square.dashed": "square-dashed",
    "printer": "printer", "lock": "lock", "lock.open": "lock-open", "lock.shield": "shield-check", "shield.lefthalf.filled": "shield-half",
    "eye": "eye", "eyes": "eye", "eye.slash": "eye-off", "power": "power", "poweroff": "power", "togglepower": "power",
    "wand.and.stars": "wand-sparkles", "sparkles": "sparkles", "hammer": "hammer", "wrench.and.screwdriver": "wrench",
    "bandage": "bandage", "testtube.2": "test-tubes", "dice": "dices", "puzzlepiece.extension": "puzzle",
    "lightswitch.on": "toggle-right", "lightswitch.off": "toggle-left", "switch.2": "toggle-left",
    "slider.horizontal.3": "sliders-horizontal", "slider.vertical.3": "sliders-vertical",
    "line.3.horizontal": "menu", "line.3.horizontal.decrease": "list-filter", "list.bullet": "list",
    "list.bullet.rectangle.portrait": "clipboard-list", "text.alignleft": "align-left", "text.append": "text",
    "text.quote": "quote", "textformat": "type", "bold": "bold", "italic": "italic", "character.cursor.ibeam": "text-cursor",
    "text.bubble": "message-square-text", "captions.bubble": "captions", "exclamationmark.bubble": "message-square-warning",
    "curlybraces": "braces", "ellipsis.curlybraces": "braces", "chevron.left.forwardslash.chevron.right": "code",
    "terminal": "terminal", "command": "command", "return.left": "corner-down-left", "delete.left": "delete",
    "clear": "delete", "keyboard": "keyboard", "s.square": "square", "swift": "code", "applescript": "scroll-text",
    "ellipsis": "ellipsis", "ellipsis.rectangle": "rectangle-ellipsis", "ellipsis.viewfinder": "scan",
    "flowchart": "workflow", "nosign": "ban", "rays": "sun-dim", "move.3d": "move-3d", "hand.raised": "hand",
    "repeat": "repeat", "repeat.1": "repeat-1", "timer": "timer", "hourglass": "hourglass", "clock": "clock",
    "clock.arrow.circlepath": "history", "calendar": "calendar", "bell": "bell", "bell.badge": "bell-dot",
    "star": "star", "heart": "heart", "bookmark": "bookmark", "tag": "tag", "flag": "flag",
    "face.smiling": "smile", "theatermask.and.paintbrush": "drama", "paintpalette": "palette", "memories": "images",
    "lightbulb": "lightbulb", "rosette": "badge", "book.closed": "book",
    "ant": "bug", "bolt": "zap", "moon": "moon", "sun.max": "sun", "globe": "globe", "network": "network",
    "safari": "compass", "house": "house", "gift": "gift", "music.note": "music", "shippingbox": "package",
    "vault": "vault", "newspaper": "newspaper", "apple.logo": "apple", "cpu": "cpu", "memorychip": "memory-stick",
    "gear": "settings", "gearshape": "settings", "gearshape.2": "settings-2",
    # Arrows
    "arrow.up": "arrow-up", "arrow.down": "arrow-down", "arrow.left": "arrow-left", "arrow.right": "arrow-right",
    "arrow.up.right": "arrow-up-right", "arrow.down.right": "arrow-down-right",
    "arrow.left.arrow.right": "arrow-left-right", "arrow.up.arrow.down": "arrow-up-down",
    "arrow.clockwise": "rotate-cw", "arrow.counterclockwise": "rotate-ccw", "arrow.2.squarepath": "repeat-2",
    "arrow.triangle.2.circlepath": "refresh-cw", "arrow.triangle.pull": "git-pull-request",
    "arrow.triangle.branch": "git-branch", "arrow.triangle.merge": "git-merge", "arrow.triangle.swap": "git-compare-arrows",
    "arrowshape.turn.up.left": "reply", "arrowshape.turn.up.right": "forward", "arrowshape.turn.up.left.2": "reply-all",
    "arrow.uturn.backward": "undo-2", "arrow.uturn.left": "undo-2", "arrow.uturn.forward": "redo-2",
    "arrowshape.turn.up.backward": "reply", "arrowtriangle.up": "triangle", "arrowtriangle.down": "triangle-down",
    "arrow.up.left.and.arrow.down.right": "maximize-2", "arrow.up.backward.and.arrow.down.forward": "maximize-2",
    "arrow.down.right.and.arrow.up.left": "minimize-2", "arrow.down.forward.and.arrow.up.backward": "minimize-2",
    "chevron.up": "chevron-up", "chevron.down": "chevron-down", "chevron.left": "chevron-left", "chevron.right": "chevron-right",
    "chevron.backward": "chevron-left", "chevron.forward": "chevron-right", "chevron.compact.right": "chevron-right",
    "chevron.up.chevron.down": "chevrons-up-down",
    # Media
    "play": "play", "pause": "pause", "stop": "square-stop-inner", "record": "record-inner", "backward": "rewind", "forward": "fast-forward",
    "backward.end": "skip-back", "forward.end": "skip-forward", "eject": "arrow-up-from-line", "film": "film", "film.stack": "clapperboard",
    "video": "video", "camera": "camera", "camera.metering.center.weighted": "focus", "photo": "image",
    "photo.on.rectangle": "images", "photo.stack": "images", "photo.badge.exclamationmark": "image-off",
    "mic": "mic", "mic.slash": "mic-off", "speaker": "volume", "speaker.wave.1": "volume-1", "speaker.wave.2": "volume-2",
    "speaker.wave.3": "volume-2", "speaker.slash": "volume-x", "waveform": "audio-waveform", "viewfinder": "scan",
    "text.viewfinder": "scan-text", "crop": "crop", "cursorarrow": "mouse-pointer-2", "magicmouse": "mouse",
    "wave.3.right": "radio", "waveform.path.ecg": "activity",
    # Charts and activity
    "chart.bar": "chart-no-axes-column", "chart.bar.xaxis": "chart-column",
    "chart.line.uptrend.xyaxis": "chart-line-arrow", "point.3.connected.trianglepath.dotted": "chart-network",
    "figure.run": "footprints", "figure.walk": "footprints", "figure.mixed.cardio": "activity",
    "dumbbell": "dumbbell", "leaf": "leaf",
    # Files and storage
    "doc": "file", "document": "file", "doc.text": "file-text", "doc.plaintext": "file-text", "doc.richtext": "file-type",
    "folder": "folder", "folder.badge.plus": "folder-plus", "folder.badge.minus": "folder-minus",
    "folder.badge.gearshape": "folder-cog", "questionmark.folder": "folder-search",
    "externaldrive": "hard-drive", "internaldrive": "hard-drive", "externaldrive.badge.icloud": "hard-drive-upload",
    "externaldrive.badge.questionmark": "hard-drive", "externaldrive.badge.plus": "hard-drive-download",
    "cloud": "cloud", "brain": "brain", "brain.head.profile": "brain-circuit", "checklist": "list-checks",
    "bubble": "message-circle", "bubble.left": "message-circle", "bubble.right": "message-circle",
    "bubble.left.and.bubble.right": "messages-square", "paperclip": "paperclip", "return": "corner-down-left",
    "scope": "crosshair", "at": "at-sign", "1.magnifyingglass": "text-search", "text.magnifyingglass": "text-search",
    "icloud": "cloud", "checkmark.icloud": "cloud-upload", "xmark.icloud": "cloud-off", "icloud.and.arrow.down": "cloud-download",
    "cable.connector": "cable", "cable.connector.slash": "unplug",
    # People
    "person": "user", "person.2": "users", "person.crop": "user-round",
    # Windows and layout
    "sidebar.left": "panel-left", "sidebar.leading": "panel-left", "sidebar.right": "panel-right", "sidebar.trailing": "panel-right",
    "macwindow": "app-window", "macwindow.on.rectangle": "app-window", "appwindow.swipe.rectangle": "app-window",
    "uiwindow.split.2x1": "columns-2", "rectangle.split.2x1": "columns-2", "square.split.2x1": "columns-2",
    "rectangle.split.3x1": "columns-3", "rectangle.grid.1x2": "rows-2", "square.grid.2x2": "layout-grid",
    "square.grid.3x3": "grid-3x3", "circle.grid.3x3": "grip", "square.stack": "layers", "square.stack.3d.down.forward": "layers",
    "rectangle.stack.badge.plus": "layers", "squares.leading.rectangle": "layout-panel-left",
    "rectangle": "rectangle-horizontal", "rectangle.dashed": "square-dashed", "rectangle.inset.filled": "rectangle-horizontal",
    "rectangle.portrait.inset.filled": "rectangle-vertical", "square.bottomthird.inset.filled": "panel-bottom",
    "square.leadingthird.inset.filled": "panel-left", "square.trailingthird.inset.filled": "panel-right",
    "menubar.dock.rectangle": "app-window", "filemenu.and.cursorarrow": "mouse-pointer-click",
    "filemenu.and.selection": "menu", "iphone.app.switcher": "smartphone", "app": "square", "appclip": "square-dashed",
    "app.dashed": "square-dashed", "questionmark.app": "square", "display": "monitor", "display.2": "monitor-smartphone",
    "desktopcomputer": "monitor", "laptopcomputer": "laptop", "applepencil.gen1": "pencil-line",
    # Shapes (".fill" fills them)
    "eyeglasses": "glasses", "inset.filled.bottomtrailing.rectangle": "picture-in-picture-2", "key": "key-round",
    "key.slash": "key-round", "number": "hash", "speedometer": "gauge", "tablecells": "table", "text.magnifyingglass": "text-search",
    "wifi": "wifi", "wifi.slash": "wifi-off", "lock.slash": "lock-open", "bell.slash": "bell-off", "pin.slash": "pin-off", "tag.slash": "tag",
    "network.slash": "network", "speaker.slash": "volume-x", "eye.slash": "eye-off",
    "circle": "circle", "largecircle.fill.circle": "circle-dot", "square": "square", "triangle": "triangle",
}

# Glyphs drawn inside a circle or square by the ".circle" / ".square" variants
# come from the bare icon; these Lucide-only helpers exist to give SF names
# without an outline of their own something sensible.
HELPERS = {"help-circle-inner": ("circle-help", "inner"), "alert-inner": ("circle-alert", "inner"),
           "square-stop-inner": ("square", "fill"), "record-inner": ("circle", "fill"),
           "triangle-down": ("triangle", "rotate"), "chart-line-arrow": ("chart-line", "arrowhead")}

def body(svg):
    m = re.search(r'<svg[^>]*>\s*(.*)</svg>', svg, re.S)
    inner = m.group(1)
    inner = re.sub(r'\s+', ' ', inner).replace('" />', '"/>').strip()
    return inner

def main(icons):
    out = {}
    missing = []
    for sf, lu in sorted(BASE.items()):
        if lu in HELPERS:
            src, mode = HELPERS[lu]
            b = body(open(os.path.join(icons, src + '.svg')).read())
            if mode == "inner":  # drop the outer circle: just the glyph
                b = re.sub(r'<circle cx="12" cy="12" r="10"\s*/>\s*', '', b)
            elif mode == "rotate":
                b = f'<g transform="rotate(180 12 12)">{b}</g>'
            elif mode == "arrowhead":
                b += ' <path d="M14.5 9H19v4.5"/>'
            else:
                b = b.replace('<rect', '<rect data-fill="1"').replace('<circle', '<circle data-fill="1"')
                b = re.sub(r'r="10"', 'r="7"', b) if src == "circle" else b
            out[sf] = b
            continue
        p = os.path.join(icons, lu + '.svg')
        if not os.path.exists(p):
            missing.append((sf, lu)); continue
        out[sf] = body(open(p).read())
    if missing:
        sys.exit('missing Lucide icons: %r' % missing)
    here = os.path.dirname(os.path.abspath(__file__))
    dst = os.path.join(here, '..', '..', 'Sources', 'RunwayCore', 'SymbolArt+Table.swift')
    with open(dst, 'w') as f:
        f.write('// Generated by Tools/symbols/generate.py from Lucide 0.460.0 (ISC licence,\n')
        f.write('// Copyright (c) Lucide Contributors; portions Cole Bemis / Feather, MIT).\n')
        f.write('// Do not edit: SF Symbols base names → SVG bodies on a 24-unit grid.\n\n')
        f.write('extension SymbolArt {\n    static let table: [String: String] = [\n')
        for k, v in sorted(out.items()):
            f.write('        "%s": #"%s"#,\n' % (k, v))
        f.write('    ]\n}\n')
    print('wrote %d symbols to %s' % (len(out), os.path.normpath(dst)))

main(sys.argv[1])
