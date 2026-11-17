// Selector-based notification observers and timers.

import Foundation

// MARK: NotificationCenter

private final class SelectorObservers: @unchecked Sendable {
    let lock = NSLock()
    struct Reg { let center: ObjectIdentifier; let observer: ObjectIdentifier; let name: NSNotification.Name?; let object: ObjectIdentifier?; let token: NSObjectProtocol }
    var regs: [Reg] = []
}
private let selectorObservers = SelectorObservers()

extension NotificationCenter {
    /// `addObserver:selector:name:object:`: `observer` gets `aSelector` with
    /// the notification, on the posting thread. The observer isn't retained;
    /// its registrations go when it's deallocated (as on macOS 10.11+).
    public func addObserver(_ observer: Any, selector aSelector: Selector, name aName: NSNotification.Name?, object anObject: Any?) {
        let target = observer as AnyObject
        let me = ObjectIdentifier(self), them = ObjectIdentifier(target)
        final class Box: @unchecked Sendable { var token: NSObjectProtocol? }
        let box = Box()
        let token = addObserver(forName: aName, object: anObject, queue: nil) { [weak self, weak target] n in
            guard let t = target else {
                if let token = box.token { self?.removeSelectorObservers { $0.token === token } }
                return
            }
            RunwayObjC.perform(t, aSelector, [n])
        }
        box.token = token
        selectorObservers.lock.lock()
        selectorObservers.regs.append(.init(center: me, observer: them, name: aName, object: identity(anObject), token: token))
        selectorObservers.lock.unlock()
    }

    /// What `removeObserver(_:)` on a notification center becomes: removes
    /// selector registrations as well as Foundation's own.
    public func _runwayRemoveObserver(_ observer: Any) {
        let them = ObjectIdentifier(observer as AnyObject)
        removeSelectorObservers { $0.observer == them }
        removeObserver(observer, name: nil, object: nil)
    }

    /// What `removeObserver(_:name:object:)` becomes.
    public func _runwayRemoveObserver(_ observer: Any, name aName: NSNotification.Name?, object anObject: Any?) {
        let them = ObjectIdentifier(observer as AnyObject), obj = identity(anObject)
        removeSelectorObservers { $0.observer == them && (aName == nil || $0.name == aName) && (obj == nil || $0.object == obj) }
        removeObserver(observer, name: aName, object: anObject)
    }

    private func removeSelectorObservers(_ match: (SelectorObservers.Reg) -> Bool) {
        let me = ObjectIdentifier(self)
        selectorObservers.lock.lock()
        let hit = selectorObservers.regs.filter { $0.center == me && match($0) }
        selectorObservers.regs.removeAll { $0.center == me && match($0) }
        selectorObservers.lock.unlock()
        for r in hit { removeObserver(r.token, name: nil, object: nil) }
    }
}

// MARK: Timer

/// A timer that sends a selector to a target (`Timer(timeInterval:target:selector:userInfo:repeats:)`
/// is rewritten to this; `Timer.scheduledTimer(timeInterval:target:...)` returns one).
/// The target is retained until the timer is invalidated, as on the Mac.
open class SelectorTimer: Timer {
    private var storedUserInfo: Any?
    open override var userInfo: Any? { storedUserInfo }

    public convenience init(timeInterval ti: TimeInterval, target aTarget: Any, selector aSelector: Selector, userInfo: Any?, repeats yesOrNo: Bool) {
        let target = aTarget as AnyObject
        self.init(timeInterval: ti, repeats: yesOrNo) { t in RunwayObjC.perform(target, aSelector, [t]) }
        storedUserInfo = userInfo
    }

    public convenience init(fireAt date: Date, interval ti: TimeInterval, target t: Any, selector s: Selector, userInfo ui: Any?, repeats rep: Bool) {
        let target = t as AnyObject
        self.init(fire: date, interval: ti, repeats: rep) { timer in RunwayObjC.perform(target, s, [timer]) }
        storedUserInfo = ui
    }
}

extension Timer {
    /// `scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:`, on
    /// the current run loop.
    @discardableResult
    public class func scheduledTimer(timeInterval ti: TimeInterval, target aTarget: Any, selector aSelector: Selector, userInfo: Any?, repeats yesOrNo: Bool) -> Timer {
        let t = SelectorTimer(timeInterval: ti, target: aTarget, selector: aSelector, userInfo: userInfo, repeats: yesOrNo)
        RunLoop.current.add(t, forMode: .default)
        return t
    }
}

import RunwayDistributedNotifications

extension DistributedNotificationCenter {
    /// `addObserver:selector:name:object:suspensionBehavior:`.
    public func addObserver(_ observer: Any, selector aSelector: Selector, name aName: NSNotification.Name?, object anObject: String?,
                            suspensionBehavior: DistributedNotificationCenter.SuspensionBehavior) {
        addObserver(observer, selector: aSelector, name: aName, object: anObject as Any?)
    }
}
