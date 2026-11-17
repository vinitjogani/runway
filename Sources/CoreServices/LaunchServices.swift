// Launch Services pieces apps use: default handlers for files and URL
// schemes (xdg-mime and the .desktop database on Linux; the registry's
// associations on Windows), opening URLs, and the legacy UTType functions
// (over UniformTypeIdentifiers).

import Foundation
import UniformTypeIdentifiers

public struct LSRolesMask: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let none = LSRolesMask(rawValue: 1)
    public static let viewer = LSRolesMask(rawValue: 2)
    public static let editor = LSRolesMask(rawValue: 4)
    public static let shell = LSRolesMask(rawValue: 8)
    public static let all = LSRolesMask(rawValue: 0xFFFFFFFF)
}

public var kLSRolesAll: LSRolesMask { .all }
public var kLSRolesViewer: LSRolesMask { .viewer }
public var kLSRolesEditor: LSRolesMask { .editor }

public let kLSApplicationNotFoundErr: OSStatus = -10814
public let kLSUnknownErr: OSStatus = -10810
public let kLSDataUnavailableErr: OSStatus = -10813
public let kLSNoLaunchPermissionErr: OSStatus = -10826
public let paramErr: OSStatus = -50

enum Launch {
    static func run(_ tool: String, _ args: [String]) -> String? {
        #if os(Windows)
        return nil
        #else
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [tool] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
        #endif
    }

    /// The .desktop file for a desktop id, searched along XDG_DATA_DIRS.
    static func desktopFile(_ id: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        let home = env["XDG_DATA_HOME"] ?? (NSHomeDirectory() + "/.local/share")
        let dirs = [home] + (env["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share").split(separator: ":").map(String.init)
        for d in dirs {
            let p = d + "/applications/" + id
            if FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    static func mimeType(_ url: URL) -> String? {
        if url.isFileURL {
            if let m = run("xdg-mime", ["query", "filetype", url.path]) { return m }
            return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        }
        return url.scheme.map { "x-scheme-handler/\($0.lowercased())" }
    }

    static func defaultHandler(mime: String) -> URL? {
        run("xdg-mime", ["query", "default", mime]).flatMap { $0.split(separator: ";").first.map(String.init) }.flatMap(desktopFile)
    }
}

private func notFound(_ outError: UnsafeMutablePointer<Unmanaged<CFError>?>?) {
    outError?.pointee = Unmanaged.passRetained(NSError(domain: NSOSStatusErrorDomain, code: Int(kLSApplicationNotFoundErr)))
}

/// The default application for a URL: on Linux the .desktop file of the
/// handler xdg-mime reports.
public func LSCopyDefaultApplicationURLForURL(_ inURL: CFURL, _ inRoleMask: LSRolesMask,
                                              _ outError: UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>? {
    guard let mime = Launch.mimeType(inURL as URL), let app = Launch.defaultHandler(mime: mime) else { notFound(outError); return nil }
    return Unmanaged.passRetained(app as NSURL)
}

public func LSCopyDefaultApplicationURLForContentType(_ inContentType: CFString, _ inRoleMask: LSRolesMask,
                                                      _ outError: UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>? {
    let mime = UTType(inContentType as String)?.preferredMIMEType ?? (inContentType as String)
    guard let app = Launch.defaultHandler(mime: mime) else { notFound(outError); return nil }
    return Unmanaged.passRetained(app as NSURL)
}

public func LSCopyApplicationURLsForURL(_ inURL: CFURL, _ inRoleMask: LSRolesMask) -> Unmanaged<CFArray>? {
    guard let mime = Launch.mimeType(inURL as URL) else { return nil }
    let env = ProcessInfo.processInfo.environment
    let dirs = [env["XDG_DATA_HOME"] ?? (NSHomeDirectory() + "/.local/share")]
        + (env["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share").split(separator: ":").map(String.init)
    var apps: [NSURL] = []
    for d in dirs {
        let cache = d + "/applications/mimeinfo.cache"
        guard let text = try? String(contentsOfFile: cache, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n") where line.hasPrefix(mime + "=") {
            for id in line.dropFirst(mime.count + 1).split(separator: ";") {
                if let u = Launch.desktopFile(String(id)), !apps.contains(u as NSURL) { apps.append(u as NSURL) }
            }
        }
    }
    return apps.isEmpty ? nil : Unmanaged.passRetained(apps as NSArray)
}

/// The desktop id handling a scheme (Apple returns a bundle identifier).
public func LSCopyDefaultHandlerForURLScheme(_ inURLScheme: CFString) -> Unmanaged<CFString>? {
    Launch.run("xdg-mime", ["query", "default", "x-scheme-handler/\((inURLScheme as String).lowercased())"])
        .map { Unmanaged.passRetained(($0.hasSuffix(".desktop") ? String($0.dropLast(8)) : $0) as NSString) }
}

public func LSCopyAllHandlersForURLScheme(_ inURLScheme: CFString) -> Unmanaged<CFArray>? {
    LSCopyDefaultHandlerForURLScheme(inURLScheme).map { Unmanaged.passRetained([$0.takeRetainedValue()] as NSArray) }
}

/// Registers `inHandlerBundleID` (a desktop id, with or without
/// ".desktop") as the scheme's handler.
public func LSSetDefaultHandlerForURLScheme(_ inURLScheme: CFString, _ inHandlerBundleID: CFString) -> OSStatus {
    var id = inHandlerBundleID as String
    if !id.hasSuffix(".desktop") { id += ".desktop" }
    return Launch.run("xdg-mime", ["default", id, "x-scheme-handler/\((inURLScheme as String).lowercased())"]) != nil
        || Launch.desktopFile(id) != nil ? noErr : kLSApplicationNotFoundErr
}

public func LSSetDefaultRoleHandlerForContentType(_ inContentType: CFString, _ inRole: LSRolesMask, _ inHandlerBundleID: CFString) -> OSStatus {
    guard let mime = UTType(inContentType as String)?.preferredMIMEType else { return paramErr }
    var id = inHandlerBundleID as String
    if !id.hasSuffix(".desktop") { id += ".desktop" }
    _ = Launch.run("xdg-mime", ["default", id, mime])
    return noErr
}

public func LSCopyDefaultRoleHandlerForContentType(_ inContentType: CFString, _ inRole: LSRolesMask) -> Unmanaged<CFString>? {
    guard let mime = UTType(inContentType as String)?.preferredMIMEType,
          let id = Launch.run("xdg-mime", ["query", "default", mime]) else { return nil }
    return Unmanaged.passRetained((id.hasSuffix(".desktop") ? String(id.dropLast(8)) : id) as NSString)
}

/// Opens a URL with its default handler (xdg-open / ShellExecute).
public func LSOpenCFURLRef(_ inURL: CFURL, _ outLaunchedURL: UnsafeMutablePointer<Unmanaged<CFURL>?>?) -> OSStatus {
    let url = inURL as URL
    #if os(Windows)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: #"C:\Windows\System32\cmd.exe"#)
    p.arguments = ["/c", "start", "", url.isFileURL ? url.path : url.absoluteString]
    return (try? p.run()) != nil ? noErr : kLSApplicationNotFoundErr
    #else
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["xdg-open", url.isFileURL ? url.path : url.absoluteString]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    return (try? p.run()) != nil ? noErr : kLSApplicationNotFoundErr
    #endif
}

public func LSRegisterURL(_ inURL: CFURL, _ inUpdate: Bool) -> OSStatus { noErr }

// MARK: Legacy UTType functions

public let kUTTagClassFilenameExtension: CFString = "public.filename-extension"
public let kUTTagClassMIMEType: CFString = "public.mime-type"

public let kUTTypeItem: CFString = "public.item"
public let kUTTypeContent: CFString = "public.content"
public let kUTTypeData: CFString = "public.data"
public let kUTTypeText: CFString = "public.text"
public let kUTTypePlainText: CFString = "public.plain-text"
public let kUTTypeUTF8PlainText: CFString = "public.utf8-plain-text"
public let kUTTypeHTML: CFString = "public.html"
public let kUTTypeJSON: CFString = "public.json"
public let kUTTypeXML: CFString = "public.xml"
public let kUTTypeURL: CFString = "public.url"
public let kUTTypeFileURL: CFString = "public.file-url"
public let kUTTypeImage: CFString = "public.image"
public let kUTTypePNG: CFString = "public.png"
public let kUTTypeJPEG: CFString = "public.jpeg"
public let kUTTypeGIF: CFString = "com.compuserve.gif"
public let kUTTypeTIFF: CFString = "public.tiff"
public let kUTTypePDF: CFString = "com.adobe.pdf"
public let kUTTypeMovie: CFString = "public.movie"
public let kUTTypeAudio: CFString = "public.audio"
public let kUTTypeFolder: CFString = "public.folder"
public let kUTTypeDirectory: CFString = "public.directory"
public let kUTTypeApplication: CFString = "com.apple.application"
public let kUTTypeZipArchive: CFString = "public.zip-archive"
public let kUTTypeRTF: CFString = "public.rtf"
public let kUTTypeSourceCode: CFString = "public.source-code"

private func tagClass(_ c: CFString) -> UTTagClass? {
    switch c as String {
    case "public.filename-extension": return .filenameExtension
    case "public.mime-type": return .mimeType
    default: return nil
    }
}

public func UTTypeCreatePreferredIdentifierForTag(_ inTagClass: CFString, _ inTag: CFString, _ inConformingToUTI: CFString?) -> Unmanaged<CFString>? {
    guard let c = tagClass(inTagClass) else { return nil }
    let t = UTType(tag: inTag as String, tagClass: c, conformingTo: inConformingToUTI.flatMap { UTType($0 as String) })
    return t.map { Unmanaged.passRetained($0.identifier as NSString) }
}

public func UTTypeCopyPreferredTagWithClass(_ inUTI: CFString, _ inTagClass: CFString) -> Unmanaged<CFString>? {
    guard let t = UTType(inUTI as String), let c = tagClass(inTagClass) else { return nil }
    let tag: String? = c == .filenameExtension ? t.preferredFilenameExtension : t.preferredMIMEType
    return tag.map { Unmanaged.passRetained($0 as NSString) }
}

public func UTTypeConformsTo(_ inUTI: CFString, _ inConformsToUTI: CFString) -> Bool {
    guard let a = UTType(inUTI as String), let b = UTType(inConformsToUTI as String) else { return (inUTI as String) == (inConformsToUTI as String) }
    return a.conforms(to: b)
}

public func UTTypeEqual(_ a: CFString, _ b: CFString) -> Bool { (a as String) == (b as String) }

public func UTTypeCopyDescription(_ inUTI: CFString) -> Unmanaged<CFString>? {
    UTType(inUTI as String)?.localizedDescription.map { Unmanaged.passRetained($0 as NSString) }
}
