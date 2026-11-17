// Foundation classes Apple ships and swift-corelibs-foundation doesn't:
// FileWrapper (real), NSUbiquitousKeyValueStore (a local store: there is no
// iCloud), NSUserActivity, NSFileCoordinator/NSFilePresenter (coordination
// within the process), NSBackgroundActivityScheduler (a timer), and the
// Mach-service ones, NSXPCConnection/NSXPCListener/NSXPCInterface, which
// have no services to reach: connections fail through their own error,
// interruption and invalidation handlers, as on a Mac whose helper isn't
// installed. NSAppleScript compiles and reports that scripting isn't
// available. NSExtensionItem carries attachments.

import Foundation

// MARK: FileWrapper

open class FileWrapper: NSObject, @unchecked Sendable {
    public struct ReadingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let immediate = ReadingOptions(rawValue: 1)
        public static let withoutMapping = ReadingOptions(rawValue: 2)
    }
    public struct WritingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let atomic = WritingOptions(rawValue: 1)
        public static let withNameUpdating = WritingOptions(rawValue: 2)
    }
    enum Kind { case file(Data), directory([String: FileWrapper]), link(URL) }
    var kind: Kind
    open var preferredFilename: String?
    open var filename: String?
    open var fileAttributes: [String: Any] = [:]

    public init(regularFileWithContents contents: Data) { kind = .file(contents) }
    public init(directoryWithFileWrappers childrenByPreferredName: [String: FileWrapper]) {
        for (name, w) in childrenByPreferredName where w.preferredFilename == nil { w.preferredFilename = name }
        kind = .directory(childrenByPreferredName)
    }
    public init(symbolicLinkWithDestinationURL url: URL) { kind = .link(url) }
    public init(url: URL, options: ReadingOptions = []) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        if let dest = try? fm.destinationOfSymbolicLink(atPath: url.path) {
            kind = .link(URL(fileURLWithPath: dest, relativeTo: url.deletingLastPathComponent()))
        } else if isDir.boolValue {
            var children: [String: FileWrapper] = [:]
            for name in try fm.contentsOfDirectory(atPath: url.path) {
                children[name] = try FileWrapper(url: url.appendingPathComponent(name), options: options)
            }
            kind = .directory(children)
        } else {
            kind = .file(try Data(contentsOf: url))
        }
        super.init()
        filename = url.lastPathComponent
        preferredFilename = url.lastPathComponent
    }
    public convenience init?(serializedRepresentation: Data) { self.init(regularFileWithContents: serializedRepresentation) }

    open var isRegularFile: Bool { if case .file = kind { return true }; return false }
    open var isDirectory: Bool { if case .directory = kind { return true }; return false }
    open var isSymbolicLink: Bool { if case .link = kind { return true }; return false }
    open var regularFileContents: Data? { if case .file(let d) = kind { return d }; return nil }
    open var fileWrappers: [String: FileWrapper]? { if case .directory(let c) = kind { return c }; return nil }
    open var symbolicLinkDestinationURL: URL? { if case .link(let u) = kind { return u }; return nil }
    open var serializedRepresentation: Data? { regularFileContents }

    @discardableResult
    open func addFileWrapper(_ child: FileWrapper) -> String {
        guard case .directory(var c) = kind else { return "" }
        var name = child.preferredFilename ?? UUID().uuidString
        let base = name
        var n = 2
        while c[name] != nil { name = "\(n) \(base)"; n += 1 }
        c[name] = child
        kind = .directory(c)
        return name
    }
    @discardableResult
    open func addRegularFile(withContents data: Data, preferredFilename fileName: String) -> String {
        let w = FileWrapper(regularFileWithContents: data)
        w.preferredFilename = fileName
        return addFileWrapper(w)
    }
    open func removeFileWrapper(_ child: FileWrapper) {
        guard case .directory(var c) = kind else { return }
        for (k, v) in c where v === child { c[k] = nil }
        kind = .directory(c)
    }
    open func keyForChildFileWrapper(_ child: FileWrapper) -> String? {
        fileWrappers?.first { $0.value === child }?.key
    }
    open func matchesContents(of url: URL) -> Bool {
        guard let other = try? FileWrapper(url: url) else { return false }
        return regularFileContents == other.regularFileContents
    }
    open func read(from url: URL, options: ReadingOptions = []) throws {
        kind = try FileWrapper(url: url, options: options).kind
    }
    open func write(to url: URL, options: WritingOptions = [], originalContentsURL: URL?) throws {
        let fm = FileManager.default
        switch kind {
        case .file(let d): try d.write(to: url, options: options.contains(.atomic) ? .atomic : [])
        case .link(let dest): try fm.createSymbolicLink(at: url, withDestinationURL: dest)
        case .directory(let c):
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            for (name, w) in c { try w.write(to: url.appendingPathComponent(name), options: options, originalContentsURL: nil) }
        }
        if options.contains(.withNameUpdating) { filename = url.lastPathComponent }
    }
}

// MARK: NSUbiquitousKeyValueStore

/// iCloud's key-value store, kept locally (a property list under the
/// user's data directory): values persist, nothing syncs, so
/// `didChangeExternallyNotification` never fires.
open class NSUbiquitousKeyValueStore: NSObject, @unchecked Sendable {
    public static let didChangeExternallyNotification = Notification.Name("NSUbiquitousKeyValueStoreDidChangeExternallyNotification")
    public static let `default` = NSUbiquitousKeyValueStore()
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private let file: URL

    public override init() {
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        let id = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        file = base.appendingPathComponent(id).appendingPathComponent("UbiquitousKeyValueStore.plist")
        super.init()
        if let data = try? Data(contentsOf: file),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            values = plist
        }
    }

    open func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    open func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    open func removeObject(forKey key: String) { lock.withLock { values[key] = nil } }
    open func string(forKey key: String) -> String? { object(forKey: key) as? String }
    open func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    open func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    open func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    open func longLong(forKey key: String) -> Int64 { (object(forKey: key) as? NSNumber)?.int64Value ?? (object(forKey: key) as? Int).map(Int64.init) ?? 0 }
    open func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? (object(forKey: key) as? Double) ?? 0 }
    open func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? (object(forKey: key) as? Bool) ?? false }
    open func set(_ value: String?, forKey key: String) { set(value as Any?, forKey: key) }
    open func set(_ value: Data?, forKey key: String) { set(value as Any?, forKey: key) }
    open func set(_ value: [Any]?, forKey key: String) { set(value as Any?, forKey: key) }
    open func set(_ value: [String: Any]?, forKey key: String) { set(value as Any?, forKey: key) }
    open func set(_ value: Int64, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    open func set(_ value: Double, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    open func set(_ value: Bool, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    open var dictionaryRepresentation: [String: Any] { lock.withLock { values } }

    @discardableResult
    open func synchronize() -> Bool {
        let snapshot = lock.withLock { values }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0) else { return false }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: file, options: .atomic)) != nil
    }
}

public let NSUbiquitousKeyValueStoreChangeReasonKey = "NSUbiquitousKeyValueStoreChangeReasonKey"
public let NSUbiquitousKeyValueStoreChangedKeysKey = "NSUbiquitousKeyValueStoreChangedKeysKey"
public let NSUbiquitousKeyValueStoreServerChange = 0
public let NSUbiquitousKeyValueStoreInitialSyncChange = 1
public let NSUbiquitousKeyValueStoreQuotaViolationChange = 2
public let NSUbiquitousKeyValueStoreAccountChange = 3

// MARK: NSUserActivity

/// Handoff and Spotlight activities: kept as values; there is no other
/// device to continue on.
open class NSUserActivity: NSObject, @unchecked Sendable {
    public let activityType: String
    open var title: String?
    open var userInfo: [AnyHashable: Any]?
    open var requiredUserInfoKeys: Set<String>?
    open var keywords: Set<String> = []
    open var webpageURL: URL?
    open var referrerURL: URL?
    open var expirationDate: Date?
    open var targetContentIdentifier: String?
    open var persistentIdentifier: String?
    open var isEligibleForHandoff = true
    open var isEligibleForSearch = false
    open var isEligibleForPublicIndexing = false
    open var isEligibleForPrediction = false
    open var needsSave = false
    open var supportsContinuationStreams = false
    open weak var delegate: NSUserActivityDelegate?
    open var contentAttributeSet: AnyObject?
    nonisolated(unsafe) private static var current: NSUserActivity?

    public init(activityType: String) { self.activityType = activityType }
    open func addUserInfoEntries(from otherDictionary: [AnyHashable: Any]) {
        var u = userInfo ?? [:]
        for (k, v) in otherDictionary { u[k] = v }
        userInfo = u
    }
    open func becomeCurrent() { Self.current = self }
    open func resignCurrent() { if Self.current === self { Self.current = nil } }
    open func invalidate() { resignCurrent() }
    public static func deleteSavedUserActivities(withPersistentIdentifiers ids: [String], completionHandler: @escaping () -> Void) { completionHandler() }
    public static func deleteAllSavedUserActivities(completionHandler: @escaping () -> Void) { completionHandler() }
}

public protocol NSUserActivityDelegate: AnyObject {
    func userActivityWillSave(_ userActivity: NSUserActivity)
    func userActivityWasContinued(_ userActivity: NSUserActivity)
}
extension NSUserActivityDelegate {
    public func userActivityWillSave(_ userActivity: NSUserActivity) {}
    public func userActivityWasContinued(_ userActivity: NSUserActivity) {}
}

public typealias NSErrorPointer = AutoreleasingUnsafeMutablePointer<NSError?>?

// MARK: File coordination

public protocol NSFilePresenter: AnyObject {
    var presentedItemURL: URL? { get }
    var presentedItemOperationQueue: OperationQueue { get }
    func presentedItemDidChange()
    func presentedSubitemDidChange(at url: URL)
    func presentedItemDidMove(to newURL: URL)
    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void)
    func relinquishPresentedItem(toReader reader: @escaping ((() -> Void)?) -> Void)
    func relinquishPresentedItem(toWriter writer: @escaping ((() -> Void)?) -> Void)
    func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void)
}

extension NSFilePresenter {
    public func presentedItemDidChange() {}
    public func presentedSubitemDidChange(at url: URL) {}
    public func presentedItemDidMove(to newURL: URL) {}
    public func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }
    public func relinquishPresentedItem(toReader reader: @escaping ((() -> Void)?) -> Void) { reader(nil) }
    public func relinquishPresentedItem(toWriter writer: @escaping ((() -> Void)?) -> Void) { writer(nil) }
    public func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }
}

/// Coordination within this process: accessors run at once, serialized;
/// presenters registered here hear about writes made through a coordinator.
open class NSFileCoordinator: NSObject, @unchecked Sendable {
    public struct ReadingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let withoutChanges = ReadingOptions(rawValue: 1)
        public static let resolvesSymbolicLink = ReadingOptions(rawValue: 2)
        public static let immediatelyAvailableMetadataOnly = ReadingOptions(rawValue: 4)
        public static let forUploading = ReadingOptions(rawValue: 8)
    }
    public struct WritingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let forDeleting = WritingOptions(rawValue: 1)
        public static let forMoving = WritingOptions(rawValue: 2)
        public static let forMerging = WritingOptions(rawValue: 4)
        public static let forReplacing = WritingOptions(rawValue: 8)
        public static let contentIndependentMetadataOnly = WritingOptions(rawValue: 16)
    }
    nonisolated(unsafe) private static var presenters: [ObjectIdentifier: NSFilePresenter] = [:]
    private static let lock = NSRecursiveLock()
    weak var filePresenter: NSFilePresenter?
    open var purposeIdentifier = UUID().uuidString

    public init(filePresenter: NSFilePresenter?) { self.filePresenter = filePresenter }
    public override convenience init() { self.init(filePresenter: nil) }

    open class func addFilePresenter(_ presenter: NSFilePresenter) { lock.withLock { presenters[ObjectIdentifier(presenter)] = presenter } }
    open class func removeFilePresenter(_ presenter: NSFilePresenter) { lock.withLock { presenters[ObjectIdentifier(presenter)] = nil } }
    open class var filePresenters: [NSFilePresenter] { lock.withLock { Array(presenters.values) } }

    open func coordinate(readingItemAt url: URL, options: ReadingOptions = [], error outError: NSErrorPointer, byAccessor reader: (URL) -> Void) {
        Self.lock.withLock { reader(url) }
    }
    open func coordinate(writingItemAt url: URL, options: WritingOptions = [], error outError: NSErrorPointer, byAccessor writer: (URL) -> Void) {
        Self.lock.withLock { writer(url) }
        notify(url)
    }
    open func coordinate(readingItemAt readingURL: URL, options readingOptions: ReadingOptions = [], writingItemAt writingURL: URL,
                         options writingOptions: WritingOptions = [], error outError: NSErrorPointer, byAccessor readerWriter: (URL, URL) -> Void) {
        Self.lock.withLock { readerWriter(readingURL, writingURL) }
        notify(writingURL)
    }
    open func coordinate(writingItemAt url1: URL, options options1: WritingOptions = [], writingItemAt url2: URL,
                         options options2: WritingOptions = [], error outError: NSErrorPointer, byAccessor writer: (URL, URL) -> Void) {
        Self.lock.withLock { writer(url1, url2) }
        notify(url1)
        notify(url2)
    }
    open func coordinate(with intents: [NSFileAccessIntent], queue: OperationQueue, byAccessor accessor: @escaping (Error?) -> Void) {
        queue.addOperation { Self.lock.withLock { accessor(nil) } }
    }
    open func item(at oldURL: URL, willMoveTo newURL: URL) {}
    open func item(at oldURL: URL, didMoveTo newURL: URL) {
        for p in Self.filePresenters where p !== filePresenter && p.presentedItemURL?.standardizedFileURL == oldURL.standardizedFileURL {
            p.presentedItemOperationQueue.addOperation { p.presentedItemDidMove(to: newURL) }
        }
    }
    open func cancel() {}

    private func notify(_ url: URL) {
        let u = url.standardizedFileURL
        for p in Self.filePresenters where p !== filePresenter {
            guard let presented = p.presentedItemURL?.standardizedFileURL else { continue }
            if presented == u {
                p.presentedItemOperationQueue.addOperation { p.presentedItemDidChange() }
            } else if u.path.hasPrefix(presented.path + "/") {
                p.presentedItemOperationQueue.addOperation { p.presentedSubitemDidChange(at: u) }
            }
        }
    }
}

open class NSFileAccessIntent: NSObject, @unchecked Sendable {
    public let url: URL
    init(url: URL) { self.url = url }
    open class func readingIntent(with url: URL, options: NSFileCoordinator.ReadingOptions = []) -> NSFileAccessIntent { NSFileAccessIntent(url: url) }
    open class func writingIntent(with url: URL, options: NSFileCoordinator.WritingOptions = []) -> NSFileAccessIntent { NSFileAccessIntent(url: url) }
}

// MARK: NSBackgroundActivityScheduler

/// Deferrable background work: runs on a timer at its interval.
open class NSBackgroundActivityScheduler: NSObject, @unchecked Sendable {
    public enum Result: Int, Sendable { case finished = 1, deferred = 2 }
    public typealias CompletionHandler = (Result) -> Void
    public let identifier: String
    open var qualityOfService: QualityOfService = .background
    open var repeats = false
    open var interval: TimeInterval = 0
    open var tolerance: TimeInterval = 0
    open var shouldDefer: Bool { false }
    private var timer: DispatchSourceTimer?

    public init(identifier: String) { self.identifier = identifier }
    open func schedule(_ block: @escaping @Sendable (@escaping CompletionHandler) -> Void) {
        invalidate()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let interval = max(self.interval, 1)
        t.schedule(deadline: .now() + interval, repeating: repeats ? interval : .infinity, leeway: .milliseconds(Int(tolerance * 1000)))
        t.setEventHandler { block { _ in } }
        timer = t
        t.resume()
    }
    open func invalidate() { timer?.cancel(); timer = nil }
}

// MARK: XPC

/// An interface: what a Mac checks messages against. Made from a protocol
/// (any value here, as there's no Objective-C `Protocol` off Apple's runtime).
open class NSXPCInterface: NSObject, @unchecked Sendable {
    public let protocolValue: Any
    public init(with protocol: Any) { protocolValue = `protocol` }
    open func setClasses(_ classes: Set<AnyHashable>, for selector: Any, argumentIndex arg: Int, ofReply: Bool) {}
    open func classes(for selector: Any, argumentIndex arg: Int, ofReply: Bool) -> Set<AnyHashable> { [] }
    open func setInterface(_ ifc: NSXPCInterface, for selector: Any, argumentIndex arg: Int, ofReply: Bool) {}
}

public enum NSXPCConnectionError {
    public static let interrupted = 4097
    public static let invalid = 4099
}

/// A connection to a Mach or XPC service. Linux has no launchd services to
/// look up, so a resumed connection invalidates: the remote proxy's error
/// handler gets NSXPCConnectionInvalid, then invalidationHandler runs, as a
/// Mac reports a service that isn't there.
open class NSXPCConnection: NSObject, @unchecked Sendable {
    public struct Options: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let privileged = Options(rawValue: 1 << 12)
    }
    public let serviceName: String?
    open var endpoint: NSXPCListenerEndpoint { NSXPCListenerEndpoint() }
    open var exportedInterface: NSXPCInterface?
    open var exportedObject: Any?
    open var remoteObjectInterface: NSXPCInterface?
    open var interruptionHandler: (() -> Void)?
    open var invalidationHandler: (() -> Void)?
    open var processIdentifier: Int32 { 0 }
    open var effectiveUserIdentifier: UInt32 { 0 }
    open var effectiveGroupIdentifier: UInt32 { 0 }
    open var auditSessionIdentifier: Int32 { 0 }
    private var invalidated = false
    private let lock = NSLock()

    public init(serviceName: String) { self.serviceName = serviceName }
    public init(machServiceName name: String, options: Options = []) { serviceName = name }
    public init(listenerEndpoint endpoint: NSXPCListenerEndpoint) { serviceName = nil }

    static var unavailableError: NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionError.invalid,
                userInfo: [NSDebugDescriptionErrorKey: "XPC services are not available on this platform"])
    }

    open func resume() {
        DispatchQueue.global().async { self.invalidate() }
    }
    open func activate() { resume() }
    open func suspend() {}
    open func invalidate() {
        let handler: (() -> Void)? = lock.withLock {
            guard !invalidated else { return nil }
            invalidated = true
            return invalidationHandler
        }
        handler?()
    }
    open func setCodeSigningRequirement(_ requirement: String) {}

    /// A proxy that can't be sent to: casting it to the remote protocol
    /// fails, and the error handler hears that the connection is invalid.
    open func remoteObjectProxyWithErrorHandler(_ handler: @escaping (Error) -> Void) -> Any {
        DispatchQueue.global().async { handler(Self.unavailableError) }
        return NSXPCUnavailableProxy()
    }
    open func synchronousRemoteObjectProxyWithErrorHandler(_ handler: @escaping (Error) -> Void) -> Any {
        handler(Self.unavailableError)
        return NSXPCUnavailableProxy()
    }
    open var remoteObjectProxy: Any { NSXPCUnavailableProxy() }
    open func scheduleSendBarrierBlock(_ block: @escaping () -> Void) { DispatchQueue.global().async(execute: block) }
    open class func current() -> NSXPCConnection? { nil }
}

/// What a connection's remote proxy is here: nothing answers.
public final class NSXPCUnavailableProxy: NSObject, @unchecked Sendable {}

open class NSXPCListenerEndpoint: NSObject, @unchecked Sendable {}

public protocol NSXPCListenerDelegate: AnyObject {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool
}

/// A service's listener: nothing connects to it here.
open class NSXPCListener: NSObject, @unchecked Sendable {
    open weak var delegate: NSXPCListenerDelegate?
    open var endpoint: NSXPCListenerEndpoint { NSXPCListenerEndpoint() }
    public init(machServiceName name: String) {}
    public override init() {}
    open class func service() -> NSXPCListener { NSXPCListener() }
    open class func anonymous() -> NSXPCListener { NSXPCListener() }
    open func resume() {}
    open func activate() {}
    open func suspend() {}
    open func invalidate() {}
    open func setConnectionCodeSigningRequirement(_ requirement: String) {}
}

// MARK: NSAppleScript

/// AppleScript has no interpreter off the Mac: compiling and running fail
/// with the error dictionary a Mac returns for a script that can't run.
open class NSAppleScript: NSObject, @unchecked Sendable {
    public static let errorMessage = "NSAppleScriptErrorMessage"
    public static let errorNumber = "NSAppleScriptErrorNumber"
    public static let errorAppName = "NSAppleScriptErrorAppName"
    public static let errorBriefMessage = "NSAppleScriptErrorBriefMessage"
    public static let errorRange = "NSAppleScriptErrorRange"
    public let source: String?
    open var isCompiled: Bool { false }

    public init?(source: String) { self.source = source }
    public init?(contentsOf url: URL, error errorInfo: AutoreleasingUnsafeMutablePointer<NSDictionary?>?) {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        source = s
    }
    static var unavailable: NSDictionary {
        [errorMessage: "AppleScript is not available on this platform.", errorNumber: -1750,
         errorBriefMessage: "AppleScript is not available."] as NSDictionary
    }
    open func compileAndReturnError(_ errorInfo: AutoreleasingUnsafeMutablePointer<NSDictionary?>?) -> Bool {
        errorInfo?.pointee = Self.unavailable
        return false
    }
    open func executeAndReturnError(_ errorInfo: AutoreleasingUnsafeMutablePointer<NSDictionary?>?) -> NSAppleEventDescriptor {
        errorInfo?.pointee = Self.unavailable
        return NSAppleEventDescriptor.null()
    }
    open func executeAppleEvent(_ event: NSAppleEventDescriptor, error errorInfo: AutoreleasingUnsafeMutablePointer<NSDictionary?>?) -> NSAppleEventDescriptor {
        errorInfo?.pointee = Self.unavailable
        return NSAppleEventDescriptor.null()
    }
}

// MARK: NSExtensionItem

open class NSExtensionItem: NSObject, @unchecked Sendable {
    open var attributedTitle: NSAttributedString?
    open var attributedContentText: NSAttributedString?
    open var attachments: [NSItemProvider]?
    open var userInfo: [AnyHashable: Any]?
    public override init() {}
}

open class NSExtensionContext: NSObject, @unchecked Sendable {
    open var inputItems: [Any] = []
    open func completeRequest(returningItems items: [Any]?, completionHandler: ((Bool) -> Void)? = nil) { completionHandler?(true) }
    open func cancelRequest(withError error: Error) {}
    open func open(_ url: URL, completionHandler: ((Bool) -> Void)? = nil) { completionHandler?(false) }
}
