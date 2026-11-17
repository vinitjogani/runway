// NSAnimationContext and the animator proxy. Changes made through
// `animator()` or inside `runAnimationGroup` take effect at once (Runway
// doesn't tween view properties); completion handlers still run after the
// group's duration, as they would when the animation ends.

import Foundation
import QuartzCore

@preconcurrency @MainActor
open class NSAnimationContext: NSObject {
    private static var stack: [NSAnimationContext] = [NSAnimationContext()]
    /// The context of the current group.
    open class var current: NSAnimationContext { stack.last! }

    open var duration: TimeInterval = 0.25
    open var timingFunction: CAMediaTimingFunction?
    open var completionHandler: (() -> Void)?
    open var allowsImplicitAnimation = false

    open class func beginGrouping() { stack.append(NSAnimationContext()) }
    open class func endGrouping() {
        guard stack.count > 1, let c = stack.popLast() else { return }
        if let h = c.completionHandler { finish(after: c.duration, h) }
    }
    open class func runAnimationGroup(_ changes: (NSAnimationContext) -> Void, completionHandler: (() -> Void)? = nil) {
        beginGrouping()
        let c = current
        changes(c)
        if let h = completionHandler {
            let prior = c.completionHandler
            c.completionHandler = { prior?(); h() }
        }
        endGrouping()
    }
    open class func runAnimationGroup(_ changes: (NSAnimationContext) -> Void) {
        runAnimationGroup(changes, completionHandler: nil)
    }
    /// The async form: returns once the group has finished.
    open class func runAnimationGroup(_ changes: (NSAnimationContext) -> Void) async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            runAnimationGroup(changes) { k.resume() }
        }
    }

    private static func finish(after duration: TimeInterval, _ handler: @escaping () -> Void) {
        let h = UncheckedHandler(handler)
        if duration <= 0 { DispatchQueue.main.async { h.run() }; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { h.run() }
    }
    private struct UncheckedHandler: @unchecked Sendable {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }
}

/// Objects whose properties can be animated through a proxy (NSView,
/// NSWindow, NSLayoutConstraint). The proxy is the object itself: changes
/// apply immediately.
@preconcurrency @MainActor public protocol NSAnimatablePropertyContainer: AnyObject {
    func animator() -> Self
    var animations: [NSAnimatablePropertyKey: Any] { get set }
    func animation(forKey key: NSAnimatablePropertyKey) -> Any?
}
public typealias NSAnimatablePropertyKey = String

extension NSView: NSAnimatablePropertyContainer {
    public func animator() -> Self { self }
    public var animations: [NSAnimatablePropertyKey: Any] {
        get { [:] }
        set {}
    }
    public func animation(forKey key: NSAnimatablePropertyKey) -> Any? { nil }
    public static func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? { nil }
}
extension NSWindow: NSAnimatablePropertyContainer {
    public func animator() -> Self { self }
    public var animations: [NSAnimatablePropertyKey: Any] {
        get { [:] }
        set {}
    }
    public func animation(forKey key: NSAnimatablePropertyKey) -> Any? { nil }
}
extension NSLayoutConstraint: NSAnimatablePropertyContainer {
    public func animator() -> Self { self }
    public var animations: [NSAnimatablePropertyKey: Any] {
        get { [:] }
        set {}
    }
    public func animation(forKey key: NSAnimatablePropertyKey) -> Any? { nil }
}
