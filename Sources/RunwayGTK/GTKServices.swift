// Desktop services on Linux: GDK clipboard, GIO for opening URIs, the
// freedesktop FileManager1 D-Bus interface for revealing files, the
// freedesktop sound theme, GtkFileDialog and GtkAlertDialog.

#if os(Linux)
import Foundation
import CGtk
import CRunwayGtk
import RunwayCore

@MainActor final class GTKServices: PlatformServices {
    unowned let backend: GTKBackend
    init(backend: GTKBackend) { self.backend = backend }

    private var parent: UnsafeMutablePointer<GtkWindow>? { backend.activeWindow.map { typed($0) } }

    func copyToClipboard(string: String) { runway_clipboard_set_text(string) }

    func copyToClipboard(fileURLs: [URL]) {
        let uris = fileURLs.map(\.absoluteString).joined(separator: "\r\n")
        runway_clipboard_set_uris(uris, fileURLs.map(\.path).joined(separator: "\n"))
    }

    func clipboardString() -> String? {
        guard let c = runway_clipboard_get_text() else { return nil }
        defer { g_free(c) }
        return String(cString: c)
    }

    func open(_ url: URL) -> Bool { runway_open_uri(url.absoluteString) != 0 }

    func reveal(_ urls: [URL]) {
        let dup = urls.map { strdup($0.absoluteString) }
        defer { dup.forEach { free($0) } }
        var ptrs: [UnsafePointer<CChar>?] = dup.map { UnsafePointer($0) }
        ptrs.append(nil)
        ptrs.withUnsafeBufferPointer { runway_reveal_uris($0.baseAddress) }
    }

    /// macOS sound names → the freedesktop sound theme.
    static let sounds: [String: String] = [
        "Glass": "complete", "Hero": "complete", "Ping": "message", "Pop": "message", "Tink": "message",
        "Purr": "message-new-instant", "Submarine": "message-new-instant", "Blow": "bell", "Bottle": "bell",
        "Frog": "bell", "Funk": "dialog-warning", "Morse": "bell", "Sosumi": "dialog-warning", "Basso": "dialog-error",
    ]

    func playSound(named name: String) -> Bool {
        let id = Self.sounds[name] ?? name.lowercased()
        let dirs = ["/usr/share/sounds/freedesktop/stereo", "/usr/share/sounds/Yaru/stereo", "/usr/share/sounds/gnome/default/alerts"]
        for dir in dirs {
            for ext in ["oga", "ogg", "wav"] {
                let path = "\(dir)/\(id).\(ext)"
                guard FileManager.default.fileExists(atPath: path) else { continue }
                for player in ["/usr/bin/pw-play", "/usr/bin/paplay", "/usr/bin/canberra-gtk-play"] where FileManager.default.isExecutableFile(atPath: player) {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: player)
                    p.arguments = player.hasSuffix("canberra-gtk-play") ? ["-f", path] : [path]
                    if (try? p.run()) != nil { return true }
                }
            }
        }
        beep()
        return false
    }

    func beep() { runway_beep() }

    func chooseFiles(title: String, allowsMultiple: Bool, canChooseDirectories: Bool, extensions: [String]) -> [URL]? {
        let dup = extensions.map { strdup($0) }
        defer { dup.forEach { free($0) } }
        var ptrs: [UnsafePointer<CChar>?] = dup.map { UnsafePointer($0) }
        ptrs.append(nil)
        let result = ptrs.withUnsafeBufferPointer { runway_choose_files(parent, title, allowsMultiple ? 1 : 0, canChooseDirectories ? 1 : 0, $0.baseAddress) }
        guard let result else { return nil }
        defer { g_free(result) }
        return String(cString: result).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    func chooseSaveLocation(title: String, suggestedName: String) -> URL? {
        guard let result = runway_choose_save(parent, title, suggestedName) else { return nil }
        defer { g_free(result) }
        return URL(fileURLWithPath: String(cString: result))
    }

    func chooseApplication(title: String, mimeType: String?) -> String? {
        guard let result = runway_choose_application(parent, title, mimeType) else { return nil }
        defer { g_free(result) }
        return String(cString: result)
    }

    func alert(title: String, message: String, buttons: [String], destructive: Int?) -> Int {
        let dup = buttons.map { strdup($0) }
        defer { dup.forEach { free($0) } }
        var ptrs: [UnsafePointer<CChar>?] = dup.map { UnsafePointer($0) }
        ptrs.append(nil)
        // AppKit puts the default button first; GTK lists buttons left to
        // right with the default last, so reverse and map back.
        let cancel = buttons.firstIndex { $0 == "Cancel" } ?? (buttons.count > 1 ? buttons.count - 1 : 0)
        let i = ptrs.withUnsafeBufferPointer { runway_alert(parent, title, message, $0.baseAddress, Int32(cancel), 0) }
        return Int(i)
    }
}

/// SF Symbols names → freedesktop icon names (the Adwaita / GNOME theme).
enum SymbolMap {
    static let map: [String: String] = [
        "plus": "list-add-symbolic", "minus": "list-remove-symbolic", "xmark": "window-close-symbolic",
        "xmark.circle.fill": "window-close-symbolic", "xmark.circle": "window-close-symbolic",
        "checkmark": "object-select-symbolic", "checkmark.circle.fill": "emblem-ok-symbolic", "checkmark.circle": "emblem-ok-symbolic",
        "gear": "emblem-system-symbolic", "gearshape": "emblem-system-symbolic", "gearshape.fill": "emblem-system-symbolic",
        "magnifyingglass": "system-search-symbolic", "trash": "user-trash-symbolic", "trash.fill": "user-trash-symbolic",
        "folder": "folder-symbolic", "folder.fill": "folder-symbolic", "doc": "text-x-generic-symbolic", "doc.text": "text-x-generic-symbolic",
        "doc.on.doc": "edit-copy-symbolic", "square.and.arrow.up": "document-send-symbolic", "square.and.arrow.down": "document-save-symbolic",
        "square.and.pencil": "document-edit-symbolic", "pencil": "document-edit-symbolic", "scissors": "edit-cut-symbolic",
        "arrow.uturn.backward": "edit-undo-symbolic", "arrow.uturn.forward": "edit-redo-symbolic",
        "arrow.clockwise": "view-refresh-symbolic", "arrow.counterclockwise": "view-refresh-symbolic",
        "chevron.left": "go-previous-symbolic", "chevron.right": "go-next-symbolic", "chevron.up": "go-up-symbolic", "chevron.down": "go-down-symbolic",
        "arrow.left": "go-previous-symbolic", "arrow.right": "go-next-symbolic", "arrow.up": "go-up-symbolic", "arrow.down": "go-down-symbolic",
        "play": "media-playback-start-symbolic", "play.fill": "media-playback-start-symbolic", "pause": "media-playback-pause-symbolic",
        "pause.fill": "media-playback-pause-symbolic", "stop": "media-playback-stop-symbolic", "stop.fill": "media-playback-stop-symbolic",
        "record.circle": "media-record-symbolic", "record.circle.fill": "media-record-symbolic", "backward.fill": "media-seek-backward-symbolic",
        "forward.fill": "media-seek-forward-symbolic", "backward.end.fill": "media-skip-backward-symbolic", "forward.end.fill": "media-skip-forward-symbolic",
        "speaker.wave.2": "audio-volume-high-symbolic", "speaker.wave.2.fill": "audio-volume-high-symbolic", "speaker.slash": "audio-volume-muted-symbolic",
        "speaker.slash.fill": "audio-volume-muted-symbolic", "mic": "audio-input-microphone-symbolic", "mic.fill": "audio-input-microphone-symbolic",
        "mic.slash": "microphone-disabled-symbolic", "video": "camera-video-symbolic", "video.fill": "camera-video-symbolic",
        "camera": "camera-photo-symbolic", "camera.fill": "camera-photo-symbolic", "photo": "image-x-generic-symbolic", "photo.fill": "image-x-generic-symbolic",
        "film": "video-x-generic-symbolic", "music.note": "audio-x-generic-symbolic", "waveform": "audio-x-generic-symbolic",
        "display": "video-display-symbolic", "desktopcomputer": "computer-symbolic", "macwindow": "focus-windows-symbolic",
        "rectangle.on.rectangle": "focus-windows-symbolic", "info.circle": "dialog-information-symbolic", "info.circle.fill": "dialog-information-symbolic",
        "exclamationmark.triangle": "dialog-warning-symbolic", "exclamationmark.triangle.fill": "dialog-warning-symbolic",
        "exclamationmark.circle": "dialog-error-symbolic", "exclamationmark.circle.fill": "dialog-error-symbolic",
        "questionmark.circle": "help-about-symbolic", "star": "non-starred-symbolic", "star.fill": "starred-symbolic",
        "heart": "emblem-favorite-symbolic", "heart.fill": "emblem-favorite-symbolic", "bell": "preferences-system-notifications-symbolic",
        "lock": "changes-prevent-symbolic", "lock.fill": "changes-prevent-symbolic", "lock.open": "changes-allow-symbolic",
        "link": "insert-link-symbolic", "globe": "web-browser-symbolic", "network": "network-workgroup-symbolic",
        "person": "avatar-default-symbolic", "person.fill": "avatar-default-symbolic", "person.crop.circle": "avatar-default-symbolic",
        "person.2": "system-users-symbolic", "envelope": "mail-unread-symbolic", "paperplane": "mail-send-symbolic",
        "calendar": "x-office-calendar-symbolic", "clock": "document-open-recent-symbolic", "tag": "bookmark-new-symbolic",
        "bookmark": "user-bookmarks-symbolic", "list.bullet": "view-list-symbolic", "square.grid.2x2": "view-grid-symbolic",
        "sidebar.left": "sidebar-show-symbolic", "line.3.horizontal": "open-menu-symbolic", "ellipsis": "view-more-symbolic",
        "ellipsis.circle": "view-more-symbolic", "slider.horizontal.3": "preferences-other-symbolic", "wand.and.stars": "starred-symbolic",
        "sparkles": "starred-symbolic", "text.bubble": "user-available-symbolic", "captions.bubble": "media-view-subtitles-symbolic",
        "square.and.arrow.up.on.square": "document-send-symbolic", "arrow.down.circle": "folder-download-symbolic",
        "plus.circle": "list-add-symbolic", "plus.circle.fill": "list-add-symbolic", "minus.circle": "list-remove-symbolic",
        "plus.magnifyingglass": "zoom-in-symbolic", "minus.magnifyingglass": "zoom-out-symbolic",
        "arrow.up.left.and.arrow.down.right": "view-fullscreen-symbolic", "arrow.down.right.and.arrow.up.left": "view-restore-symbolic",
        "crop": "edit-select-all-symbolic", "rectangle.dashed": "edit-select-all-symbolic", "cursorarrow": "input-mouse-symbolic",
        "keyboard": "input-keyboard-symbolic", "printer": "printer-symbolic", "house": "go-home-symbolic", "eye": "view-reveal-symbolic",
        "eye.slash": "view-conceal-symbolic", "square.stack": "view-dual-symbolic", "rectangle.split.3x1": "view-dual-symbolic",
    ]

    static func iconName(for symbol: String) -> String {
        if let m = map[symbol] { return m }
        // Try the base name without variants (".fill", ".circle"…).
        var parts = symbol.split(separator: ".")
        while parts.count > 1 {
            parts.removeLast()
            if let m = map[parts.joined(separator: ".")] { return m }
        }
        return "image-missing-symbolic"
    }
}
#endif
