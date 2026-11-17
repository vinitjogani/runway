import XCTest
import AppIntents
import Intents
import RunwayFoundation

// Shapes taken from real apps' intents (Maccy, Gifski), so the surface
// keeps compiling what they declare.

private enum Mode: String, AppEnum, CaseIterable, Codable, Hashable {
    case aspectRatio, exact
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Crop Mode"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.aspectRatio: "a fixed aspect ratio", .exact: "exact dimensions"]
}

private struct SelectItem: AppIntent, CustomIntentMigratedAppIntent {
    static let intentClassName = "SelectIntent"
    static let title: LocalizedStringResource = "Select Item"
    static let description = IntentDescription("Selects an item.")

    static var parameterSummary: some ParameterSummary {
        Summary("Select \(\.$number) Item")
    }

    @Parameter(title: "Number", default: 1, requestValueDialog: "Which one?")
    var number: Int

    @Parameter(title: "Selected", default: true)
    var selected: Bool

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: "item \(number)")
    }
}

private struct Crop: AppIntent {
    static let title: LocalizedStringResource = "Crop"
    static var parameterSummary: some ParameterSummary {
        Switch(\.$mode) {
            Case(.exact) {
                Summary("Crop \(\.$mode): \(\.$width)") {
                    \.$width
                    \.$quality
                }
            }
            DefaultCase {
                Summary("Crop \(\.$mode)")
            }
        }
    }
    @Parameter(description: "Mode", default: .aspectRatio)
    var mode: Mode
    @Parameter(title: "Width", default: 1, inclusiveRange: (1, 100_000))
    var width: Int
    @Parameter(default: 1, controlStyle: .slider, inclusiveRange: (0, 1))
    var quality: Double
    @Parameter(description: "Rate", inclusiveRange: (3, 50))
    var frameRate: Int?

    func perform() async throws -> some IntentResult {
        .result()
    }
}

private struct Conditional: AppIntent {
    static let title: LocalizedStringResource = "Get"
    @Parameter(title: "Selected", default: true)
    var selected: Bool
    @Parameter(title: "Number", default: 1)
    var number: Int
    static var parameterSummary: some ParameterSummary {
        When(\.$selected, .equalTo, false) {
            Summary {
                \.$number
                \.$selected
            }
        } otherwise: {
            Summary {
                \.$selected
            }
        }
    }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "Done \(number)")
    }
}

private struct Item: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Item")
    @Property(title: "Text")
    var text: String?
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Item") }
}

final class AppIntentsTests: XCTestCase {
    func testIntentsRunInProcess() async throws {
        var intent = SelectItem()
        XCTAssertEqual(intent.number, 1)
        intent.number = 4
        let result = try await intent.perform()
        XCTAssertEqual((result as? _IntentResult<String>)?.value, "item 4")
        let crop = Crop()
        XCTAssertNil(crop.frameRate)
        XCTAssertEqual(crop.mode, .aspectRatio)
        _ = try await Conditional().perform()
        let item = Item()
        item.text = "hello"
        XCTAssertEqual(item.text, "hello")
    }

    func testSiriIsUnavailable() {
        XCTAssertEqual(INPreferences.siriAuthorizationStatus(), .denied)
        let c = INObjectCollection(items: [INObject(identifier: "a", display: "A")])
        XCTAssertEqual(c.allItems.count, 1)
    }
}
