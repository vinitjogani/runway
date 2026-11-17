// RunwayObjC: the slice of the Objective-C runtime that Mac Swift code leans
// on (selectors, target/action, perform, KVC/KVO, selector-based
// notification observers and timers), rebuilt in plain Swift for platforms
// without an Objective-C runtime.
//
// It works together with RunwayTranspiler, which rewrites app sources as
// they're staged: `#selector(f(_:))` becomes `Selector("f:")`, `@objc` /
// `dynamic` / `@IBAction` go, and every class with selector-reachable members
// gets a generated, statically typed dispatch table (`SelectorDispatching`)
// that the functions here call into.
//
// Selector is owned here; AppKit re-exports this module
// (`@_exported import RunwayObjC`) rather than declaring its own.

import Foundation

/// An Objective-C style selector: just its name ("copy:", "tableView:didSelectRow:").
public struct Selector: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let name: String
    public init(_ name: String) { self.name = name }
    public init(stringLiteral value: String) { name = value }
    public var description: String { name }
}

public func NSStringFromSelector(_ aSelector: Selector) -> String { aSelector.name }
public func NSSelectorFromString(_ aSelectorName: String) -> Selector { Selector(aSelectorName) }

