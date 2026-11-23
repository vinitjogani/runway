import Foundation

package struct MobileSystemFont {
    // Order chosen from GTK measurements of iOS preview labels using
    // readily available fonts. The toolkit can still supply other glyphs.
    package static let portableFamilies = ["Open Sans", "Noto Sans Display", "Noto Sans", "Liberation Sans"]

    package let requestedFamily: String?
    package let files: [URL]
    package let useToolkitFont: Bool

    package init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let name = environment["RUNWAY_IOS_SYSTEM_FONT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        requestedFamily = name.flatMap { name in
            name.isEmpty || name.contains(",") || name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? nil : name
        }
        files = (environment["RUNWAY_IOS_SYSTEM_FONT_FILES"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0)).standardizedFileURL
        }
        useToolkitFont = requestedFamily == nil && environment["RUNWAY_NATIVE_FONT"] != nil
    }

    package var candidates: [String] {
        guard !useToolkitFont else { return [] }
        return (requestedFamily.map { [$0] } ?? []) + Self.portableFamilies
    }

    package func select(from installed: [String]) -> String? {
        for candidate in candidates {
            if let family = installed.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return family
            }
        }
        return nil
    }
}
