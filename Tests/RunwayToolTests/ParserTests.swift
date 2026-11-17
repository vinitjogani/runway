// The importers' parsers: OpenStep property lists (project.pbxproj),
// xcconfig files and build-setting evaluation, the JSON project format's
// trailing commas, and the YAML subset XcodeGen specs use.

import Foundation
import XCTest
@testable import RunwayImport

final class OpenStepPlistTests: XCTestCase {
    func testDictionariesArraysAndComments() throws {
        let text = """
        // !$*UTF8*$!
        {
            archiveVersion = 1;
            /* a block
               comment */
            objects = {
                A1B2 /* Foo.swift */ = {isa = PBXFileReference; path = "Foo Bar.swift"; sourceTree = "<group>"; };
            };
            list = (a, "b c", d/e.f, "$(SRCROOT)/x", );
            empty = ();
            emptyDict = {};
        }
        """
        let v = try OpenStepPlist.parse(text)
        XCTAssertEqual(v["archiveVersion"]?.string, "1")
        XCTAssertEqual(v["objects"]?["A1B2"]?["path"]?.string, "Foo Bar.swift")
        XCTAssertEqual(v["objects"]?["A1B2"]?["sourceTree"]?.string, "<group>")
        XCTAssertEqual(v["list"]?.strings, ["a", "b c", "d/e.f", "$(SRCROOT)/x"])
        XCTAssertEqual(v["empty"], .array([]))
        XCTAssertEqual(v["emptyDict"], .dict([:]))
    }

    func testStringEscapes() throws {
        let v = try OpenStepPlist.parse(#"{ a = "line\nnext\t\"q\" \\ \U00e9\U00A9"; b = "\UD83D\UDE00"; c = "\101\102"; d = 'single'; }"#)
        XCTAssertEqual(v["a"]?.string, "line\nnext\t\"q\" \\ é©")
        XCTAssertEqual(v["b"]?.string, "😀")
        XCTAssertEqual(v["c"]?.string, "AB")
        XCTAssertEqual(v["d"]?.string, "single")
    }

    func testDataAndUnicodeBareStrings() throws {
        let v = try OpenStepPlist.parse("{ data = <48656c 6c6f>; name = Café; }")
        XCTAssertEqual(v["data"], .data(Data("Hello".utf8)))
        XCTAssertEqual(v["name"]?.string, "Café")
    }

    func testErrorsCarryTheLine() {
        XCTAssertThrowsError(try OpenStepPlist.parse("{\n a = b;\n c = ;\n}")) { e in
            XCTAssertEqual((e as? PlistParseError)?.line, 3)
        }
        XCTAssertThrowsError(try OpenStepPlist.parse("{ a = \"unterminated; }"))
        XCTAssertThrowsError(try OpenStepPlist.parse("{ a = b }  extra"))
    }

    func testFoundationValues() throws {
        let v = try OpenStepPlist.parse("{ k = (1, {x = y;}); }")
        let f = v.foundation as? [String: Any]
        XCTAssertEqual((f?["k"] as? [Any])?.first as? String, "1")
    }
}

final class BuildSettingsTests: XCTestCase {
    func testConditionalKeys() {
        let a = SettingAssignment(rawKey: "OTHER_SWIFT_FLAGS[config=Debug][sdk=macosx*]", value: "-DX")
        XCTAssertEqual(a.key, "OTHER_SWIFT_FLAGS")
        XCTAssertEqual(a.conditions, ["config": "Debug", "sdk": "macosx*"])
        var ctx = SettingContext(configuration: "Debug")
        XCTAssertTrue(ctx.matches(a.conditions))
        ctx.configuration = "Release"
        XCTAssertFalse(ctx.matches(a.conditions))
        XCTAssertTrue(globMatch("macosx*", "macosx14.0"))
        XCTAssertFalse(globMatch("iphone*", "macosx"))
    }

    func testInheritedAndReferences() {
        let stack: [SettingAssignment] = [
            .init(key: "TARGET_NAME", value: "My App"),
            .init(key: "PRODUCT_NAME", value: "$(TARGET_NAME)"),
            .init(key: "DEFS", value: "A"),
            .init(key: "DEFS", value: "$(inherited) B"),
            .init(key: "DEFS", conditions: ["config": "Debug"], value: "$(inherited) DEBUG"),
            .init(key: "ID", value: "com.example.$(PRODUCT_NAME:rfc1034identifier)"),
            .init(key: "MODULE", value: "${PRODUCT_NAME:c99extidentifier}"),
            .init(key: "LOOP", value: "$(LOOP) x"),
            .init(key: "NESTED", value: "$($(INNER))"),
            .init(key: "INNER", value: "TARGET_NAME"),
        ]
        let debug = BuildSettings(stack: stack, context: SettingContext(configuration: "Debug"))
        let release = BuildSettings(stack: stack, context: SettingContext(configuration: "Release"))
        XCTAssertEqual(debug["DEFS"], "A B DEBUG")
        XCTAssertEqual(release["DEFS"], "A B")
        XCTAssertEqual(release["ID"], "com.example.My-App")
        XCTAssertEqual(release["MODULE"], "My_App")
        XCTAssertEqual(release["LOOP"], "x")  // a cycle expands to nothing, not forever
        XCTAssertEqual(release["NESTED"], "My App")
        XCTAssertNil(release["UNSET"])
        XCTAssertEqual(release.list("DEFS"), ["A", "B"])
    }

    func testXCConfigIncludesAndComments() throws {
        let dir = fixtures.appendingPathComponent("GroupsApp/Config")
        var missing: [String] = []
        let a = XCConfig.parse(dir.appendingPathComponent("Base.xcconfig"), missing: &missing)
        XCTAssertTrue(missing.isEmpty, "#include? of a missing file is fine: \(missing)")
        let s = BuildSettings(stack: a, context: SettingContext(configuration: "Debug"))
        XCTAssertEqual(s["VERSION"], "2.1")
        XCTAssertEqual(s["BUNDLE_PREFIX"], "com.example")  // the // comment is dropped
        XCTAssertEqual(s["SWIFT_ACTIVE_COMPILATION_CONDITIONS"], "DEBUG_EXTRA")
        var missing2: [String] = []
        _ = XCConfig.parse(text: "#include \"Nope.xcconfig\"\nA = 1", base: dir, missing: &missing2)
        XCTAssertEqual(missing2.count, 1)
    }

    func testListSplitting() {
        XCTAssertEqual(splitSettingList(#"-D A "-D" "B C" 'd e' f\ g"#), ["-D", "A", "-D", "B C", "d e", "f g"])
        XCTAssertEqual(splitSettingList("  "), [])
    }

    func testPlistArraysJoinAsLists() {
        XCTAssertEqual(settingString(.array([.string("$(inherited)"), .string("-D"), .string("Two Words")])), #"$(inherited) -D "Two Words""#)
    }

    func testVersionsAndNames() {
        XCTAssertEqual(nextVersion("1.2.3", major: true), "2.0.0")
        XCTAssertEqual(nextVersion("1.2.3", major: false), "1.3.0")
        XCTAssertEqual(nextVersion("0.9", major: true), "1.0.0")
        XCTAssertEqual(c99Name("Hidden Bar"), "Hidden_Bar")
        XCTAssertEqual(c99Name("1Password-Mini"), "_1Password_Mini")
        XCTAssertEqual(c99Name("eu.exelban.Stats.SMC.Helper"), "eu_exelban_Stats_SMC_Helper")
        XCTAssertEqual(packageIdentity("https://github.com/groue/GRDB.swift.git"), "grdb.swift")
        XCTAssertEqual(packageIdentity("git@github.com:soffes/HotKey/"), "hotkey")
    }
}

final class FormatTests: XCTestCase {
    func testTrailingCommasOutsideStrings() throws {
        let s = XcprojJSONReader.removingTrailingCommas(#"{"a": [1, 2,], "b": "x,]", "c": {"d": 1,},}"#)
        let j = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
        XCTAssertEqual(j?["b"] as? String, "x,]")
        XCTAssertEqual((j?["a"] as? [Int]) ?? [], [1, 2])
    }

    func testYAMLSubset() throws {
        let y = try YAML.parse("""
        # comment
        name: Demo
        list:
          - a
          - "b # not a comment"
          - key: v
            other: w
        flow: [x, 'y', z]
        map: {k: v, n: 2}
        nested:
          deeper:
            value: 3 # trailing
        block: |
          line one
          line two
        empty:
        """) as? [String: Any]
        XCTAssertEqual(y?["name"] as? String, "Demo")
        let list = y?["list"] as? [Any]
        XCTAssertEqual(list?[0] as? String, "a")
        XCTAssertEqual(list?[1] as? String, "b # not a comment")
        XCTAssertEqual((list?[2] as? [String: Any])?["other"] as? String, "w")
        XCTAssertEqual(y?["flow"] as? [String], ["x", "y", "z"])
        XCTAssertEqual((y?["map"] as? [String: Any])?["n"] as? String, "2")
        XCTAssertEqual(((y?["nested"] as? [String: Any])?["deeper"] as? [String: Any])?["value"] as? String, "3")
        XCTAssertEqual(y?["block"] as? String, "line one\nline two")
        XCTAssertEqual(y?["empty"] as? String, "")
    }
}

/// Tests/RunwayToolTests/Fixtures.
let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
