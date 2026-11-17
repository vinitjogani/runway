// SwiftUI API the corpus apps use beyond the first slice: more shape and
// style spellings, text input traits, drag configuration, list editing.
// Where the platform has nothing to offer (autocorrection, drag previews)
// the modifier is accepted and leaves the view as it is.

import Foundation
import RunwayCore
import UniformTypeIdentifiers

// MARK: Shapes

/// The four corner radii of an uneven rounded rectangle.
public struct RectangleCornerRadii: Equatable, Sendable {
    public var topLeading: CGFloat
    public var bottomLeading: CGFloat
    public var bottomTrailing: CGFloat
    public var topTrailing: CGFloat
    public init(topLeading: CGFloat = 0, bottomLeading: CGFloat = 0, bottomTrailing: CGFloat = 0, topTrailing: CGFloat = 0) {
        self.topLeading = topLeading; self.bottomLeading = bottomLeading; self.bottomTrailing = bottomTrailing; self.topTrailing = topTrailing
    }
}

extension UnevenRoundedRectangle {
    public init(cornerRadii: RectangleCornerRadii, style: RoundedCornerStyle = .continuous) {
        self.init(topLeadingRadius: cornerRadii.topLeading, bottomLeadingRadius: cornerRadii.bottomLeading,
                  bottomTrailingRadius: cornerRadii.bottomTrailing, topTrailingRadius: cornerRadii.topTrailing, style: style)
    }
}

extension Shape where Self == UnevenRoundedRectangle {
    public static func rect(cornerRadii: RectangleCornerRadii, style: RoundedCornerStyle = .continuous) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(cornerRadii: cornerRadii, style: style)
    }
    public static func rect(topLeadingRadius: CGFloat = 0, bottomLeadingRadius: CGFloat = 0, bottomTrailingRadius: CGFloat = 0,
                            topTrailingRadius: CGFloat = 0, style: RoundedCornerStyle = .continuous) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: topLeadingRadius, bottomLeadingRadius: bottomLeadingRadius,
                               bottomTrailingRadius: bottomTrailingRadius, topTrailingRadius: topTrailingRadius, style: style)
    }
}

extension Shape where Self == RoundedRectangle {
    public static func rect(cornerSize: CGSize, style: RoundedCornerStyle = .continuous) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerSize.width, style: style)
    }
}

// MARK: Shape styles

/// `.fill`: the fill colour for shapes over content (a faint label colour),
/// with `.secondary`… levels fainter still.
public struct FillShapeStyle: ShapeStyle {
    var level = 0
    public init() {}
    public func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint {
        let alphas = [0.12, 0.08, 0.05, 0.03, 0.02]
        let dark = env.colorScheme == .dark
        return .color(dark ? RGBA(1, 1, 1, alphas[min(level, 4)] * 1.5) : RGBA(0, 0, 0, alphas[min(level, 4)]))
    }
    public var secondary: FillShapeStyle { var s = self; s.level = 1; return s }
    public var tertiary: FillShapeStyle { var s = self; s.level = 2; return s }
    public var quaternary: FillShapeStyle { var s = self; s.level = 3; return s }
    public var quinary: FillShapeStyle { var s = self; s.level = 4; return s }
}
extension ShapeStyle where Self == FillShapeStyle { public static var fill: FillShapeStyle { FillShapeStyle() } }

/// `.placeholder`: the colour of placeholder text.
public struct PlaceholderTextShapeStyle: ShapeStyle {
    public init() {}
    public func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint { .color(Color(.label(level: 2)).resolve(env)) }
}
extension ShapeStyle where Self == PlaceholderTextShapeStyle { public static var placeholder: PlaceholderTextShapeStyle { PlaceholderTextShapeStyle() } }

/// `.selection`: the selected-content background.
public struct SelectionShapeStyle: ShapeStyle {
    public init() {}
    public func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint { .color(Color.accentColor.resolve(env).multiplyingAlpha(0.35)) }
}
extension ShapeStyle where Self == SelectionShapeStyle { public static var selection: SelectionShapeStyle { SelectionShapeStyle() } }

/// `.link`: the colour of links.
public struct LinkShapeStyle: ShapeStyle {
    public init() {}
    public func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint { .color(Color.accentColor.resolve(env)) }
}
extension ShapeStyle where Self == LinkShapeStyle { public static var link: LinkShapeStyle { LinkShapeStyle() } }

/// `.windowBackground`.
public struct WindowBackgroundShapeStyle: ShapeStyle {
    public init() {}
    public func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint { .color(Color.windowBackground.resolve(env)) }
}
extension ShapeStyle where Self == WindowBackgroundShapeStyle { public static var windowBackground: WindowBackgroundShapeStyle { WindowBackgroundShapeStyle() } }

// MARK: Text input traits and help

extension View {
    /// The deprecated spelling of `autocorrectionDisabled(_:)` (no autocorrection here).
    public func disableAutocorrection(_ disable: Bool?) -> some View { self }
    public func help(_ textKey: LocalizedStringKey) -> some View { help(textKey.string) }
    public func textInputAutocapitalization(_ autocapitalization: Any?) -> some View { self }
    public func textSelectionAffinity(_ affinity: Any?) -> some View { self }
    public func writingToolsBehavior(_ behavior: Any?) -> some View { self }
    public func speechAdjustedPitch(_ value: Double) -> some View { self }
}

// MARK: Dragging (macOS 26)

/// How a drag behaves: which operations it allows within and outside the app.
public struct DragConfiguration: Sendable {
    public struct OperationsWithinApp: Sendable {
        public var allowCopy: Bool, allowMove: Bool, allowDelete: Bool
        public init(allowCopy: Bool = true, allowMove: Bool = false, allowDelete: Bool = false) {
            self.allowCopy = allowCopy; self.allowMove = allowMove; self.allowDelete = allowDelete
        }
    }
    public struct OperationsOutsideApp: Sendable {
        public var allowCopy: Bool, allowMove: Bool, allowDelete: Bool
        public init(allowCopy: Bool = true, allowMove: Bool = false, allowDelete: Bool = false) {
            self.allowCopy = allowCopy; self.allowMove = allowMove; self.allowDelete = allowDelete
        }
    }
    public var operationsWithinApp: OperationsWithinApp
    public var operationsOutsideApp: OperationsOutsideApp
    public var allowMove: Bool { operationsWithinApp.allowMove }
    public var allowDelete: Bool { operationsWithinApp.allowDelete }
    public init(operationsWithinApp: OperationsWithinApp = .init(), operationsOutsideApp: OperationsOutsideApp = .init()) {
        self.operationsWithinApp = operationsWithinApp; self.operationsOutsideApp = operationsOutsideApp
    }
    public init(allowMove: Bool, allowDelete: Bool = false) {
        self.init(operationsWithinApp: .init(allowCopy: true, allowMove: allowMove, allowDelete: allowDelete))
    }
}

extension View {
    /// The configuration of drags that start in this view (drags use the defaults here).
    public func dragConfiguration(_ configuration: DragConfiguration) -> some View { self }
    /// Drag and drop sessions aren't reported phase by phase here: the
    /// callbacks are kept and never called.
    public func onDragSessionUpdated(_ onUpdate: @escaping (DragSession) -> Void) -> some View { self }
    public func onDropSessionUpdated(_ onUpdate: @escaping (DropSession) -> Void) -> some View { self }
    public func dragPreviewsFormation(_ formation: Any) -> some View { self }
    /// Adjusts the transaction of changes below (changes aren't animated here).
    public func transaction(_ transform: @escaping (inout Transaction) -> Void) -> some View { self }
    public func transaction<V: Equatable>(value: V, _ transform: @escaping (inout Transaction) -> Void) -> some View { self }
}


/// A drag in progress (macOS 26).
public struct DragSession: Sendable {
    public enum Phase: Sendable {
        case initial, active, ended(DragDropOperation), dataTransferCompleted
    }
    public var phase: Phase = .initial
    public var id = UUID()
    public var draggedItemIDs: [AnyHashable] { [] }
}

/// A drop in progress over a view (macOS 26).
public struct DropSession: Sendable {
    public enum Phase: Sendable { case entering, active, exiting, ended(DragDropOperation), dataTransferCompleted }
    public var phase: Phase = .entering
    public var location: CGPoint = .zero
    public var size: CGSize = .zero
    public var suggestedOperations: [DragDropOperation] { [] }
}

public enum DragDropOperation: Sendable { case cancel, forbidden, copy, move, delete, alias }


// MARK: ControlGroup

/// Related controls shown as one unit: here, side by side with no gaps.
public struct ControlGroup<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public init<C: View, L: View>(@ViewBuilder content: () -> C, @ViewBuilder label: () -> L) where Content == C { self.content = content() }
    public init<C: View>(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> C) where Content == C { self.content = content() }
    @_disfavoredOverload public init<C: View, S: StringProtocol>(_ title: S, @ViewBuilder content: () -> C) where Content == C { self.content = content() }
    public init<C: View>(_ titleKey: LocalizedStringKey, systemImage: String, @ViewBuilder content: () -> C) where Content == C { self.content = content() }
    public var body: some View { HStack(spacing: 0) { content } }
}

extension View {
    /// Where a file dialog opens (the system's dialogs remember their own place).
    public func fileDialogMessage(_ messageKey: LocalizedStringKey) -> some View { self }
    public func fileDialogConfirmationLabel(_ labelKey: LocalizedStringKey) -> some View { self }
    public func fileDialogBrowserOptions(_ options: Any) -> some View { self }
    public func fileDialogURLEnabled(_ predicate: Any) -> some View { self }
}
