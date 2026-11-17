// WidgetKit for Linux and Windows. There's no widget host, so an app's
// WidgetCenter calls are no-ops (no configurations are installed), and a
// widget extension's declarations (Widget, WidgetBundle, StaticConfiguration,
// TimelineProvider…) compile; Runway doesn't run them. The view modifier
// containerBackground(_:for:) is here until Runway's SwiftUI provides it.

@_exported import SwiftUI
import Foundation

public enum WidgetFamily: Int, CaseIterable, Hashable, Sendable, CustomDebugStringConvertible {
    case systemSmall, systemMedium, systemLarge, systemExtraLarge, accessoryCorner, accessoryCircular, accessoryRectangular, accessoryInline
    public var debugDescription: String { "\(self)" }
}

public struct WidgetInfo: Sendable {
    public let kind: String
    public let family: WidgetFamily
}

public final class WidgetCenter: @unchecked Sendable {
    public static let shared = WidgetCenter()
    public func reloadAllTimelines() {}
    public func reloadTimelines(ofKind kind: String) {}
    public func invalidateConfigurationRecommendations() {}
    public func getCurrentConfigurations(_ completion: @escaping @Sendable (Result<[WidgetInfo], Error>) -> Void) {
        DispatchQueue.main.async { completion(.success([])) }
    }
    public func currentConfigurations() async throws -> [WidgetInfo] { [] }
}

public protocol TimelineEntry {
    var date: Date { get }
    var relevance: TimelineEntryRelevance? { get }
}
extension TimelineEntry {
    public var relevance: TimelineEntryRelevance? { nil }
}

public struct TimelineEntryRelevance: Sendable {
    public let score: Float
    public let duration: TimeInterval
    public init(score: Float, duration: TimeInterval = 0) { self.score = score; self.duration = duration }
}

public struct TimelineReloadPolicy: Equatable, Sendable {
    let kind: Int
    let date: Date?
    public static let atEnd = TimelineReloadPolicy(kind: 0, date: nil)
    public static let never = TimelineReloadPolicy(kind: 1, date: nil)
    public static func after(_ date: Date) -> TimelineReloadPolicy { TimelineReloadPolicy(kind: 2, date: date) }
}

public struct Timeline<EntryType: TimelineEntry> {
    public let entries: [EntryType]
    public let policy: TimelineReloadPolicy
    public init(entries: [EntryType], policy: TimelineReloadPolicy) { self.entries = entries; self.policy = policy }
}

public struct TimelineProviderContext: Sendable {
    public var family: WidgetFamily { .systemMedium }
    public var isPreview: Bool { false }
    public var displaySize: CGSize { CGSize(width: 329, height: 155) }
}

public protocol TimelineProvider {
    associatedtype Entry: TimelineEntry
    typealias Context = TimelineProviderContext
    func placeholder(in context: Context) -> Entry
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void)
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void)
}

public protocol WidgetConfiguration {
    associatedtype Body: WidgetConfiguration
    var body: Body { get }
}

extension Never: WidgetConfiguration {}
extension WidgetConfiguration where Body == Never {
    public var body: Never { fatalError() }
}

public struct StaticConfiguration<Content: View>: WidgetConfiguration {
    public typealias Body = Never
    public let kind: String
    let content: Any
    public init<Provider: TimelineProvider>(kind: String, provider: Provider, @ViewBuilder content: @escaping (Provider.Entry) -> Content) {
        self.kind = kind
        self.content = content
    }
}

public struct ModifiedWidgetConfiguration<Base: WidgetConfiguration>: WidgetConfiguration {
    public typealias Body = Never
    let base: Base
}

extension WidgetConfiguration {
    public func configurationDisplayName(_ displayName: String) -> some WidgetConfiguration { ModifiedWidgetConfiguration(base: self) }
    public func configurationDisplayName(_ displayName: Text) -> some WidgetConfiguration { ModifiedWidgetConfiguration(base: self) }
    public func description(_ description: String) -> some WidgetConfiguration { ModifiedWidgetConfiguration(base: self) }
    public func description(_ description: Text) -> some WidgetConfiguration { ModifiedWidgetConfiguration(base: self) }
    public func supportedFamilies(_ families: [WidgetFamily]) -> some WidgetConfiguration { ModifiedWidgetConfiguration(base: self) }
    public func contentMarginsDisabled() -> some WidgetConfiguration { ModifiedWidgetConfiguration(base: self) }
    public func disfavoredLocations(_ locations: [Any], for families: [WidgetFamily]) -> some WidgetConfiguration { ModifiedWidgetConfiguration(base: self) }
}

public protocol Widget {
    associatedtype Body: WidgetConfiguration
    init()
    var body: Body { get }
}

public protocol WidgetBundle {
    associatedtype Body: Widget
    init()
    var body: Body { get }
}

public struct _WidgetGroup: Widget {
    public init() {}
    public var body: EmptyWidgetConfiguration { EmptyWidgetConfiguration() }
}

public struct EmptyWidgetConfiguration: WidgetConfiguration {
    public typealias Body = Never
    public init() {}
}

@resultBuilder
public enum WidgetBundleBuilder {
    public static func buildBlock() -> _WidgetGroup { _WidgetGroup() }
    public static func buildBlock<each W: Widget>(_ widgets: repeat each W) -> _WidgetGroup { _WidgetGroup() }
    public static func buildOptional<W: Widget>(_ w: W?) -> _WidgetGroup { _WidgetGroup() }
    public static func buildEither<W: Widget>(first: W) -> _WidgetGroup { _WidgetGroup() }
    public static func buildEither<W: Widget>(second: W) -> _WidgetGroup { _WidgetGroup() }
    public static func buildLimitedAvailability<W: Widget>(_ w: W) -> _WidgetGroup { _WidgetGroup() }
}

public struct ContainerBackgroundPlacement: Hashable, Sendable {
    let name: String
    public static let widget = ContainerBackgroundPlacement(name: "widget")
    public static let navigation = ContainerBackgroundPlacement(name: "navigation")
}

extension View {
    /// Widgets' background; in an app window the view draws as is.
    public func containerBackground<S: ShapeStyle>(_ style: S, for container: ContainerBackgroundPlacement) -> some View { self }
    public func containerBackground<V: View>(for container: ContainerBackgroundPlacement, alignment: Alignment = .center,
                                             @ViewBuilder content: () -> V) -> some View { self }
    public func widgetURL(_ url: URL?) -> some View { self }
    public func widgetAccentable(_ accentable: Bool = true) -> some View { self }
}

public struct WidgetRenderingMode: Hashable, Sendable {
    let name: String
    public static let fullColor = WidgetRenderingMode(name: "fullColor")
    public static let accented = WidgetRenderingMode(name: "accented")
    public static let vibrant = WidgetRenderingMode(name: "vibrant")
}
