// iOS view APIs adapted to the desktop preview's controls and environment.

import Foundation
import UIKit

public enum DynamicTypeSize: Int, CaseIterable, Comparable, Sendable {
    case xSmall, small, medium, large, xLarge, xxLarge, xxxLarge
    case accessibility1, accessibility2, accessibility3, accessibility4, accessibility5

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var isAccessibilitySize: Bool { self >= .accessibility1 }

    // iOS and iPadOS Dynamic Type sizes from Apple's typography specifications.
    // https://developer.apple.com/design/human-interface-guidelines/typography
    func mobilePointSize(for style: Font.TextStyle) -> CGFloat {
        let sizes: [CGFloat] = switch style {
        case .largeTitle: [31, 32, 33, 34, 36, 38, 40, 44, 48, 52, 56, 60]
        case .title: [25, 26, 27, 28, 30, 32, 34, 38, 43, 48, 53, 58]
        case .title2: [19, 20, 21, 22, 24, 26, 28, 34, 39, 44, 50, 56]
        case .title3: [17, 18, 19, 20, 22, 24, 26, 31, 37, 43, 49, 55]
        case .headline, .body: [14, 15, 16, 17, 19, 21, 23, 28, 33, 40, 47, 53]
        case .callout: [13, 14, 15, 16, 18, 20, 22, 26, 32, 38, 44, 51]
        case .subheadline: [12, 13, 14, 15, 17, 19, 21, 25, 30, 36, 42, 49]
        case .footnote: [12, 12, 12, 13, 15, 17, 19, 23, 27, 33, 38, 44]
        case .caption: [11, 11, 11, 12, 14, 16, 18, 22, 26, 32, 37, 43]
        case .caption2: [11, 11, 11, 11, 13, 15, 17, 20, 24, 29, 34, 40]
        }
        return sizes[rawValue]
    }

    func mobileScale(for style: Font.TextStyle) -> CGFloat {
        mobilePointSize(for: style) / Self.large.mobilePointSize(for: style)
    }
}

private struct DynamicTypeSizeKey: EnvironmentKey { static var defaultValue: DynamicTypeSize { .large } }
private struct MobilePreviewKey: EnvironmentKey { static let defaultValue = false }
private struct MobileSystemFontFamilyKey: EnvironmentKey { static let defaultValue: String? = nil }

extension EnvironmentValues {
    var _mobilePreview: Bool {
        get { self[MobilePreviewKey.self] }
        set { self[MobilePreviewKey.self] = newValue }
    }

    var _mobileSystemFontFamily: String? {
        get { self[MobileSystemFontFamilyKey.self] }
        set { self[MobileSystemFontFamilyKey.self] = newValue }
    }

    public var dynamicTypeSize: DynamicTypeSize {
        get { self[DynamicTypeSizeKey.self] }
        set { self[DynamicTypeSizeKey.self] = newValue }
    }
}

@propertyWrapper
public struct ScaledMetric<Value: BinaryFloatingPoint>: DynamicProperty {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let value: Value
    private let textStyle: Font.TextStyle

    public init(wrappedValue: Value, relativeTo textStyle: Font.TextStyle = .body) {
        value = wrappedValue
        self.textStyle = textStyle
    }

    public var wrappedValue: Value { value * Value(dynamicTypeSize.mobileScale(for: textStyle)) }
}

public enum TextInputAutocapitalization: Sendable { case never, words, sentences, characters }
public enum ScrollDismissesKeyboardMode: Sendable { case automatic, immediately, interactively, never }
public enum PresentationAdaptation: Sendable { case automatic, none, popover, sheet, fullScreenCover }

public struct PresentationDetent: Hashable, Sendable {
    private enum Value: Hashable, Sendable { case medium, large, fraction(CGFloat), height(CGFloat) }
    private let value: Value
    public static let medium = Self(value: .medium)
    public static let large = Self(value: .large)
    public static func fraction(_ value: CGFloat) -> Self { Self(value: .fraction(value)) }
    public static func height(_ value: CGFloat) -> Self { Self(value: .height(value)) }
}

public enum SensoryFeedback: Sendable { case selection, success, warning, error, increase, decrease, start, stop }

public enum ListSectionSpacing: Sendable {
    case `default`, compact, custom(CGFloat)

    var spacing: CGFloat {
        switch self {
        case .default: 0
        case .compact: 6
        case .custom(let spacing): spacing
        }
    }
}

private struct ListSectionSpacingKey: EnvironmentKey { static var defaultValue: ListSectionSpacing { .default } }

extension EnvironmentValues {
    var _listSectionSpacing: ListSectionSpacing {
        get { self[ListSectionSpacingKey.self] }
        set { self[ListSectionSpacingKey.self] = newValue }
    }
}

public struct RefreshAction: Sendable {
    let action: @Sendable () async -> Void
    public func callAsFunction() async { await action() }
}

private struct RefreshKey: EnvironmentKey { static var defaultValue: RefreshAction? { nil } }

extension EnvironmentValues {
    public var refresh: RefreshAction? { self[RefreshKey.self] }
}

extension View {
    public func dynamicTypeSize(_ size: DynamicTypeSize) -> some View { environment(\.dynamicTypeSize, size) }
    public func dynamicTypeSize<R: RangeExpression>(_ range: R) -> some View where R.Bound == DynamicTypeSize {
        environment { env in
            let sizes = DynamicTypeSize.allCases.filter(range.contains)
            if let first = sizes.first, let last = sizes.last {
                env.dynamicTypeSize = min(max(env.dynamicTypeSize, first), last)
            }
        }
    }

    // These traits target iOS-only input or feedback services.
    public func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> some View { self }
    public func textContentType(_ type: UITextContentType?) -> some View { self }
    public func keyboardType(_ type: UIKeyboardType) -> some View { self }
    public func scrollDismissesKeyboard(_ mode: ScrollDismissesKeyboardMode) -> some View { self }
    public func sensoryFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T, condition: ((T, T) -> Bool)? = nil) -> some View { self }

    public func listSectionSpacing(_ spacing: ListSectionSpacing) -> some View { environment { $0._listSectionSpacing = spacing } }

    public func refreshable(action: @escaping @Sendable () async -> Void) -> some View {
        environment { $0[RefreshKey.self] = RefreshAction(action: action) }
    }

    public func presentationCompactAdaptation(_ adaptation: PresentationAdaptation) -> some View { self }
    public func presentationDetents(_ detents: Set<PresentationDetent>) -> some View { self }

    /// Desktop previews present a cover in the same modal window as a sheet.
    public func fullScreenCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                               @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }

    /// Use an overflow menu for row actions in previews with a pointer.
    public func swipeActions<Actions: View>(edge: HorizontalEdge = .trailing, allowsFullSwipe: Bool = true,
                                            @ViewBuilder content: () -> Actions) -> some View {
        let actions = content()
        let menu = Menu { actions } label: { Image(systemName: "ellipsis").accessibilityLabel("Row actions") }
        return HStack(spacing: 8) {
            if edge == .leading { menu }
            self
            if edge == .trailing { menu }
        }
    }
}

extension View where Self: Equatable {
    public func equatable() -> some View { self }
}
