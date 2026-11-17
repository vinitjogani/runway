import Foundation

public func fixtureWhere() -> String { #filePath }

public var builtForDebug: Bool {
    #if FIXTURE_DEBUG
    true
    #else
    false
    #endif
}
