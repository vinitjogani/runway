// Shared helpers: the Apple-framework module map, import scanning, paths,
// processes and small text utilities.

import Foundation
import RunwayImport

// MARK: Module map

/// What Runway provides for each Apple framework a file imports.
enum Support: String { case runway, toolchain, local, unsupported }

let runwayModules: Set<String> = [
    "SwiftUI", "AppKit", "CoreGraphics", "ImageIO", "UniformTypeIdentifiers", "NaturalLanguage",
    "ServiceManagement", "Security", "CryptoKit", "RunwayFoundation", "Cocoa", "Darwin",
    "Combine", "os", "OSLog", "CoreServices", "FoundationModels", "UserNotifications", "ApplicationServices", "Carbon",
    "IOKit", "SystemConfiguration", "Network", "LocalAuthentication", "CoreLocation", "StoreKit", "EventKit", "Contacts",
    "WidgetKit", "CloudKit", "UIKit", "ActivityKit", "BackgroundTasks",
    "CoreVideo", "CoreMedia", "AVFoundation", "AVKit", "ScreenCaptureKit", "CoreImage", "QuartzCore", "Metal", "MetalKit",
    "CoreText", "VideoToolbox", "Speech", "Vision", "WebKit",
    "CoreTransferable", "AppIntents", "Intents", "CommonCrypto", "Compression", "CoreBluetooth", "CoreWLAN", "ScriptingBridge", "simd", "SwiftData", "Charts", "CoreAudio", "AudioToolbox", "System",
]
/// Module names that resolve to another Runway module (none today: Cocoa
/// and Darwin are real modules).
let moduleAliases: [String: String] = [:]
let toolchainModules: Set<String> = [
    "Foundation", "FoundationEssentials", "FoundationNetworking", "FoundationXML", "Observation", "Dispatch",
    "XCTest", "Testing", "Swift", "_Concurrency", "Synchronization", "RegexBuilder", "Distributed",
    "Glibc", "Musl", "WinSDK", "ucrt", "CRT",
]
/// Why a framework isn't mapped.
let unsupportedModules: [String: String] = [
    "AVFoundation": "media capture, playback and editing (GStreamer / Media Foundation would be the native routes)",
    "AVKit": "media playback UI", "CoreMedia": "media timing and buffers", "CoreVideo": "video buffers",
    "VideoToolbox": "hardware video encode/decode", "ScreenCaptureKit": "screen capture (PipeWire portal / Windows.Graphics.Capture)",
    "CoreImage": "GPU image filters", "Metal": "GPU", "MetalKit": "GPU", "QuartzCore": "Core Animation layers",
    "CoreText": "text layout below AppKit", "Speech": "on-device speech recognition", "FoundationModels": "Apple's on-device LLM",
    "CoreServices": "FSEvents and Launch Services (inotify / ReadDirectoryChangesW)", "WebKit": "web views",
    "UserNotifications": "notifications", "StoreKit": "App Store", "CloudKit": "iCloud", "Combine": "Combine (use Observation)",
    "os": "unified logging", "OSLog": "unified logging", "AppIntents": "Shortcuts", "PDFKit": "PDF views", "MapKit": "maps",
    "Vision": "computer vision", "CoreML": "ML models", "Carbon": "legacy Mac APIs", "IOKit": "devices",
    "CoreAudio": "audio devices", "AudioToolbox": "audio", "CoreLocation": "location", "Contacts": "contacts", "EventKit": "calendars",
]

func canonicalModule(_ module: String) -> String {
    let root = String(module.split(separator: ".").first ?? Substring(module))
    return moduleAliases[root] ?? root
}

func classify(_ module: String, local: Set<String>) -> Support {
    let root = String(module.split(separator: ".").first ?? Substring(module))
    if local.contains(root) { return .local }
    if runwayModules.contains(canonicalModule(root)) { return .runway }
    if toolchainModules.contains(root) { return .toolchain }
    return .unsupported
}

/// Modules a package imports only as one platform's choice among several
/// (`#if canImport(Darwin) import Darwin #elseif canImport(Glibc) …`): the
/// other branch is the Linux one, so linking Runway's module would flip the
/// code onto the Mac path.
let platformChoiceModules: Set<String> = ["Darwin"]

/// The Runway modules `source` needs linked: its imports Runway provides,
/// except `skip` modules imported only under `#if canImport(<it>)`.
func runwayImports(in source: String, local: Set<String>, skippingGuarded skip: Set<String> = platformChoiceModules) -> Set<String> {
    var out = Set<String>()
    var guards: [String] = []  // the condition of each enclosing #if
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("#if") { guards.append(l); continue }
        if l.hasPrefix("#elseif") { if !guards.isEmpty { guards[guards.count - 1] = l }; continue }
        if l.hasPrefix("#else") { if !guards.isEmpty { guards[guards.count - 1] = "#else" }; continue }
        if l.hasPrefix("#endif") { if !guards.isEmpty { guards.removeLast() }; continue }
        guard l.contains("import ") else { continue }
        for m in imports(in: String(l)) where classify(m, local: local) == .runway {
            let c = canonicalModule(m)
            if skip.contains(c), guards.contains(where: { $0.contains("canImport(\(c))") || $0.contains("os(macOS)") || $0.contains("os(iOS)") }) { continue }
            out.insert(c)
        }
    }
    return out
}

func imports(in source: String) -> [String] {
    var out: [String] = []
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
        var l = line.trimmingCharacters(in: .whitespaces)
        while l.hasPrefix("@") { l = String(l.drop { $0 != " " }).trimmingCharacters(in: .whitespaces) }
        for prefix in ["public ", "internal ", "package ", "private ", "fileprivate "] where l.hasPrefix(prefix) { l = String(l.dropFirst(prefix.count)) }
        guard l.hasPrefix("import ") else { continue }
        var rest = l.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
        for kind in ["class ", "struct ", "enum ", "protocol ", "func ", "var ", "let ", "typealias "] where rest.hasPrefix(kind) {
            rest = String(rest.dropFirst(kind.count))
        }
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
        if !name.isEmpty { out.append(String(name.split(separator: ".").first!)) }
    }
    return out
}

/// AppKit names Runway's AppKit provides; others flag in `check`.
let providedAppKit: Set<String> = [
    "NSApplication", "NSApp", "NSApplicationDelegate", "NSResponder", "NSView", "NSViewController", "NSWindow", "NSWindowDelegate",
    "NSPanel", "NSScreen", "NSMenu", "NSMenuItem", "NSControl", "NSEvent", "NSColor", "NSColorSpace", "NSAppearance", "NSFont",
    "NSImage", "NSPasteboard", "NSPasteboardWriting", "NSWorkspace", "NSRunningApplication", "NSSound", "NSSavePanel", "NSOpenPanel",
    "NSAlert", "NSBeep", "NSDockTile", "NSHostingController", "NSHostingView", "NSHostingSizingOptions", "NSViewRepresentable",
    "NSViewRepresentableContext", "NSUserInterfaceItemIdentifier",
    // Foundation's own NS types.
    "NSObject", "NSString", "NSData", "NSMutableData", "NSURL", "NSNumber", "NSDictionary", "NSMutableDictionary", "NSArray",
    "NSMutableArray", "NSError", "NSRange", "NSLock", "NSRecursiveLock", "NSCoder", "NSAttributedString", "NSMutableAttributedString",
    "NSRegularExpression", "NSPredicate", "NSSortDescriptor", "NSNull", "NSSet", "NSCache", "NSNotFound", "NSMakeRange", "NSLocalizedString",
    "NSValue", "NSDate", "NSIndexSet", "NSCountedSet", "NSFileHandle", "NSUUID", "NSTextCheckingResult", "NSItemProvider", "NSKeyedArchiver",
    "NSKeyedUnarchiver", "NSSecureCoding", "NSCoding", "NSCopying", "NSFileCoordinator", "NSFilePresenter", "NSOrderedSet", "NSCharacterSet",
    "NSDecimalNumber", "NSLocale", "NSCalendar", "NSTimeZone", "NSHomeDirectory", "NSTemporaryDirectory", "NSUserName", "NSEdgeInsets",
    "NSMaxRange", "NSIntersectionRange", "NSUnionRange", "NSEqualRanges", "NSLocationInRange", "NSRect", "NSPoint", "NSSize", "NSZeroRect",
]

#if os(Linux) || os(Windows)
let implicitImports = ["FoundationNetworking"]
#else
let implicitImports: [String] = []
#endif

// MARK: Paths and processes

let fm = FileManager.default

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("runway: error: " + message + "\n").utf8))
    exit(1)
}

func log(_ message: String) { FileHandle.standardError.write(Data(("runway: " + message + "\n").utf8)) }

/// A failure staging one package; reported with its context, not a crash.
struct StageError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

@discardableResult
func run(_ exe: String, _ args: [String], cwd: URL? = nil, env: [String: String] = [:], capture: Bool = false, quiet: Bool = false) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    var e = ProcessInfo.processInfo.environment
    for (k, v) in env { e[k] = v }
    p.environment = e
    let pipe = Pipe()
    if capture { p.standardOutput = pipe }
    if quiet { p.standardError = FileHandle.nullDevice }
    do { try p.run() } catch { die("couldn't run \(exe): \(error)") }
    var data = Data()
    if capture { data = pipe.fileHandleForReading.readDataToEndOfFile() }
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func which(_ tool: String) -> String {
    if let found = whichIfPresent(tool) { return found }
    die("\(tool) not found on PATH")
}

func whichIfPresent(_ tool: String) -> String? {
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: Character(pathListSeparator))
    for dir in paths {
        for ext in executableExtensions {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(tool + ext).path
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
    }
    return nil
}

#if os(Windows)
let pathListSeparator = ";"
let executableExtensions = [".exe", ""]
#else
let pathListSeparator = ":"
let executableExtensions = [""]
#endif

/// Runway's own package: RUNWAY_ROOT, or found from this executable
/// (…/runway/.build/<config>/runway) or the working directory.
func runwayRoot() -> URL {
    if let r = ProcessInfo.processInfo.environment["RUNWAY_ROOT"] { return URL(fileURLWithPath: r).standardizedFileURL }
    var candidates = [URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath(), URL(fileURLWithPath: fm.currentDirectoryPath)]
    candidates = candidates.map { $0.standardizedFileURL }
    for start in candidates {
        var dir = start
        for _ in 0..<8 {
            let manifest = dir.appendingPathComponent("Package.swift")
            if let s = try? String(contentsOf: manifest, encoding: .utf8), s.contains("name: \"Runway\"") { return dir }
            dir.deleteLastPathComponent()
        }
    }
    die("can't find Runway's package; set RUNWAY_ROOT")
}


/// The deepest directory that contains every URL.
func commonAncestor(_ urls: [URL]) -> URL? {
    guard var common = urls.first?.standardizedFileURL.deletingLastPathComponent().pathComponents else { return nil }
    for u in urls.dropFirst() {
        let c = u.standardizedFileURL.deletingLastPathComponent().pathComponents
        var i = 0
        while i < common.count, i < c.count, common[i] == c[i] { i += 1 }
        common = Array(common[..<i])
    }
    return URL(fileURLWithPath: common.count <= 1 ? "/" : "/" + common.dropFirst().joined(separator: "/"))
}

func ensureDir(_ url: URL) {
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
}

func write(_ text: String, to url: URL) throws {
    ensureDir(url.deletingLastPathComponent())
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// Copies a file or directory, replacing what's there.
func copyItem(_ src: URL, _ dst: URL) throws {
    ensureDir(dst.deletingLastPathComponent())
    try? fm.removeItem(at: dst)
    try fm.copyItem(at: src, to: dst)
}

// MARK: Names Runway's modules declare

/// Type names declared anywhere in Runway's modules (and the Foundation
/// classes Objective-C headers name), so stand-ins generated from
/// Objective-C headers don't declare them again. Cached per run.
nonisolated(unsafe) private var knownTypesCache: Set<String>?

func knownRunwayTypes(_ root: URL) -> Set<String> {
    if let c = knownTypesCache { return c }
    var out: Set<String> = [
        "NSObject", "NSString", "NSMutableString", "NSData", "NSMutableData", "NSURL", "NSNumber", "NSValue", "NSDictionary", "NSMutableDictionary",
        "NSArray", "NSMutableArray", "NSSet", "NSMutableSet", "NSError", "NSDate", "NSCoder", "NSNull", "NSLock", "NSRecursiveLock", "NSCondition",
        "NSAttributedString", "NSMutableAttributedString", "NSIndexSet", "NSMutableIndexSet", "NSOrderedSet", "NSMutableOrderedSet", "NSCountedSet",
        "NSCache", "NSPredicate", "NSSortDescriptor", "NSRegularExpression", "NSTextCheckingResult", "NSCopying", "NSMutableCopying", "NSCoding",
        "NSSecureCoding", "NSObjectProtocol", "NSKeyedArchiver", "NSKeyedUnarchiver", "NSNotification", "NSException", "NSEnumerator", "NSZone",
        "NSUUID", "NSCalendar", "NSLocale", "NSTimeZone", "NSDateComponents", "NSCharacterSet", "NSMutableCharacterSet", "NSURLRequest",
        "NSMutableURLRequest", "NSDecimalNumber", "NSHashTable", "NSMapTable", "NSPointerArray", "NSRange", "NSFastEnumeration", "NSLocking",
        "NSXPCConnection_", "NSMeasurement", "NSUnit", "NSDateInterval", "NSItemProvider", "NSConditionLock", "NSURLComponents", "NSURLQueryItem",
    ]
    let rx = try! NSRegularExpression(pattern: #"(?m)^\s*(?:@[\w()., :\"*]+\s+)*(?:(?:public|open|package|final|indirect|nonisolated|@unchecked)\s+)*(?:class|struct|enum|protocol|typealias|actor)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
    if let e = fm.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil) {
        for case let url as URL in e where url.pathExtension == "swift" {
            guard let s = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let ns = s as NSString
            for m in rx.matches(in: s, range: NSRange(location: 0, length: ns.length)) { out.insert(ns.substring(with: m.range(at: 1))) }
        }
    }
    knownTypesCache = out
    return out
}

/// Global functions and constants Runway's modules declare, so public
/// stand-ins don't declare them a second time (an ambiguity in the app).
nonisolated(unsafe) private var knownValuesCache: Set<String>?

func knownRunwayValues(_ root: URL) -> Set<String> {
    if let c = knownValuesCache { return c }
    var out = Set<String>()
    let rx = try! NSRegularExpression(pattern: #"(?m)^(?:@[\w()., :\"*]+\s+)*public\s+(?:nonisolated\(unsafe\)\s+)?(?:let|var|func)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
    if let e = fm.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil) {
        for case let url as URL in e where url.pathExtension == "swift" {
            guard let s = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let ns = s as NSString
            for m in rx.matches(in: s, range: NSRange(location: 0, length: ns.length)) { out.insert(ns.substring(with: m.range(at: 1))) }
        }
    }
    knownValuesCache = out
    return out
}
