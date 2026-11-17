// UNUserNotificationCenter. On Linux notifications go to the desktop's
// notification server (org.freedesktop.Notifications over D-Bus: GNOME
// Shell, KDE Plasma, dunst, mako…); authorization is granted when such a
// server is running, and denied otherwise, so apps take their existing
// "notifications are off" path. Actions become notification buttons, a
// click is the default action, dismissal is the dismiss action (for
// categories with .customDismissAction); the delegate hears all three as
// UNNotificationResponses on the main queue. Triggers are scheduled in
// process (a dispatch timer each; pending requests don't survive a quit).
// On Windows there's no server Runway can reach without WinRT, so
// authorization is denied.

import Foundation
import RunwayDBus

public protocol UNUserNotificationCenterDelegate: NSObjectProtocol {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void)
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void)
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async
    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?)
}

/// Markers: which delegate methods the app didn't implement.
private let _defaultMarker = UNNotificationPresentationOptions(rawValue: 1 << 63)

extension UNUserNotificationCenterDelegate {
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        nonisolated(unsafe) let handler = completionHandler
        Task { handler(await self.userNotificationCenter(center, willPresent: notification)) }
    }
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Neither form implemented: Apple's default is to present nothing
        // while the app is frontmost; Runway can't tell, so it presents.
        _defaultMarker
    }
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        nonisolated(unsafe) let handler = completionHandler
        Task { await self.userNotificationCenter(center, didReceive: response); handler() }
    }
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {}
    public func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {}
}

open class UNUserNotificationCenter: NSObject, @unchecked Sendable {
    private static let shared = UNUserNotificationCenter()
    open class func current() -> UNUserNotificationCenter { shared }

    open weak var delegate: UNUserNotificationCenterDelegate?
    open var supportsContentExtensions: Bool { false }

    let lock = NSLock()
    var categories: Set<UNNotificationCategory> = []
    var pending: [String: (UNNotificationRequest, DispatchSourceTimer)] = [:]
    var delivered: [String: (UNNotification, UInt32)] = [:]
    var requestedOptions: UNAuthorizationOptions?
    let timers = DispatchQueue(label: "runway.usernotifications")
    let backend = NotificationBackend()

    private override init() {
        super.init()
        if let raw = UserDefaults.standard.object(forKey: "RunwayUNAuthorizationOptions") as? Int {
            requestedOptions = UNAuthorizationOptions(rawValue: UInt(raw))
        }
        backend.onAction = { [weak self] id, key, text in self?.respond(serverID: id, actionKey: key, text: text) }
        backend.onClosed = { [weak self] id, dismissed in self?.closed(serverID: id, dismissed: dismissed) }
    }

    var status: UNAuthorizationStatus {
        guard let opts = requestedOptions else { return .notDetermined }
        if !backend.available { return .denied }
        return opts.contains(.provisional) ? .provisional : .authorized
    }

    // MARK: Authorization and settings

    open func requestAuthorization(options: UNAuthorizationOptions = [], completionHandler: @escaping @Sendable (Bool, Error?) -> Void) {
        lock.lock()
        requestedOptions = (requestedOptions ?? []).union(options)
        let raw = Int(requestedOptions!.rawValue)
        lock.unlock()
        UserDefaults.standard.set(raw, forKey: "RunwayUNAuthorizationOptions")
        let granted = backend.available
        DispatchQueue.main.async { completionHandler(granted, nil) }
    }

    open func requestAuthorization(options: UNAuthorizationOptions = []) async throws -> Bool {
        await withCheckedContinuation { k in requestAuthorization(options: options) { ok, _ in k.resume(returning: ok) } }
    }

    open func getNotificationSettings(completionHandler: @escaping @Sendable (UNNotificationSettings) -> Void) {
        let s = currentSettings()
        DispatchQueue.main.async { completionHandler(s) }
    }

    open func notificationSettings() async -> UNNotificationSettings { currentSettings() }

    func currentSettings() -> UNNotificationSettings {
        lock.lock(); let opts = requestedOptions; lock.unlock()
        return UNNotificationSettings(status: status, sound: opts?.contains(.sound) ?? false)
    }

    open func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        lock.lock(); self.categories = categories; lock.unlock()
    }

    open func getNotificationCategories(completionHandler: @escaping @Sendable (Set<UNNotificationCategory>) -> Void) {
        lock.lock(); let c = categories; lock.unlock()
        DispatchQueue.main.async { completionHandler(c) }
    }

    open func notificationCategories() async -> Set<UNNotificationCategory> { lock.lock(); defer { lock.unlock() }; return categories }

    open func setBadgeCount(_ newBadgeCount: Int, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)? = nil) {
        backend.setBadge(newBadgeCount)
        if let completionHandler { DispatchQueue.main.async { completionHandler(nil) } }
    }

    open func setBadgeCount(_ newBadgeCount: Int) async throws { backend.setBadge(newBadgeCount) }

    // MARK: Requests

    open func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)? = nil) {
        let error = schedule(request)
        if let completionHandler { DispatchQueue.main.async { completionHandler(error) } }
    }

    open func add(_ request: UNNotificationRequest) async throws {
        if let e = schedule(request) { throw e }
    }

    private func schedule(_ request: UNNotificationRequest) -> Error? {
        guard status == .authorized || status == .provisional else { return UNError(.notificationsNotAllowed) }
        let c = request.content
        guard !(c.title.isEmpty && c.subtitle.isEmpty && c.body.isEmpty) || c.sound != nil else { return UNError(.notificationInvalidNoContent) }
        cancelPending(request.identifier)
        guard let trigger = request.trigger, !(trigger is UNPushNotificationTrigger) else {
            deliver(request)
            return nil
        }
        guard let first = trigger.next(after: Date()) else { return UNError(.notificationInvalidNoDate) }
        let timer = DispatchSource.makeTimerSource(queue: timers)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.deliver(request)
            if trigger.repeats, let next = trigger.next(after: Date().addingTimeInterval(0.5)) {
                timer.schedule(wallDeadline: .now() + Swift.max(0, next.timeIntervalSinceNow))
            } else {
                timer.cancel()
                self.lock.lock(); self.pending[request.identifier] = nil; self.lock.unlock()
            }
        }
        timer.schedule(wallDeadline: .now() + Swift.max(0, first.timeIntervalSinceNow))
        lock.lock(); pending[request.identifier] = (request, timer); lock.unlock()
        timer.resume()
        return nil
    }

    private func cancelPending(_ id: String) {
        lock.lock(); let t = pending.removeValue(forKey: id); lock.unlock()
        t?.1.cancel()
    }

    open func getPendingNotificationRequests(completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void) {
        let r = pendingRequests()
        DispatchQueue.main.async { completionHandler(r) }
    }
    open func pendingNotificationRequests() async -> [UNNotificationRequest] { pendingRequests() }
    func pendingRequests() -> [UNNotificationRequest] { lock.lock(); defer { lock.unlock() }; return pending.values.map(\.0) }

    open func removePendingNotificationRequests(withIdentifiers identifiers: [String]) { identifiers.forEach(cancelPending) }
    open func removeAllPendingNotificationRequests() {
        lock.lock(); let all = pending.keys; lock.unlock()
        all.forEach(cancelPending)
    }

    open func getDeliveredNotifications(completionHandler: @escaping @Sendable ([UNNotification]) -> Void) {
        let d = deliveredNotes()
        DispatchQueue.main.async { completionHandler(d) }
    }
    open func deliveredNotifications() async -> [UNNotification] { deliveredNotes() }
    func deliveredNotes() -> [UNNotification] {
        lock.lock(); defer { lock.unlock() }
        return delivered.values.map(\.0).sorted { $0.date < $1.date }
    }

    open func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        lock.lock()
        let ids = identifiers.compactMap { delivered.removeValue(forKey: $0)?.1 }
        lock.unlock()
        ids.forEach(backend.close)
    }
    open func removeAllDeliveredNotifications() {
        lock.lock()
        let ids = delivered.values.map(\.1)
        delivered.removeAll()
        lock.unlock()
        ids.forEach(backend.close)
    }

    // MARK: Delivery

    private func deliver(_ request: UNNotificationRequest) {
        let note = UNNotification(date: Date(), request: request)
        DispatchQueue.main.async { [self] in
            if let d = delegate {
                d.userNotificationCenter(self, willPresent: note) { options in
                    if options.contains(_defaultMarker) || !options.isDisjoint(with: [.banner, .alert, .list]) || options.contains(.sound) {
                        self.timers.async { self.show(note, silent: !options.contains(_defaultMarker) && options.isDisjoint(with: [.banner, .alert, .list])) }
                    } else {
                        self.record(note, serverID: nil)
                    }
                }
            } else {
                timers.async { self.show(note, silent: false) }
            }
        }
    }

    private func show(_ note: UNNotification, silent: Bool) {
        let req = note.request
        lock.lock()
        let category = categories.first { $0.identifier == req.content.categoryIdentifier }
        let replaces = delivered[req.identifier]?.1 ?? 0
        lock.unlock()
        let id = silent ? nil : backend.show(req.content, actions: category?.actions ?? [], replaces: replaces)
        record(note, serverID: id)
    }

    private func record(_ note: UNNotification, serverID: UInt32?) {
        lock.lock(); delivered[note.request.identifier] = (note, serverID ?? 0); lock.unlock()
    }

    private func notification(forServerID id: UInt32) -> UNNotification? {
        lock.lock(); defer { lock.unlock() }
        return delivered.values.first { $0.1 == id && id != 0 }?.0
    }

    private func respond(serverID: UInt32, actionKey: String, text: String?) {
        guard let note = notification(forServerID: serverID) else { return }
        let identifier = actionKey == "default" ? UNNotificationDefaultActionIdentifier : actionKey
        let response: UNNotificationResponse = text.map { UNTextInputNotificationResponse(notification: note, actionIdentifier: identifier, userText: $0) }
            ?? UNNotificationResponse(notification: note, actionIdentifier: identifier)
        DispatchQueue.main.async { [self] in delegate?.userNotificationCenter(self, didReceive: response) {} }
    }

    private func closed(serverID: UInt32, dismissed: Bool) {
        guard let note = notification(forServerID: serverID) else { return }
        lock.lock()
        let category = categories.first { $0.identifier == note.request.content.categoryIdentifier }
        delivered[note.request.identifier] = nil
        lock.unlock()
        if dismissed, category?.options.contains(.customDismissAction) == true {
            let response = UNNotificationResponse(notification: note, actionIdentifier: UNNotificationDismissActionIdentifier)
            DispatchQueue.main.async { [self] in delegate?.userNotificationCenter(self, didReceive: response) {} }
        }
    }
}

// MARK: Backend

final class NotificationBackend: @unchecked Sendable {
    var onAction: ((UInt32, String, String?) -> Void)?
    var onClosed: ((UInt32, Bool) -> Void)?
    private let lock = NSLock()
    private var subscribed: DBusConnection?

    static let name = "org.freedesktop.Notifications"
    static let path = "/org/freedesktop/Notifications"

    nonisolated(unsafe) static var busOverride: DBusConnection?
    var bus: DBusConnection? { NotificationBackend.busOverride ?? DBusConnection.session }

    var available: Bool {
        #if os(Linux)
        guard let bus else { return false }
        if bus.hasOwner(NotificationBackend.name) { return true }
        let names = (try? bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListActivatableNames"))?.first?.children
        return names?.contains { $0.string == NotificationBackend.name } ?? false
        #else
        return false
        #endif
    }

    private func subscribe(_ bus: DBusConnection) {
        lock.lock()
        guard subscribed !== bus else { lock.unlock(); return }
        subscribed = bus
        lock.unlock()
        #if os(Linux)
        bus.subscribe(interface: NotificationBackend.name, member: "ActionInvoked", path: NotificationBackend.path) { [weak self] s in
            guard let id = s.arguments.first?.int, let key = s.arguments.count > 1 ? s.arguments[1].string : nil else { return }
            self?.onAction?(UInt32(id), key, nil)
        }
        bus.subscribe(interface: NotificationBackend.name, member: "NotificationClosed", path: NotificationBackend.path) { [weak self] s in
            guard let id = s.arguments.first?.int else { return }
            // Reason 2: dismissed by the user.
            self?.onClosed?(UInt32(id), s.arguments.count > 1 && s.arguments[1].int == 2)
        }
        #endif
    }

    var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
    }

    func show(_ c: UNNotificationContent, actions: [UNNotificationAction], replaces: UInt32) -> UInt32? {
        #if os(Linux)
        guard let bus else { return nil }
        subscribe(bus)
        var actionList: [DBusValue] = [.string("default"), .string("")]
        for a in actions { actionList += [.string(a.identifier), .string(a.title)] }
        var hints: [String: DBusValue] = [:]
        if let s = c.sound {
            if let n = s.name?.rawValue { hints["sound-name"] = .string((n as NSString).deletingPathExtension) } else { hints["sound-name"] = .string("message-new-instant") }
        } else {
            hints["suppress-sound"] = .bool(true)
        }
        switch c.interruptionLevel {
        case .critical, .timeSensitive: hints["urgency"] = .byte(2)
        case .passive: hints["urgency"] = .byte(0)
        default: hints["urgency"] = .byte(1)
        }
        if let image = c.attachments.first(where: { $0.type.hasPrefix("public.") && $0.type != "public.data" || $0.type.hasPrefix("com.") }) {
            hints["image-path"] = .string(image.url.absoluteString)
        }
        if let id = Bundle.main.bundleIdentifier { hints["desktop-entry"] = .string(id) }
        let summary = c.subtitle.isEmpty ? c.title : (c.title.isEmpty ? c.subtitle : "\(c.title) — \(c.subtitle)")
        let reply = try? bus.call(NotificationBackend.name, NotificationBackend.path, NotificationBackend.name, "Notify", [
            .string(appName), .uint32(replaces), .string(""), .string(summary), .string(c.body),
            .array("s", actionList), .vardict(hints), .int32(-1),
        ])
        return reply?.first?.int.map { UInt32($0) }
        #else
        return nil
        #endif
    }

    func close(_ id: UInt32) {
        #if os(Linux)
        guard id != 0, let bus else { return }
        _ = try? bus.call(NotificationBackend.name, NotificationBackend.path, NotificationBackend.name, "CloseNotification", [.uint32(id)])
        #endif
    }

    /// Unity's launcher API (honoured by KDE, Dash to Dock, Plank).
    func setBadge(_ n: Int) {
        #if os(Linux)
        guard let bus, let id = Bundle.main.bundleIdentifier else { return }
        bus.emit(path: "/com/canonical/unity/launcherentry/\(abs(id.hashValue))", interface: "com.canonical.Unity.LauncherEntry", member: "Update",
                 [.string("application://\(id).desktop"), .vardict(["count": .int64(Int64(n)), "count-visible": .bool(n > 0)])])
        #endif
    }
}

/// Tests and tools: send notifications over this bus instead of the session bus.
public func _runwayUseNotificationBus(_ bus: DBusConnection?) { NotificationBackend.busOverride = bus }
