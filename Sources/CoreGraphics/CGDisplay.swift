// Display services, events, screen-capture access and PDF documents.
//
// Displays come from a provider the platform layer installs
// (`CGDisplayServices.provider`: ScreenCaptureKit and the GTK backend set it
// from GDK monitors); without one there's a single 1920×1080 display, id 1.
// The pointer location comes from `CGEventServices.pointerLocation` the same
// way; without one `CGEvent(source:)` is nil, as when events are unavailable.

import Foundation

public typealias CGDirectDisplayID = UInt32
public typealias CGWindowID = UInt32
public typealias CGWindowLevel = Int32
public let kCGNullDirectDisplay: CGDirectDisplayID = 0
public let kCGNullWindowID: CGWindowID = 0

public struct CGDisplayInfo: Sendable, Equatable {
    public var id: CGDirectDisplayID
    /// Global points, top-left origin.
    public var bounds: CGRect
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double
    public var name: String
    public var isMain: Bool
    public init(id: CGDirectDisplayID, bounds: CGRect, pixelWidth: Int, pixelHeight: Int, refreshRate: Double = 60, name: String = "Display", isMain: Bool = false) {
        self.id = id; self.bounds = bounds; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate; self.name = name; self.isMain = isMain
    }
}

public enum CGDisplayServices {
    /// The displays, as the platform reports them.
    nonisolated(unsafe) public static var provider: (() -> [CGDisplayInfo])?
    static let lock = NSLock()
    public static var displays: [CGDisplayInfo] {
        lock.lock(); let p = provider; lock.unlock()
        if let p { let d = p(); if !d.isEmpty { return d } }
        return [CGDisplayInfo(id: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), pixelWidth: 1920, pixelHeight: 1080, isMain: true)]
    }
    /// Sets the provider unless the platform already has.
    public static func installIfAbsent(_ p: @escaping () -> [CGDisplayInfo]) {
        lock.lock(); defer { lock.unlock() }
        if provider == nil { provider = p }
    }
    static func display(_ id: CGDirectDisplayID) -> CGDisplayInfo? { displays.first { $0.id == id } }
}

public func CGMainDisplayID() -> CGDirectDisplayID {
    let d = CGDisplayServices.displays
    return (d.first(where: \.isMain) ?? d.first)?.id ?? 1
}
public func CGDisplayBounds(_ display: CGDirectDisplayID) -> CGRect { CGDisplayServices.display(display)?.bounds ?? .zero }
public func CGDisplayPixelsWide(_ display: CGDirectDisplayID) -> Int { CGDisplayServices.display(display)?.pixelWidth ?? 0 }
public func CGDisplayPixelsHigh(_ display: CGDirectDisplayID) -> Int { CGDisplayServices.display(display)?.pixelHeight ?? 0 }
public func CGDisplayIsMain(_ display: CGDirectDisplayID) -> UInt32 { display == CGMainDisplayID() ? 1 : 0 }
public func CGDisplayIsBuiltin(_ display: CGDirectDisplayID) -> UInt32 { 0 }
public func CGDisplayIsActive(_ display: CGDirectDisplayID) -> UInt32 { CGDisplayServices.display(display) == nil ? 0 : 1 }
public func CGDisplayIsOnline(_ display: CGDirectDisplayID) -> UInt32 { CGDisplayIsActive(display) }
public func CGDisplayScreenSize(_ display: CGDirectDisplayID) -> CGSize {
    guard let d = CGDisplayServices.display(display) else { return .zero }
    return CGSize(width: CGFloat(d.pixelWidth) * 0.25, height: CGFloat(d.pixelHeight) * 0.25) // ~100 dpi, in millimetres
}
@discardableResult
public func CGGetActiveDisplayList(_ maxDisplays: UInt32, _ activeDisplays: UnsafeMutablePointer<CGDirectDisplayID>?,
                                   _ displayCount: UnsafeMutablePointer<UInt32>?) -> CGError {
    let d = CGDisplayServices.displays
    displayCount?.pointee = UInt32(d.count)
    if let activeDisplays { for (i, x) in d.prefix(Int(maxDisplays)).enumerated() { activeDisplays[i] = x.id } }
    return .success
}
@discardableResult
public func CGGetOnlineDisplayList(_ maxDisplays: UInt32, _ displays: UnsafeMutablePointer<CGDirectDisplayID>?, _ count: UnsafeMutablePointer<UInt32>?) -> CGError {
    CGGetActiveDisplayList(maxDisplays, displays, count)
}

public final class CGDisplayMode: @unchecked Sendable {
    public let width: Int, height: Int, pixelWidth: Int, pixelHeight: Int
    public let refreshRate: Double
    public var ioDisplayModeID: Int32 { 0 }
    public var isUsableForDesktopGUI: Bool { true }
    init(_ d: CGDisplayInfo) {
        width = Int(d.bounds.width); height = Int(d.bounds.height)
        pixelWidth = d.pixelWidth; pixelHeight = d.pixelHeight
        refreshRate = d.refreshRate
    }
}
public func CGDisplayCopyDisplayMode(_ display: CGDirectDisplayID) -> CGDisplayMode? { CGDisplayServices.display(display).map(CGDisplayMode.init) }

/// Display streams are a capture API (ScreenCaptureKit stands in); the matrix names remain.
public enum CGDisplayStream {
    public static let yCbCrMatrix_ITU_R_709_2: CFString = "ITU_R_709_2"
    public static let yCbCrMatrix_ITU_R_601_4: CFString = "ITU_R_601_4"
    public static let yCbCrMatrix_SMPTE_240M_1995: CFString = "SMPTE_240M_1995"
}

// MARK: Screen-capture access

/// Linux has no per-app screen-recording switch: capture is granted per
/// session by the desktop portal when it starts. So access is "yes", and a
/// refusal arrives through the capture API's own error path.
public func CGPreflightScreenCaptureAccess() -> Bool { true }
@discardableResult
public func CGRequestScreenCaptureAccess() -> Bool { true }

// MARK: Windows

// The window list and Quartz Event Services are in CGEvents.swift.

public enum CGEventServices {
    /// Where the pointer is, in global points (top-left origin), from the platform.
    nonisolated(unsafe) public static var pointerLocation: (() -> CGPoint?)?
    /// Which mouse buttons are down (bit 0 left, 1 right), from the platform.
    nonisolated(unsafe) public static var pressedButtons: (() -> Int)?
}

// MARK: PDF

public enum CGPDFBox: Int32, Sendable { case mediaBox = 0, cropBox, bleedBox, trimBox, artBox }

/// PDF documents can't be read here (no PDF renderer): opening one fails, as for an unreadable file.
public final class CGPDFDocument: @unchecked Sendable {
    public init?(_ url: CFURL) { return nil }
    public init?(_ provider: CGDataProvider) { return nil }
    public var numberOfPages: Int { 0 }
    public func page(at pageNumber: Int) -> CGPDFPage? { nil }
    public var isEncrypted: Bool { false }
    public var isUnlocked: Bool { true }
}
public final class CGPDFPage: @unchecked Sendable {
    public func getBoxRect(_ box: CGPDFBox) -> CGRect { .zero }
    public var pageNumber: Int { 0 }
    public var rotationAngle: Int32 { 0 }
    public func getDrawingTransform(_ box: CGPDFBox, rect: CGRect, rotate: Int32, preserveAspectRatio: Bool) -> CGAffineTransform { .identity }
}


// MARK: Window levels

public enum CGWindowLevelKey: Int32, Sendable {
    case baseWindow = 0, minimumWindow, desktopWindow, backstopMenu, normalWindow, floatingWindow, tornOffMenuWindow, dockWindow, mainMenuWindow,
         statusWindow, modalPanelWindow, popUpMenuWindow, draggingWindow, screenSaverWindow, maximumWindow, overlayWindow, helpWindow,
         utilityWindow, desktopIconWindow, cursorWindow, assistiveTechHighWindow
}

public func CGWindowLevelForKey(_ key: CGWindowLevelKey) -> CGWindowLevel {
    switch key {
    case .baseWindow, .minimumWindow: return Int32.min
    case .desktopWindow: return -2147483623
    case .backstopMenu: return -20
    case .normalWindow: return 0
    case .floatingWindow, .tornOffMenuWindow, .utilityWindow: return 3
    case .modalPanelWindow: return 8
    case .dockWindow: return 20
    case .mainMenuWindow: return 24
    case .statusWindow: return 25
    case .popUpMenuWindow: return 101
    case .overlayWindow: return 102
    case .helpWindow: return 200
    case .draggingWindow: return 500
    case .screenSaverWindow: return 1000
    case .assistiveTechHighWindow: return 1500
    case .desktopIconWindow: return -2147483603
    case .cursorWindow: return 2147483630
    case .maximumWindow: return 2147483631
    }
}

public let kCGBaseWindowLevel: CGWindowLevel = Int32.min
public let kCGMinimumWindowLevel: CGWindowLevel = Int32.min
public let kCGDesktopWindowLevel: CGWindowLevel = -2147483623
public let kCGDesktopIconWindowLevel: CGWindowLevel = -2147483603
public let kCGBackstopMenuLevel: CGWindowLevel = -20
public let kCGNormalWindowLevel: CGWindowLevel = 0
public let kCGFloatingWindowLevel: CGWindowLevel = 3
public let kCGTornOffMenuWindowLevel: CGWindowLevel = 3
public let kCGUtilityWindowLevel: CGWindowLevel = 3
public let kCGModalPanelWindowLevel: CGWindowLevel = 8
public let kCGDockWindowLevel: CGWindowLevel = 20
public let kCGMainMenuWindowLevel: CGWindowLevel = 24
public let kCGStatusWindowLevel: CGWindowLevel = 25
public let kCGPopUpMenuWindowLevel: CGWindowLevel = 101
public let kCGOverlayWindowLevel: CGWindowLevel = 102
public let kCGHelpWindowLevel: CGWindowLevel = 200
public let kCGDraggingWindowLevel: CGWindowLevel = 500
public let kCGScreenSaverWindowLevel: CGWindowLevel = 1000
public let kCGAssistiveTechHighWindowLevel: CGWindowLevel = 1500
public let kCGCursorWindowLevel: CGWindowLevel = 2147483630
public let kCGMaximumWindowLevel: CGWindowLevel = 2147483631


// MARK: Login session

public let kCGSessionOnConsoleKey = "kCGSSessionOnConsoleKey"
public let kCGSessionUserIDKey = "kCGSSessionUserIDKey"
public let kCGSessionUserNameKey = "kCGSSessionUserNameKey"
public let kCGSessionLoginDoneKey = "kCGSessionLoginDoneKey"
public let kCGSessionConsoleSetKey = "kCGSSessionConsoleSetKey"

/// The window server session: this process's user, on the console.
public func CGSessionCopyCurrentDictionary() -> CFDictionary? {
    [kCGSessionOnConsoleKey: true, kCGSessionUserIDKey: Int(getuid()), kCGSessionUserNameKey: NSUserName(), kCGSessionLoginDoneKey: true] as NSDictionary
}


// MARK: Gamma tables

public typealias CGGammaValue = Float

/// The display's transfer tables. Gamma ramps aren't read from the X
/// server here: the tables come back linear (an uncorrected display).
public func CGGetDisplayTransferByTable(_ display: CGDirectDisplayID, _ capacity: UInt32, _ redTable: UnsafeMutablePointer<CGGammaValue>?,
                                        _ greenTable: UnsafeMutablePointer<CGGammaValue>?, _ blueTable: UnsafeMutablePointer<CGGammaValue>?,
                                        _ sampleCount: UnsafeMutablePointer<UInt32>?) -> CGError {
    let n = Int(min(capacity, 256))
    for i in 0..<n {
        let v = n > 1 ? CGGammaValue(i) / CGGammaValue(n - 1) : 0
        redTable?[i] = v; greenTable?[i] = v; blueTable?[i] = v
    }
    sampleCount?.pointee = UInt32(n)
    return .success
}

/// Setting gamma ramps isn't supported (software dimming through gamma has no effect).
public func CGSetDisplayTransferByTable(_ display: CGDirectDisplayID, _ tableSize: UInt32, _ redTable: UnsafePointer<CGGammaValue>?,
                                        _ greenTable: UnsafePointer<CGGammaValue>?, _ blueTable: UnsafePointer<CGGammaValue>?) -> CGError { .failure }
public func CGSetDisplayTransferByFormula(_ display: CGDirectDisplayID, _ redMin: CGGammaValue, _ redMax: CGGammaValue, _ redGamma: CGGammaValue,
                                          _ greenMin: CGGammaValue, _ greenMax: CGGammaValue, _ greenGamma: CGGammaValue,
                                          _ blueMin: CGGammaValue, _ blueMax: CGGammaValue, _ blueGamma: CGGammaValue) -> CGError { .failure }
public func CGDisplayGammaTableCapacity(_ display: CGDirectDisplayID) -> UInt32 { 256 }
public func CGDisplayRestoreColorSyncSettings() {}
