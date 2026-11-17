import FixtureKit
import Foundation

let b = Bundle.main
print("bundleIdentifier=\(b.bundleIdentifier ?? "nil")")
print("version=\(b.infoDictionary?["CFBundleShortVersionString"] as? String ?? "nil")")
print("name=\(b.infoDictionary?["CFBundleName"] as? String ?? "nil")")
print("catalog=\(NSLocalizedString("Hello", comment: ""))")
print("untranslated=\(NSLocalizedString("Untranslated", comment: ""))")
print("strings=\(b.localizedString(forKey: "Greeting", value: "missing", table: "Other"))")
print("plural=\(String.localizedStringWithFormat(NSLocalizedString("%lld notes", comment: ""), 1))")
print("assets=\(b.path(forResource: "RunwayAssets", ofType: "json", inDirectory: "RunwayAssets") ?? "nil")")
print("kitFile=\(fixtureWhere())")
print("debug=\(builtForDebug)")
