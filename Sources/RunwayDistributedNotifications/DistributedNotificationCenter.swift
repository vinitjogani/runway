// DistributedNotificationCenter (Foundation on the Mac; swift-corelibs
// lacks it) over D-Bus on Linux: a post is a signal on the session bus
// (path /org/runway/DistributedNotificationCenter, interface
// org.runway.DistributedNotification, member Post: name, object, userInfo
// as JSON, sender pid), and every Runway process with observers receives it
// as an ordinary Notification on its own center. A few system notifications
// apps listen for are bridged from the desktop: screen lock/unlock
// (org.freedesktop.ScreenSaver ActiveChanged → com.apple.screenIsLocked /
// com.apple.screenIsUnlocked) and the appearance switch (the settings
// portal's color-scheme → AppleInterfaceThemeChangedNotification).
// Elsewhere (Windows, no session bus) it's a process-local center.

import Foundation
import RunwayDBus

open class DistributedNotificationCenter: NotificationCenter, @unchecked Sendable {
    public struct CenterType: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let localNotificationCenterType = CenterType("NSLocalNotificationCenterType")
    }

    public struct Options: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let deliverImmediately = Options(rawValue: 1 << 0)
        public static let postToAllSessions = Options(rawValue: 1 << 1)
    }

    public enum SuspensionBehavior: UInt, Sendable { case drop = 1, coalesce = 2, hold = 3, deliverImmediately = 4 }

    private static let shared = DistributedNotificationCenter(bridged: true)
    open class func `default`() -> DistributedNotificationCenter { shared }
    open class func forType(_ notificationCenterType: CenterType) -> DistributedNotificationCenter { shared }

    open var suspended = false

    static let path = "/org/runway/DistributedNotificationCenter"
    static let interface = "org.runway.DistributedNotification"
    private let lock = NSLock()
    private var listening = false
    private let bridged: Bool

    init(bridged: Bool) {
        self.bridged = bridged
        super.init()
        listen()
    }
    public required init() { bridged = false; super.init() }

    private func listen() {
        lock.lock()
        guard !listening else { lock.unlock(); return }
        listening = true
        lock.unlock()
        #if os(Linux)
        guard let bus = DBusConnection.session else { return }
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        bus.subscribe(interface: Self.interface, member: "Post", path: Self.path) { [weak self] s in
            guard let self, s.arguments.count >= 4, let name = s.arguments[0].string, s.arguments[3].int != pid else { return }
            let object = s.arguments[1].string.flatMap { $0.isEmpty ? nil : $0 }
            let info = s.arguments[2].string.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [AnyHashable: Any] }
            self.deliver(Notification.Name(name), object, info)
        }
        guard bridged else { return }
        bus.subscribe(interface: "org.freedesktop.ScreenSaver", member: "ActiveChanged") { [weak self] s in
            guard let active = s.arguments.first?.bool else { return }
            self?.deliver(Notification.Name(active ? "com.apple.screenIsLocked" : "com.apple.screenIsUnlocked"), nil, nil)
        }
        bus.subscribe(interface: "org.freedesktop.portal.Settings", member: "SettingChanged") { [weak self] s in
            guard s.arguments.first?.string == "org.freedesktop.appearance", s.arguments.count > 1, s.arguments[1].string == "color-scheme" else { return }
            self?.deliver(Notification.Name("AppleInterfaceThemeChangedNotification"), nil, nil)
        }
        #endif
    }

    private func deliver(_ name: Notification.Name, _ object: String?, _ info: [AnyHashable: Any]?) {
        guard !suspended else { return }
        DispatchQueue.main.async { self.postLocally(name, object, info) }
    }

    private func postLocally(_ name: Notification.Name, _ object: String?, _ info: [AnyHashable: Any]?) {
        (self as NotificationCenter).post(name: name, object: object as Any?, userInfo: info)
    }

    open func addObserver(forName name: NSNotification.Name?, object: String?, suspensionBehavior: SuspensionBehavior,
                          queue: OperationQueue?, using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
        addObserver(forName: name, object: object as Any?, queue: queue, using: block)
    }

    open func postNotificationName(_ name: NSNotification.Name, object: String?, userInfo: [AnyHashable: Any]? = nil, deliverImmediately: Bool) {
        post(name: name, object: object as String?, userInfo: userInfo)
    }

    open func postNotificationName(_ name: NSNotification.Name, object: String?, userInfo: [AnyHashable: Any]? = nil, options: Options = []) {
        post(name: name, object: object as String?, userInfo: userInfo)
    }

    open func postNotificationName(_ name: NSNotification.Name, object: String?) {
        post(name: name, object: object as String?, userInfo: nil)
    }

    /// Posts here and to every other Runway process on the session bus. (The
    /// `Any?`-object form inherited from NotificationCenter stays local.)
    open func post(name aName: NSNotification.Name, object anObject: String?, userInfo aUserInfo: [AnyHashable: Any]? = nil) {
        postLocally(aName, anObject, aUserInfo)
        #if os(Linux)
        guard let bus = DBusConnection.session else { return }
        var json = ""
        if let info = aUserInfo {
            let plain = Dictionary(uniqueKeysWithValues: info.compactMap { k, v in (k as? String).map { ($0, v) } })
            if JSONSerialization.isValidJSONObject(plain), let d = try? JSONSerialization.data(withJSONObject: plain) { json = String(decoding: d, as: UTF8.self) }
        }
        bus.emit(path: Self.path, interface: Self.interface, member: "Post", [
            .string(aName.rawValue), .string(anObject ?? ""), .string(json),
            .int64(Int64(ProcessInfo.processInfo.processIdentifier)),
        ])
        #endif
    }

}
