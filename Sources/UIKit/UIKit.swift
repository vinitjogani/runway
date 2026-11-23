@_exported import Foundation
@_exported import CoreGraphics
import AppKit
@_spi(Runway) import CoreText
import RunwayCore

@MainActor @preconcurrency
public protocol UIApplicationDelegate: AnyObject {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void)
}

extension UIApplicationDelegate {
    public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool { true }
    public func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) { completionHandler() }
}

@MainActor @preconcurrency
public final class UIApplication: NSObject {
    public enum State: Sendable { case active, inactive, background }

    public struct LaunchOptionsKey: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let url = Self(rawValue: "UIApplicationLaunchOptionsURLKey")
    }

    public struct OpenExternalURLOptionsKey: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let universalLinksOnly = Self(rawValue: "UIApplicationOpenURLOptionsUniversalLinksOnly")
    }

    public static let shared = UIApplication()
    public static let openSettingsURLString = "app-settings:"
    public weak var delegate: UIApplicationDelegate?
    public var applicationState: State { .active }

    public func open(_ url: URL, options: [OpenExternalURLOptionsKey: Any] = [:], completionHandler completion: ((Bool) -> Void)? = nil) {
        guard url.scheme != "app-settings", options[.universalLinksOnly] as? Bool != true else {
            completion?(false)
            return
        }
        let opened = Runway.backend.services.open(url)
        completion?(opened)
    }

    // The desktop preview has no iOS background execution grants.
    public func beginBackgroundTask(withName taskName: String?, expirationHandler handler: (() -> Void)? = nil) -> UIBackgroundTaskIdentifier { .invalid }
    public func beginBackgroundTask(expirationHandler handler: (() -> Void)? = nil) -> UIBackgroundTaskIdentifier { .invalid }
    public func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {}
}

public struct UIBackgroundTaskIdentifier: RawRepresentable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let invalid = Self(rawValue: Int.max)
}

@MainActor @preconcurrency
public final class UIDevice: NSObject {
    public static let current = UIDevice()
    public var name: String { "Runway Preview" }
}

public struct UITextContentType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let name = Self(rawValue: "name")
    public static let emailAddress = Self(rawValue: "emailAddress")
    public static let username = Self(rawValue: "username")
    public static let password = Self(rawValue: "password")
    public static let newPassword = Self(rawValue: "newPassword")
    public static let oneTimeCode = Self(rawValue: "oneTimeCode")
    public static let telephoneNumber = Self(rawValue: "telephoneNumber")
    public static let URL = Self(rawValue: "URL")
}

public enum UIKeyboardType: Int, Sendable {
    case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad, phonePad, namePhonePad
    case emailAddress, decimalPad, twitter, webSearch, asciiCapableNumberPad
}

public enum UIAccessibility {
    public enum Notification: Sendable { case announcement, layoutChanged, screenChanged, pageScrolled }

    // Accessibility announcements need a platform accessibility backend.
    public static func post(notification: Notification, argument: Any?) {}
}

@MainActor @preconcurrency
public final class UIPasteboard {
    public struct OptionsKey: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let localOnly = Self(rawValue: "UIPasteboardOptionLocalOnly")
    }

    public static let general = UIPasteboard()
    public static let typeAutomatic = "com.apple.uikit.pasteboard.automatic"

    public var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            if let newValue { _ = NSPasteboard.general.setString(newValue, forType: .string) }
            else { Runway.backend.services.copyToClipboard(string: "") }
        }
    }

    public func setItems(_ items: [[String: Any]], options: [OptionsKey: Any] = [:]) {
        string = items.lazy.compactMap { ($0[Self.typeAutomatic] ?? $0["public.utf8-plain-text"]) as? String }.first
    }
}

public final class UIImage: NSObject, @unchecked Sendable {
    @_spi(Runway) public let platformImage: NSImage

    private init(_ image: NSImage) { platformImage = image }

    public convenience init?(named name: String) {
        guard let image = NSImage(named: name) else { return nil }
        self.init(image)
    }

    public convenience init?(systemName name: String) {
        guard SymbolArt.overrideSVG(name) != nil || SymbolArt.svg(name) != nil,
              let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        self.init(image)
    }

    public var size: CGSize { platformImage.size }
}

public final class UIFont: NSObject, @unchecked Sendable {
    public let fontName: String
    public let pointSize: CGFloat

    public init?(name: String, size: CGFloat) {
        if runwayRegisteredFont(named: name, size: size) == nil {
            let families = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
            let postScriptNames = CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? []
            guard (families + postScriptNames).contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        }
        fontName = name
        pointSize = size
    }
}

@_spi(Runway) public enum UIKitRuntime {
    public static func registerMobileSystemFonts() {
        #if os(Linux)
        for file in MobileSystemFont().files {
            if !CTFontManagerRegisterFontsForURL(file as NSURL, .process, nil) {
                FileHandle.standardError.write(Data("runway: could not register mobile font \(file.path)\n".utf8))
            }
        }
        #endif
    }

    public static let mobileSystemFontFamily: String? = {
        let configuration = MobileSystemFont()
        #if os(Linux)
        let families = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        let selected = configuration.select(from: families)
        if let requested = configuration.requestedFamily, selected?.caseInsensitiveCompare(requested) != .orderedSame {
            FileHandle.standardError.write(Data("runway: mobile font family ‘\(requested)’ is unavailable; using \(selected ?? "the toolkit font")\n".utf8))
        }
        return selected
        #else
        return configuration.requestedFamily
        #endif
    }()

    public static func registerBundleFonts(_ bundle: Bundle = .main) {
        guard let fontFiles = bundle.object(forInfoDictionaryKey: "UIAppFonts") as? [String] else { return }
        for file in fontFiles {
            guard let url = bundle.url(forResource: file, withExtension: nil) else { continue }
            _ = CTFontManagerRegisterFontsForURL(url as NSURL, .process, nil)
        }
    }

    public static func registeredFont(named name: String, size: CGFloat) -> FontSpec? {
        runwayRegisteredFont(named: name, size: size)
    }
}
