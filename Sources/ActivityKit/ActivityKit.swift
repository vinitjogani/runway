@_exported import Foundation

public protocol ActivityAttributes: Codable {
    associatedtype ContentState: Codable & Hashable
}

public struct ActivityContent<State: Codable & Hashable> {
    public let state: State
    public let staleDate: Date?
    public let relevanceScore: Double

    public init(state: State, staleDate: Date?, relevanceScore: Double = 0) {
        self.state = state
        self.staleDate = staleDate
        self.relevanceScore = relevanceScore
    }
}

extension ActivityContent: Sendable where State: Sendable {}

public enum ActivityState: Codable, Hashable, Sendable {
    case active, dismissed, ended, pending, stale
}

public struct ActivityUIDismissalPolicy: Equatable, Sendable {
    private enum Timing: Equatable, Sendable {
        case systemDefault, immediate, after(Date)
    }

    private let timing: Timing

    public static let `default` = Self(timing: .systemDefault)
    public static let immediate = Self(timing: .immediate)

    public static func after(_ date: Date) -> Self { Self(timing: .after(date)) }
}

public struct PushType: Equatable {
    private init() {}
    public static var token: Self { Self() }
}

public enum ActivityAuthorizationError: LocalizedError {
    case unsupported

    public var errorDescription: String? { "Live Activities are unavailable in the Runway preview." }
    public var failureReason: String? { errorDescription }
}

public final class ActivityAuthorizationInfo {
    public init() {}
    public var areActivitiesEnabled: Bool { false }
}

/// Runway has no Live Activity host. Apps can render their own content and use
/// the same fallback they use when Live Activities are disabled on the device.
public final class Activity<Attributes: ActivityAttributes>: Identifiable {
    public typealias ContentState = Attributes.ContentState

    public static var activities: [Activity<Attributes>] { [] }

    public let id: String
    public let attributes: Attributes
    public let content: ActivityContent<ContentState>
    public var activityState: ActivityState { .ended }

    private init(id: String, attributes: Attributes, content: ActivityContent<ContentState>) {
        self.id = id
        self.attributes = attributes
        self.content = content
    }

    public static func request(attributes: Attributes, content: ActivityContent<ContentState>,
                               pushType: PushType? = nil) throws -> Activity<Attributes> {
        throw ActivityAuthorizationError.unsupported
    }

    public func update(_ content: ActivityContent<ContentState>) async {}

    public func end(_ content: ActivityContent<ContentState>?,
                    dismissalPolicy: ActivityUIDismissalPolicy = .default) async {}
}
