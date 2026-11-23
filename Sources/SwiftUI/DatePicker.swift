// Date and time input using the host's editable text field.

import Foundation

public struct DatePicker<Label: View>: View {
    public struct Components: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static var date: Self { Self(rawValue: 1) }
        public static var hourAndMinute: Self { Self(rawValue: 2) }
    }

    private let label: Label
    private let selection: Binding<Date>
    private let components: Components
    private let minimum: Date?
    private let maximum: Date?

    @Environment(\._labelsHidden) private var labelsHidden
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @State private var text = ""

    private init(selection: Binding<Date>, displayedComponents: Components, minimum: Date?, maximum: Date?, @ViewBuilder label: () -> Label) {
        self.selection = selection
        components = displayedComponents
        self.minimum = minimum
        self.maximum = maximum
        self.label = label()
    }

    public init(selection: Binding<Date>, displayedComponents: Components = [.date, .hourAndMinute], @ViewBuilder label: () -> Label) {
        self.init(selection: selection, displayedComponents: displayedComponents, minimum: nil, maximum: nil, label: label)
    }

    private var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = components.contains(.date) ? .short : .none
        formatter.timeStyle = components.contains(.hourAndMinute) ? .short : .none
        return formatter
    }

    public var body: some View {
        let field = TextField(text: $text) { label }.onSubmit(commit)
            .onChange(of: selection.wrappedValue, initial: true) { _, date in text = formatter.string(from: date) }
        HStack {
            if !labelsHidden { label; Spacer(minLength: 8) }
            field
        }
    }

    private func commit() {
        let formatter = self.formatter
        if let parsed = formatter.date(from: text) {
            let date = selection.wrappedValue
            let units: Set<Calendar.Component> = if components.contains(.date) && components.contains(.hourAndMinute) {
                [.year, .month, .day, .hour, .minute]
            } else if components.contains(.date) {
                [.year, .month, .day]
            } else {
                [.hour, .minute]
            }
            var calendar = self.calendar
            calendar.timeZone = timeZone
            var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let parsedParts = calendar.dateComponents(units, from: parsed)
            for unit in units { parts.setValue(parsedParts.value(for: unit), for: unit) }
            if let updated = calendar.date(from: parts) {
                selection.wrappedValue = min(max(updated, minimum ?? updated), maximum ?? updated)
            }
        }
        text = formatter.string(from: selection.wrappedValue)
    }
}

extension DatePicker where Label == Text {
    public init(_ titleKey: LocalizedStringKey, selection: Binding<Date>, displayedComponents: Components = [.date, .hourAndMinute]) {
        self.init(selection: selection, displayedComponents: displayedComponents) { Text(titleKey) }
    }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, selection: Binding<Date>, displayedComponents: Components = [.date, .hourAndMinute]) {
        self.init(selection: selection, displayedComponents: displayedComponents) { Text(title) }
    }
    public init(_ titleKey: LocalizedStringKey, selection: Binding<Date>, in bounds: ClosedRange<Date>, displayedComponents: Components = [.date, .hourAndMinute]) {
        self.init(selection: selection, displayedComponents: displayedComponents, minimum: bounds.lowerBound, maximum: bounds.upperBound) { Text(titleKey) }
    }
    public init(_ titleKey: LocalizedStringKey, selection: Binding<Date>, in bounds: PartialRangeThrough<Date>, displayedComponents: Components = [.date, .hourAndMinute]) {
        self.init(selection: selection, displayedComponents: displayedComponents, minimum: nil, maximum: bounds.upperBound) { Text(titleKey) }
    }
    public init(_ titleKey: LocalizedStringKey, selection: Binding<Date>, in bounds: PartialRangeFrom<Date>, displayedComponents: Components = [.date, .hourAndMinute]) {
        self.init(selection: selection, displayedComponents: displayedComponents, minimum: bounds.lowerBound, maximum: nil) { Text(titleKey) }
    }
}
