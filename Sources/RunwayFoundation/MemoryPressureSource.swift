// Dispatch's memory pressure sources (`DispatchSource.makeMemoryPressureSource`),
// which corelibs libdispatch builds only on Darwin. Here the system's free
// memory is sampled on a timer and the source fires when the level changes:
//
//   Linux    MemAvailable / MemTotal from /proc/meminfo
//   Windows  GlobalMemoryStatusEx's dwMemoryLoad
//
//   .normal    more than 15% of memory available
//   .warning   15% or less
//   .critical  5% or less
//
// Sampling runs on a utility queue every two seconds and costs one small
// read; the handler only runs on a change into a level in the mask.

import Foundation
import Dispatch
#if os(Windows)
import WinSDK
#endif

extension DispatchSource {
    public struct MemoryPressureEvent: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let normal = MemoryPressureEvent(rawValue: 0x1)
        public static let warning = MemoryPressureEvent(rawValue: 0x2)
        public static let critical = MemoryPressureEvent(rawValue: 0x4)
        public static let all: MemoryPressureEvent = [.normal, .warning, .critical]
    }

    /// A source that reports changes in the system's memory pressure on
    /// `queue` (the default global queue when nil). It starts inactive.
    public class func makeMemoryPressureSource(eventMask: DispatchSource.MemoryPressureEvent,
                                               queue: DispatchQueue? = nil) -> DispatchSourceMemoryPressure {
        MemoryPressureSource(mask: eventMask, queue: queue ?? .global())
    }
}

public protocol DispatchSourceMemoryPressure: DispatchSourceProtocol {
    /// The level seen when the handler last ran.
    var data: DispatchSource.MemoryPressureEvent { get }
    var mask: DispatchSource.MemoryPressureEvent { get }
    func _setEventHandler(handler: (() -> Void)?)
    func _setCancelHandler(handler: (() -> Void)?)
    func _activate()
    var _pressure: (data: DispatchSource.MemoryPressureEvent, mask: DispatchSource.MemoryPressureEvent) { get }
}

extension DispatchSourceMemoryPressure {
    public func setEventHandler(qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = [], handler: DispatchSourceHandler?) {
        _setEventHandler(handler: FileSystemObjectSource.swiftClosure(handler))
    }
    public func setEventHandler(handler: DispatchWorkItem) { _setEventHandler(handler: { handler.perform() }) }
    public func setCancelHandler(qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = [], handler: DispatchSourceHandler?) {
        _setCancelHandler(handler: FileSystemObjectSource.swiftClosure(handler))
    }
    public func setCancelHandler(handler: DispatchWorkItem) { _setCancelHandler(handler: { handler.perform() }) }
    public func activate() { _activate() }
    public var data: DispatchSource.MemoryPressureEvent { _pressure.data }
    public var mask: DispatchSource.MemoryPressureEvent { _pressure.mask }
}

final class MemoryPressureSource: DispatchSourceMemoryPressure, @unchecked Sendable {
    private let eventMask: DispatchSource.MemoryPressureEvent
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var eventHandler: (() -> Void)?
    private var cancelHandler: (() -> Void)?
    private var level: DispatchSource.MemoryPressureEvent = .normal
    private var delivered: DispatchSource.MemoryPressureEvent = []
    private var suspendCount = 1
    private var activated = false
    private var cancelled = false
    private var timer: DispatchSourceTimer?
    /// Overrides the sampled fraction of memory available (tests).
    nonisolated(unsafe) static var sampleOverride: (() -> Double?)?

    init(mask: DispatchSource.MemoryPressureEvent, queue: DispatchQueue) {
        eventMask = mask
        self.queue = queue
    }

    var _pressure: (data: DispatchSource.MemoryPressureEvent, mask: DispatchSource.MemoryPressureEvent) { (lock.withLock { delivered }, eventMask) }
    var handle: UInt { 0 }
    var mask: UInt { eventMask.rawValue }
    var data: UInt { lock.withLock { delivered.rawValue } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    func setEventHandler(qos: DispatchQoS, flags: DispatchWorkItemFlags, handler: DispatchSourceHandler?) {
        _setEventHandler(handler: FileSystemObjectSource.swiftClosure(handler))
    }
    func setEventHandler(handler: DispatchWorkItem) { _setEventHandler(handler: { handler.perform() }) }
    func setCancelHandler(qos: DispatchQoS, flags: DispatchWorkItemFlags, handler: DispatchSourceHandler?) {
        _setCancelHandler(handler: FileSystemObjectSource.swiftClosure(handler))
    }
    func setCancelHandler(handler: DispatchWorkItem) { _setCancelHandler(handler: { handler.perform() }) }
    func setRegistrationHandler(qos: DispatchQoS, flags: DispatchWorkItemFlags, handler: DispatchSourceHandler?) {
        if let h = FileSystemObjectSource.swiftClosure(handler) { queue.async(execute: h) }
    }
    func setRegistrationHandler(handler: DispatchWorkItem) { queue.async { handler.perform() } }

    func _setEventHandler(handler: (() -> Void)?) { lock.withLock { eventHandler = handler } }
    func _setCancelHandler(handler: (() -> Void)?) { lock.withLock { cancelHandler = handler } }

    func _activate() { resume() }

    func resume() {
        let start: Bool = lock.withLock {
            guard !cancelled, suspendCount > 0 else { return false }
            suspendCount -= 1
            if suspendCount == 0, !activated { activated = true; return true }
            if suspendCount == 0 { timer?.resume() }
            return false
        }
        if start { startSampling() }
    }

    func suspend() {
        lock.withLock {
            guard !cancelled else { return }
            suspendCount += 1
            if suspendCount == 1, activated { timer?.suspend() }
        }
    }

    func cancel() {
        let (h, t, wasSuspended): ((() -> Void)?, DispatchSourceTimer?, Bool) = lock.withLock {
            guard !cancelled else { return (nil, nil, false) }
            cancelled = true
            let h = cancelHandler
            eventHandler = nil
            cancelHandler = nil
            let t = timer
            timer = nil
            return (h, t, activated && suspendCount > 0)
        }
        if let t { if wasSuspended { t.resume() }; t.cancel() }
        if let h { queue.async(execute: h) }
    }

    private func startSampling() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.sample() }
        lock.withLock { timer = t }
        t.resume()
    }

    func sample() {
        guard let available = Self.sampleOverride?() ?? Self.availableFraction() else { return }
        let now: DispatchSource.MemoryPressureEvent = available <= 0.05 ? .critical : available <= 0.15 ? .warning : .normal
        let h: (() -> Void)? = lock.withLock {
            guard !cancelled, now != level else { return nil }
            level = now
            guard eventMask.contains(now) else { return nil }
            delivered = now
            return eventHandler
        }
        if let h { queue.async(execute: h) }
    }

    /// The fraction of physical memory available, 0…1.
    static func availableFraction() -> Double? {
        #if os(Linux)
        guard let text = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8) else { return nil }
        var total: Double?, available: Double?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let v = Double(parts[1]) else { continue }
            if parts[0] == "MemTotal:" { total = v } else if parts[0] == "MemAvailable:" { available = v }
            if total != nil, available != nil { break }
        }
        guard let total, let available, total > 0 else { return nil }
        return available / total
        #elseif os(Windows)
        var status = MEMORYSTATUSEX()
        status.dwLength = DWORD(MemoryLayout<MEMORYSTATUSEX>.size)
        guard GlobalMemoryStatusEx(&status) else { return nil }
        return 1 - Double(status.dwMemoryLoad) / 100
        #else
        return nil
        #endif
    }
}
