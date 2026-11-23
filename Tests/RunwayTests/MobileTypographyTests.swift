import XCTest
import RunwayCore
@testable import SwiftUI

@MainActor
final class MobileTypographyTests: XCTestCase {
    func testSystemFamilyConfigurationUsesInstalledFamilies() {
        let configuration = MobileSystemFont(environment: [
            "RUNWAY_IOS_SYSTEM_FONT": "  Example UI  ",
            "RUNWAY_IOS_SYSTEM_FONT_FILES": "/tmp/Example Regular.ttf:/tmp/Example Italic.ttf",
            "RUNWAY_NATIVE_FONT": "1",
        ])
        XCTAssertEqual(configuration.files.map(\.lastPathComponent), ["Example Regular.ttf", "Example Italic.ttf"])
        XCTAssertEqual(configuration.select(from: ["Open Sans", "EXAMPLE UI"]), "EXAMPLE UI")
        XCTAssertEqual(configuration.select(from: ["Noto Sans", "Open Sans"]), "Open Sans")
        XCTAssertNil(MobileSystemFont(environment: ["RUNWAY_NATIVE_FONT": "1"]).select(from: ["Open Sans"]))
    }

    func testMobileSystemFamilyPreservesWeightItalicAndExplicitFontDesign() {
        var phone = MobilePreviewProfile.iphone.environment
        phone._mobileSystemFontFamily = "Example UI"
        let system = Font.headline.weight(.medium).italic().resolved(in: phone)
        XCTAssertEqual(system.family, "Example UI")
        XCTAssertEqual(system.size, 17)
        XCTAssertEqual(system.weight, .medium)
        XCTAssertTrue(system.italic)

        let display = Font.custom("Instrument Serif", size: 52).resolved(in: phone)
        XCTAssertEqual(display.family, "Instrument Serif")
        XCTAssertEqual(display.size, 52)
        XCTAssertNil(Font.system(.title2, design: .serif).resolved(in: phone).family)
        XCTAssertNil(Font.system(.title2, design: .monospaced).resolved(in: phone).family)
        XCTAssertNil(Font.title2.resolved(in: EnvironmentValues()).family)
    }

    func testSystemTextStylesUseMobileMetricsAndKeepExplicitWeight() {
        var phone = MobilePreviewProfile.iphone.environment
        let desktop = EnvironmentValues()
        XCTAssertEqual(Font.title2.resolved(in: desktop).size, 17)
        XCTAssertEqual(Font.title2.resolved(in: phone).size, 22)
        XCTAssertEqual(Font.headline.resolved(in: phone).weight, .semibold)
        XCTAssertEqual(Font.headline.weight(.bold).resolved(in: phone).weight, .bold)

        phone.dynamicTypeSize = .accessibility3
        XCTAssertEqual(Font.title2.resolved(in: phone).size, 44)
        XCTAssertEqual(Font.body.resolved(in: phone).size, 40)
        XCTAssertEqual(Font.system(size: 22).resolved(in: phone).size, 22)
    }

    func testCustomFontsAndScaledMetricsFollowTheRequestedTextStyle() {
        var phone = MobilePreviewProfile.iphone.environment
        phone.dynamicTypeSize = .accessibility3
        let relative = Font.custom("Example Serif", size: 26, relativeTo: .title2).resolved(in: phone)
        XCTAssertEqual(relative.family, "Example Serif")
        XCTAssertEqual(relative.size, 52)
        XCTAssertEqual(Font.custom("Example Serif", fixedSize: 26).resolved(in: phone).size, 26)

        let host = ViewHost(ScaledLabel(), backend: HeadlessBackend(), environment: phone)
        host.setSize(CGSize(width: 393, height: 852))
        host.render()
        let widget = (host.container as! HeadlessWidget).all.first { $0.kind == .text }
        XCTAssertEqual(widget?.props.text?.runs.first?.font.size, 44)
    }

    func testLabelTextCaseUsesLocaleAndExplicitFontTakesPrecedence() {
        var phone = MobilePreviewProfile.iphone.environment
        phone.font = .caption
        phone.locale = Locale(identifier: "tr_TR")
        phone.textCase = .uppercase
        phone._fontWeight = .bold
        let label = Text("isim").font(.title2).fontWeight(.medium).tracking(1.5)
        let run = label.styled(phone).runs.first
        XCTAssertEqual(run?.string, "İSİM")
        XCTAssertEqual(run?.font.size, 22)
        XCTAssertEqual(run?.font.weight, .medium)
        XCTAssertEqual(run?.tracking, 1.5)
    }

    private struct ScaledLabel: View {
        @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 22
        var body: some View { Text("Metric heading").font(.system(size: size)) }
    }
}
