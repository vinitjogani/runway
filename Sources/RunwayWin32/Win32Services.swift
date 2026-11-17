// Desktop services on Windows: the clipboard (text and CF_HDROP files),
// ShellExecute, Explorer's SHOpenFolderAndSelectItems, system sounds via
// PlaySound, the Common Item Dialogs, and alerts drawn like the Mac's.

#if os(Windows)
import Foundation
import RunwayCore
import CRunwayWin32

@MainActor final class Win32Services: PlatformServices {
    unowned let backend: Win32Backend
    init(backend: Win32Backend) { self.backend = backend }

    private var owner: OpaquePointer? { backend.activeWindow?.native }

    func copyToClipboard(string: String) { rw_clipboard_set_text(string) }

    func copyToClipboard(fileURLs: [URL]) {
        withCStrings(fileURLs.map(Self.path)) { rw_clipboard_set_files($0, $1) }
    }

    func clipboardString() -> String? {
        guard let c = rw_clipboard_get_text() else { return nil }
        defer { rw_free(c) }
        return String(cString: c)
    }

    func open(_ url: URL) -> Bool {
        rw_shell_open(url.isFileURL ? Self.path(url) : url.absoluteString) != 0
    }

    func reveal(_ urls: [URL]) {
        withCStrings(urls.map(Self.path)) { rw_reveal($0, $1) }
    }

    /// macOS sound names → Windows sound events.
    static let sounds: [String: String] = [
        "Glass": "SystemAsterisk", "Hero": "SystemAsterisk", "Ping": "Notification.Default", "Pop": "Notification.Default",
        "Tink": "Notification.Default", "Purr": "Notification.IM", "Submarine": "Notification.Reminder", "Blow": ".Default",
        "Bottle": ".Default", "Frog": ".Default", "Morse": ".Default", "Funk": "SystemExclamation", "Sosumi": "SystemExclamation",
        "Basso": "SystemHand",
    ]

    func playSound(named name: String) -> Bool {
        if rw_play_sound(Self.sounds[name] ?? name) != 0 { return true }
        beep()
        return false
    }

    func beep() { rw_beep() }

    func chooseFiles(title: String, allowsMultiple: Bool, canChooseDirectories: Bool, extensions: [String]) -> [URL]? {
        let result = withCStrings(extensions) { rw_choose_files(owner, title, allowsMultiple ? 1 : 0, canChooseDirectories ? 1 : 0, $0, $1) }
        guard let result else { return nil }
        defer { rw_free(result) }
        return String(cString: result).split(separator: "\n").map { URL(fileURLWithPath: String($0), isDirectory: canChooseDirectories) }
    }

    func chooseSaveLocation(title: String, suggestedName: String) -> URL? {
        guard let result = rw_choose_save(owner, title, suggestedName) else { return nil }
        defer { rw_free(result) }
        return URL(fileURLWithPath: String(cString: result))
    }

    // MARK: Alerts

    /// A modal alert in the Mac's style (centred bold title, message, and
    /// buttons side by side or stacked), drawn by this backend so it follows
    /// light and dark mode like every other window.
    func alert(title: String, message: String, buttons: [String], destructive: Int?) -> Int {
        let titles = buttons.isEmpty ? ["OK"] : buttons
        let cancel = titles.firstIndex(of: "Cancel") ?? (titles.count > 1 ? titles.count - 1 : 0)
        let width: CGFloat = 272, margin: CGFloat = 20, inner = width - 2 * margin

        func label(_ s: String, size: CGFloat, weight: FontWeightValue) -> (W32Widget, CGSize) {
            let w = backend.makeWidget(.text) as! W32Widget
            var p = WidgetProps()
            p.text = StyledText(runs: [TextRun(string: s, font: FontSpec(size: size, weight: weight), color: nil)], alignment: .center)
            backend.update(w, props: p, events: WidgetEvents())
            return (w, backend.measure(w, proposal: ProposedSize(width: inner, height: nil)))
        }
        let (titleWidget, titleSize) = label(title, size: 13, weight: .bold)
        let (messageWidget, messageSize) = message.isEmpty ? (nil, CGSize.zero) : { let l = label(message, size: 11, weight: .regular); return (Optional(l.0), l.1) }()

        let done = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        done.pointee = 0
        defer { done.deallocate() }
        var answer = cancel

        var y = margin + 4
        var placed: [(NativeWidget, CGRect)] = [(titleWidget, CGRect(x: margin, y: y, width: inner, height: titleSize.height))]
        y += titleSize.height
        if let m = messageWidget {
            y += 6
            placed.append((m, CGRect(x: margin, y: y, width: inner, height: messageSize.height)))
            y += messageSize.height
        }
        y += 18
        let sideBySide = titles.count <= 2
        let buttonHeight: CGFloat = 24, gap: CGFloat = 8
        for (i, t) in titles.enumerated() {
            let b = backend.makeWidget(.button) as! W32Widget
            var p = WidgetProps()
            p.title = t
            p.isDefault = i == 0
            p.prominent = i == 0
            p.isCancel = i == cancel
            p.isDestructive = destructive == i
            p.controlSize = .large
            var e = WidgetEvents()
            e.onTap = { answer = i; done.pointee = 1 }
            backend.update(b, props: p, events: e)
            let frame: CGRect
            if sideBySide {
                // Default button on the right, as on the Mac.
                let bw = titles.count == 1 ? inner : (inner - gap) / 2
                let slot = titles.count == 1 ? 0 : 1 - i
                frame = CGRect(x: margin + CGFloat(slot) * (bw + gap), y: y, width: bw, height: buttonHeight)
            } else {
                frame = CGRect(x: margin, y: y + CGFloat(i) * (buttonHeight + gap), width: inner, height: buttonHeight)
            }
            placed.append((b, frame))
        }
        y += sideBySide ? buttonHeight : CGFloat(titles.count) * (buttonHeight + gap) - gap
        let size = CGSize(width: width, height: (y + margin).rounded(.up))

        let window = backend.makeWindow(WindowOptions(title: "", size: size, resizable: false, modal: true), parent: backend.activeWindow)
        let container = backend.makeWidget(.container)
        backend.setChildren(container, placed, contentSize: size)
        backend.setChildren(window.content, [(container, CGRect(origin: .zero, size: size))], contentSize: size)
        window.onKey = { key in
            guard !key.command else { return false }
            if key.key == "return" { answer = 0; done.pointee = 1; return true }
            if key.key == "escape" { answer = cancel; done.pointee = 1; return true }
            return false
        }
        window.onCloseRequest = { answer = cancel; done.pointee = 1; return false }
        window.show()
        if (window as? W32Window)?.native == nil {
            // No window (out of resources): fall back to a system message box.
            return Int(rw_message_box(owner, title, message, titles.count > 1 ? 1 : 0))
        }
        rw_run_modal(done)
        window.close()
        return answer
    }

    // MARK: Helpers

    /// A file URL as a native path ("C:\Users\…").
    static func path(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
    }

    private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>?, Int32) -> R) -> R {
        let dup = strings.map { strdup($0) }
        defer { dup.forEach { free($0) } }
        let ptrs: [UnsafePointer<CChar>?] = dup.map { $0.map { UnsafePointer($0) } }
        return ptrs.withUnsafeBufferPointer { body($0.baseAddress, Int32(strings.count)) }
    }
}
#endif
