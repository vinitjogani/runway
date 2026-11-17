// Xlib, loaded at run time (dlopen "libX11.so.6"): no build dependency, and
// nothing happens without an X server (DISPLAY unset, or a Wayland session
// without XWayland). Used for global hot keys (XGrabKey) and the window
// list (_NET_CLIENT_LIST).

import Foundation
#if os(Linux)
import Glibc

public final class X11: @unchecked Sendable {
    public typealias Display = OpaquePointer
    public typealias Window = UInt
    public typealias Atom = UInt

    // Function pointers.
    public let XOpenDisplay: @convention(c) (UnsafePointer<CChar>?) -> Display?
    public let XCloseDisplay: @convention(c) (Display) -> Int32
    public let XDefaultRootWindow: @convention(c) (Display) -> Window
    public let XInternAtom: @convention(c) (Display, UnsafePointer<CChar>, Int32) -> Atom
    public let XGetWindowProperty: @convention(c) (Display, Window, Atom, Int, Int, Int32, Atom,
                                                   UnsafeMutablePointer<Atom>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<UInt>,
                                                   UnsafeMutablePointer<UInt>, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>) -> Int32
    public let XFree: @convention(c) (UnsafeMutableRawPointer?) -> Int32
    public let XGrabKey: @convention(c) (Display, Int32, UInt32, Window, Int32, Int32, Int32) -> Int32
    public let XUngrabKey: @convention(c) (Display, Int32, UInt32, Window) -> Int32
    public let XKeysymToKeycode: @convention(c) (Display, UInt) -> UInt8
    public let XConnectionNumber: @convention(c) (Display) -> Int32
    public let XPending: @convention(c) (Display) -> Int32
    public let XNextEvent: @convention(c) (Display, UnsafeMutableRawPointer) -> Int32
    public let XFlush: @convention(c) (Display) -> Int32
    public let XSync: @convention(c) (Display, Int32) -> Int32
    public let XSetErrorHandler: @convention(c) (( @convention(c) (Display?, UnsafeMutableRawPointer?) -> Int32)?) -> UnsafeMutableRawPointer?
    public let XTranslateCoordinates: @convention(c) (Display, Window, Window, Int32, Int32, UnsafeMutablePointer<Int32>,
                                                      UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Window>) -> Int32
    public let XGetGeometry: @convention(c) (Display, Window, UnsafeMutablePointer<Window>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>,
                                             UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>,
                                             UnsafeMutablePointer<UInt32>) -> Int32

    /// Xlib, if it can be loaded and DISPLAY names a server.
    public static let shared: X11? = {
        guard ProcessInfo.processInfo.environment["DISPLAY"]?.isEmpty == false else { return nil }
        guard let h = dlopen("libX11.so.6", RTLD_NOW | RTLD_LOCAL) else { return nil }
        return X11(h)
    }()

    private init?(_ h: UnsafeMutableRawPointer) {
        func sym<T>(_ name: String) -> T? { dlsym(h, name).map { unsafeBitCast($0, to: T.self) } }
        guard let a: @convention(c) (UnsafePointer<CChar>?) -> Display? = sym("XOpenDisplay"),
              let b: @convention(c) (Display) -> Int32 = sym("XCloseDisplay"),
              let c: @convention(c) (Display) -> Window = sym("XDefaultRootWindow"),
              let d: @convention(c) (Display, UnsafePointer<CChar>, Int32) -> Atom = sym("XInternAtom"),
              let e: @convention(c) (Display, Window, Atom, Int, Int, Int32, Atom, UnsafeMutablePointer<Atom>, UnsafeMutablePointer<Int32>,
                                     UnsafeMutablePointer<UInt>, UnsafeMutablePointer<UInt>, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>) -> Int32 = sym("XGetWindowProperty"),
              let f: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = sym("XFree"),
              let g: @convention(c) (Display, Int32, UInt32, Window, Int32, Int32, Int32) -> Int32 = sym("XGrabKey"),
              let i: @convention(c) (Display, Int32, UInt32, Window) -> Int32 = sym("XUngrabKey"),
              let j: @convention(c) (Display, UInt) -> UInt8 = sym("XKeysymToKeycode"),
              let k: @convention(c) (Display) -> Int32 = sym("XConnectionNumber"),
              let l: @convention(c) (Display) -> Int32 = sym("XPending"),
              let m: @convention(c) (Display, UnsafeMutableRawPointer) -> Int32 = sym("XNextEvent"),
              let n: @convention(c) (Display) -> Int32 = sym("XFlush"),
              let o: @convention(c) (Display, Int32) -> Int32 = sym("XSync"),
              let p: @convention(c) ((@convention(c) (Display?, UnsafeMutableRawPointer?) -> Int32)?) -> UnsafeMutableRawPointer? = sym("XSetErrorHandler"),
              let q: @convention(c) (Display, Window, Window, Int32, Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>,
                                     UnsafeMutablePointer<Window>) -> Int32 = sym("XTranslateCoordinates"),
              let r: @convention(c) (Display, Window, UnsafeMutablePointer<Window>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>,
                                     UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>,
                                     UnsafeMutablePointer<UInt32>) -> Int32 = sym("XGetGeometry")
        else { return nil }
        XOpenDisplay = a; XCloseDisplay = b; XDefaultRootWindow = c; XInternAtom = d; XGetWindowProperty = e; XFree = f
        XGrabKey = g; XUngrabKey = i; XKeysymToKeycode = j; XConnectionNumber = k; XPending = l; XNextEvent = m
        XFlush = n; XSync = o; XSetErrorHandler = p; XTranslateCoordinates = q; XGetGeometry = r
        // Xlib's default error handler exits the process (a hot key another
        // app already grabbed is a BadAccess): log nothing, carry on.
        _ = XSetErrorHandler { _, _ in 0 }
    }

    /// A window property as raw items (format 8, 32 → UInt).
    public func property(_ dpy: Display, _ w: Window, _ name: String) -> (format: Int32, items: [UInt], bytes: [UInt8])? {
        let atom = XInternAtom(dpy, name, 0)
        var type: Atom = 0, format: Int32 = 0, count: UInt = 0, after: UInt = 0
        var data: UnsafeMutablePointer<UInt8>?
        guard XGetWindowProperty(dpy, w, atom, 0, 1 << 16, 0, 0, &type, &format, &count, &after, &data) == 0, let data else { return nil }
        defer { _ = XFree(data) }
        switch format {
        case 32:
            let p = UnsafeRawPointer(data).assumingMemoryBound(to: UInt.self)
            return (32, Array(UnsafeBufferPointer(start: p, count: Int(count))), [])
        case 8:
            return (8, [], Array(UnsafeBufferPointer(start: data, count: Int(count))))
        default:
            return (format, [], [])
        }
    }
}
#endif
