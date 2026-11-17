// Which C-family code can't be built off Apple platforms, and which headers
// describe it: the inputs for the Swift stand-ins (ObjCStandIns.swift).

import Foundation

/// Apple SDK include roots: a C target including one of these (outside a
/// `#if __APPLE__`-style guard) can't compile on Linux or Windows.
public let appleHeaderRoots: Set<String> = [
    "Foundation", "AppKit", "Cocoa", "CoreFoundation", "CoreGraphics", "ApplicationServices", "IOKit", "Carbon", "CoreServices", "Security",
    "QuartzCore", "objc", "mach", "libkern", "os", "xpc", "AudioToolbox", "CoreAudio", "CoreMedia", "CoreVideo", "AVFoundation", "WebKit",
    "SystemConfiguration", "CoreText", "ImageIO", "Metal", "MetalKit", "UIKit", "CoreData", "CoreImage", "ServiceManagement", "CoreWLAN",
    "IOSurface", "DiskArbitration", "OpenGL", "OpenCL", "Accelerate", "CommonCrypto", "mach-o", "CoreBluetooth", "IOBluetooth", "MediaPlayer",
    "CoreMIDI", "AudioUnit", "CoreAudioKit", "Virtualization", "ScriptingBridge", "Quartz", "QuickLook", "QuickLookUI", "StoreKit", "CloudKit",
    "EventKit", "Contacts", "CoreLocation", "MapKit", "GameController", "Network", "NetworkExtension", "LocalAuthentication", "SafariServices",
    "UserNotifications", "PDFKit", "SceneKit", "SpriteKit", "Vision", "CoreML", "CoreSpotlight", "Collaboration", "AddressBook", "bsm",
    "sys/sysctl.h", "sys/event.h", "libproc.h", "TargetConditionals.h", "Availability.h", "AvailabilityMacros.h", "notify.h", "launch.h",
    "sandbox.h", "dispatch", "CoreDisplay", "SkyLight", "MultitouchSupport", "Kernel", "hfs", "IOHIDFamily", "MobileDevice", "sys/kern_control.h",
    "copyfile.h", "membership.h", "libkern/OSAtomic.h", "malloc/malloc.h", "CoreMediaIO", "ExceptionHandling", "Sparkle", "servers", "spawn_private.h",
]

private let includeLine = try! NSRegularExpression(pattern: #"^\s*#\s*(?:import|include)\s*([<"])([^>"]+)[>"]"#)

/// `#include`/`#import` lines of C-family text: (path, angled), leaving out
/// those under a conditional that names an Apple platform (so portable
/// code's `#if __APPLE__` branches don't count) when `unguardedOnly`.
public func cIncludes(in text: String, unguardedOnly: Bool = false) -> [(path: String, angled: Bool)] {
    var out: [(String, Bool)] = []
    var guards: [Bool] = []  // each open conditional: is it Apple-specific?
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let l = line.trimmingCharacters(in: .whitespaces)
        guard l.hasPrefix("#") || l.hasPrefix("@import") else { continue }
        let d = l.dropFirst().trimmingCharacters(in: .whitespaces)
        if d.hasPrefix("if") {
            guards.append(["__APPLE__", "TARGET_OS_", "__MACH__", "__OBJC__", "__DARWIN", "__MACOS", "__APPLE_CC__", "__has_include", "Apple"].contains { d.contains($0) })
            continue
        }
        if d.hasPrefix("elif") || d.hasPrefix("else") { continue }
        if d.hasPrefix("endif") { _ = guards.popLast(); continue }
        if l.hasPrefix("@import") {
            let name = l.dropFirst("@import".count).trimmingCharacters(in: CharacterSet(charactersIn: " ;\t"))
            if !(unguardedOnly && guards.contains(true)) { out.append((String(name.split(separator: ".").first ?? "") + "/", true)) }
            continue
        }
        let ns = l as NSString
        guard let m = includeLine.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) else { continue }
        if unguardedOnly && guards.contains(true) { continue }
        out.append((ns.substring(with: m.range(at: 2)), ns.substring(with: m.range(at: 1)) == "<"))
    }
    return out
}

/// Whether an include names Apple's SDK.
public func isAppleInclude(_ path: String) -> Bool {
    if appleHeaderRoots.contains(path) { return true }
    guard let root = path.split(separator: "/").first, path.contains("/") else { return false }
    return appleHeaderRoots.contains(String(root))
}

/// Whether a set of C-family files needs Apple's SDK or the Objective-C
/// runtime: Objective-C sources, or an unguarded include of an Apple header.
public func needsAppleSDK(cFamilyFiles files: [URL]) -> Bool {
    for f in files {
        if ["m", "mm"].contains(f.pathExtension) { return true }
        guard let text = (try? String(contentsOf: f, encoding: .utf8)) ?? (try? String(contentsOf: f, encoding: .isoLatin1)) else { continue }
        if cIncludes(in: text, unguardedOnly: true).contains(where: { $0.angled && isAppleInclude($0.path) }) { return true }
        if f.pathExtension == "h", text.contains("@interface ") || text.contains("@protocol ") { return true }
    }
    return false
}

/// Headers by file name under `root` (not inside build output or bundles).
public func headerIndex(under root: URL, depth: Int = 8) -> [String: [URL]] {
    var out: [String: [URL]] = [:]
    func walk(_ dir: URL, _ d: Int) {
        guard d > 0 else { return }
        for e in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where !e.hasPrefix(".") {
            if ["build", "Build", "DerivedData", "Pods", "Carthage", "node_modules"].contains(e) { continue }
            let u = dir.appendingPathComponent(e)
            if isDirectory(u) {
                if ["xcodeproj", "xcworkspace", "xcassets", "app", "bundle", "xcframework"].contains(u.pathExtension) { continue }
                walk(u, d - 1)
            } else if ["h", "hh", "hpp"].contains(u.pathExtension) {
                out[e, default: []].append(u)
            }
        }
    }
    walk(root, depth)
    return out
}

/// `roots` and the local headers they include, includes first (so later
/// headers see earlier ones' types and macros). Includes are found next to
/// the including header, under `searchRoots`, then by file name in `index`.
public func headerClosure(of roots: [URL], searchRoots: [URL], index: [String: [URL]]) -> [URL] {
    var out: [URL] = []
    var visiting = Set<String>()
    func visit(_ u: URL) {
        let key = u.standardizedFileURL.path
        guard visiting.insert(key).inserted else { return }
        guard let text = (try? String(contentsOf: u, encoding: .utf8)) ?? (try? String(contentsOf: u, encoding: .isoLatin1)) else { return }
        for inc in cIncludes(in: text) {
            if inc.angled && isAppleInclude(inc.path) { continue }
            var found: URL?
            let candidates = [u.deletingLastPathComponent()] + searchRoots
            for base in candidates {
                let c = base.appendingPathComponent(inc.path).standardizedFileURL
                if exists(c), !isDirectory(c) { found = c; break }
            }
            if found == nil {
                let name = (inc.path as NSString).lastPathComponent
                let hits = index[name] ?? []
                // The nearest one in the tree.
                found = hits.min { relativePath($0, from: u).count < relativePath($1, from: u).count }
            }
            if let f = found { visit(f) }
        }
        out.append(u.standardizedFileURL)
    }
    for r in roots { visit(r) }
    return out
}

/// The Apple frameworks a set of headers includes (`Cocoa`, `IOKit`…).
public func appleFrameworks(includedBy headers: [URL]) -> [String] {
    var out: [String] = []
    for h in headers {
        guard let text = (try? String(contentsOf: h, encoding: .utf8)) ?? (try? String(contentsOf: h, encoding: .isoLatin1)) else { continue }
        for inc in cIncludes(in: text) where inc.angled {
            guard let root = inc.path.split(separator: "/").first.map(String.init), inc.path.contains("/"), !out.contains(root) else { continue }
            out.append(root)
        }
    }
    return out
}
