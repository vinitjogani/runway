#if os(Linux)
import XCTest
import Foundation
import RunwayDBus
import UserNotifications

/// A private bus with a fake org.freedesktop.Notifications server.
final class FakeNotificationServer: @unchecked Sendable {
    let daemon = Process()
    let address: String
    let server: DBusConnection
    let lock = NSLock()
    var notified: [[DBusValue]] = []
    var nextID: UInt32 = 1
    var onNotify: (() -> Void)?

    init?() {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/dbus-daemon") else { return nil }
        daemon.executableURL = URL(fileURLWithPath: "/usr/bin/dbus-daemon")
        daemon.arguments = ["--session", "--nofork", "--nopidfile", "--print-address=1"]
        let out = Pipe()
        daemon.standardOutput = out
        guard (try? daemon.run()) != nil else { return nil }
        var line = Data()
        while true {
            let b = out.fileHandleForReading.readData(ofLength: 1)
            if b.isEmpty || b == Data([0x0a]) { break }
            line.append(b)
        }
        address = String(decoding: line, as: UTF8.self)
        guard let s = try? DBusConnection.connect(address: address) else { return nil }
        server = s
        let xml = """
        <node><interface name="org.freedesktop.Notifications">
          <method name="Notify"><arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/>
            <arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/><arg type="a{sv}" direction="in"/>
            <arg type="i" direction="in"/><arg type="u" direction="out"/></method>
          <method name="CloseNotification"><arg type="u" direction="in"/></method>
          <method name="GetCapabilities"><arg type="as" direction="out"/></method>
        </interface></node>
        """
        _ = try? server.export(path: "/org/freedesktop/Notifications", introspectionXML: xml) { [unowned self] call in
            switch call.method {
            case "Notify":
                lock.lock()
                notified.append(call.arguments)
                let id = nextID
                nextID += 1
                let f = onNotify
                lock.unlock()
                f?()
                return .success([.uint32(id)])
            case "GetCapabilities": return .success([.array("s", [.string("actions"), .string("body")])])
            default: return .success([])
            }
        }
        guard server.requestName("org.freedesktop.Notifications") else { return nil }
    }

    deinit { daemon.terminate() }
}

final class Delegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var responses: [String] = []
    var onResponse: (() -> Void)?
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        responses.append(response.actionIdentifier)
        onResponse?()
        completionHandler()
    }
}

final class UserNotificationsTests: XCTestCase {
    func testDeliveryAuthorizationAndActions() throws {
        guard let fake = FakeNotificationServer() else { throw XCTSkip("no dbus-daemon") }
        let client = try DBusConnection.connect(address: fake.address)
        _runwayUseNotificationBus(client)
        defer { _runwayUseNotificationBus(nil) }

        let center = UNUserNotificationCenter.current()
        let auth = expectation(description: "authorized")
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in XCTAssertTrue(granted); auth.fulfill() }
        wait(for: [auth], timeout: 5)
        let set = expectation(description: "settings")
        center.getNotificationSettings { XCTAssertEqual($0.authorizationStatus, .authorized); set.fulfill() }
        wait(for: [set], timeout: 5)

        let delegate = Delegate()
        center.delegate = delegate
        center.setNotificationCategories([UNNotificationCategory(identifier: "msg", actions: [
            UNNotificationAction(identifier: "reply", title: "Reply", options: [.foreground]),
        ], intentIdentifiers: [])])

        let content = UNMutableNotificationContent()
        content.title = "Hello"
        content.body = "From Runway"
        content.sound = .default
        content.categoryIdentifier = "msg"

        let shown = expectation(description: "notified")
        fake.onNotify = { shown.fulfill() }
        center.add(UNNotificationRequest(identifier: "n1", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false))) {
            XCTAssertNil($0)
        }
        wait(for: [shown], timeout: 5)
        fake.lock.lock()
        let args = fake.notified.first ?? []
        fake.lock.unlock()
        XCTAssertEqual(args[3].string, "Hello")
        XCTAssertEqual(args[4].string, "From Runway")
        XCTAssertEqual(args[5].children.compactMap(\.string), ["default", "", "reply", "Reply"])
        XCTAssertEqual(args[6].dictionary["sound-name"]?.string, "message-new-instant")

        // The server reports a button press.
        let responded = expectation(description: "response")
        delegate.onResponse = { responded.fulfill() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        fake.server.emit(path: "/org/freedesktop/Notifications", interface: "org.freedesktop.Notifications", member: "ActionInvoked",
                         [.uint32(1), .string("reply")])
        wait(for: [responded], timeout: 5)
        XCTAssertEqual(delegate.responses, ["reply"])
        let listed = expectation(description: "delivered")
        center.getDeliveredNotifications { XCTAssertEqual($0.map(\.request.identifier), ["n1"]); listed.fulfill() }
        wait(for: [listed], timeout: 5)
    }

    func testTriggers() {
        let cal = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 9, minute: 30), repeats: true)
        let next = cal.nextTriggerDate()!
        XCTAssertGreaterThan(next, Date())
        XCTAssertEqual(Calendar.current.component(.minute, from: next), 30)
        let interval = UNTimeIntervalNotificationTrigger(timeInterval: 120, repeats: true)
        XCTAssertEqual(interval.nextTriggerDate()!.timeIntervalSinceNow, 120, accuracy: 1)
    }
}
#endif
