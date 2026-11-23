@_exported import Foundation

public class BGTask: NSObject {
    public let identifier: String
    public var expirationHandler: (() -> Void)?

    fileprivate init(identifier: String) { self.identifier = identifier }

    public func setTaskCompleted(success: Bool) {}
}

public final class BGAppRefreshTask: BGTask {}

public class BGTaskRequest: NSObject {
    public let identifier: String
    public var earliestBeginDate: Date?

    fileprivate init(identifier: String) { self.identifier = identifier }
}

public final class BGAppRefreshTaskRequest: BGTaskRequest {
    public override init(identifier: String) { super.init(identifier: identifier) }
}

/// A Runway app has no iOS process scheduler. Report the service as unavailable
/// so callers can use their normal fallback or skip background work.
public final class BGTaskScheduler: Sendable {
    public static let shared = BGTaskScheduler()

    private init() {}

    public struct Error: CustomNSError, LocalizedError, Sendable {
        public enum Code: Int, Sendable {
            case unavailable = 1
            case tooManyPendingTaskRequests = 2
            case notPermitted = 3
        }

        public static var unavailable: Code { .unavailable }
        public static var tooManyPendingTaskRequests: Code { .tooManyPendingTaskRequests }
        public static var notPermitted: Code { .notPermitted }
        public static var errorDomain: String { "BGTaskSchedulerErrorDomain" }
        public let code: Code
        public var errorCode: Int { code.rawValue }

        public init(_ code: Code) { self.code = code }

        public var errorDescription: String? {
            switch code {
            case .unavailable: return "Background scheduling is unavailable in the Runway preview."
            case .tooManyPendingTaskRequests: return "Too many background task requests are pending."
            case .notPermitted: return "The app is not permitted to schedule this background task."
            }
        }
    }

    @discardableResult
    public func register(forTaskWithIdentifier identifier: String, using queue: DispatchQueue?,
                         launchHandler: @escaping (BGTask) -> Void) -> Bool { false }

    public func submit(_ taskRequest: BGTaskRequest) throws { throw Error(.unavailable) }
    public func cancel(taskRequestWithIdentifier identifier: String) {}
    public func cancelAllTaskRequests() {}

    public func getPendingTaskRequests(completionHandler: @escaping @Sendable ([BGTaskRequest]) -> Void) {
        DispatchQueue.global().async { completionHandler([]) }
    }

    public func pendingTaskRequests() async -> [BGTaskRequest] { [] }
}
