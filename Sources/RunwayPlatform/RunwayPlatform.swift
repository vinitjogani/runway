// Picks the platform's backend: GTK 4 on Linux, the drawn backend (over
// Win32) on Windows. Set RUNWAY_BACKEND=headless to run with no display
// (tests, CI, `--headless`), or RUNWAY_BACKEND=drawn on Linux for the drawn
// backend over GTK: the same controls and behaviour as on Windows.

import Foundation
import RunwayCore
#if os(Linux)
import RunwayGTK
import CGtk
import RunwayDrawn
#elseif os(Windows)
import RunwayDrawn
#endif

@MainActor public enum RunwayPlatform {
    public static func installDefaultBackend() {
        guard !Runway.isInstalled else { return }
        Runway.install(makeBackend())
    }

    public static func makeBackend() -> Backend {
        if ProcessInfo.processInfo.environment["RUNWAY_BACKEND"] == "headless" { return HeadlessBackend() }
        #if os(Linux)
        // No display server (SSH, CI, unit tests): GTK can't start, so run
        // headless rather than crash, and say so once.
        let env = ProcessInfo.processInfo.environment
        if (env["DISPLAY"] ?? "").isEmpty, (env["WAYLAND_DISPLAY"] ?? "").isEmpty, env["RUNWAY_BACKEND"] != "gtk" {
            FileHandle.standardError.write(Data("runway: no display (DISPLAY/WAYLAND_DISPLAY unset); running headless\n".utf8))
            return HeadlessBackend()
        }
        RuntimeDefaults.applyBeforeToolkitInit()
        if env["RUNWAY_BACKEND"] == "drawn" { return DrawnBackend() }
        return GTKBackend()
        #elseif os(Windows)
        return DrawnBackend()
        #else
        return HeadlessBackend()
        #endif
    }
}

#if os(Linux)
/// Toolkit settings tuned for small, idle-quiet desktop apps, applied before
/// GTK initialises (so before any of its threads exist). Each one only fills
/// in what the user hasn't set: an explicit GSK_RENDERER, GDK_DEBUG,
/// GDK_DISABLE or MALLOC_ARENA_MAX always wins, and RUNWAY_RENDERER=gpu keeps
/// GTK's own defaults entirely.
///
/// Measured with Tools/measure.sh (gallery, release, Xvfb + llvmpipe):
///
/// - GSK's GL/Vulkan renderers load the GPU driver stack (Mesa: libLLVM,
///   gallium, a shader cache thread, a pool of rasteriser threads), which on
///   its own outweighs a SwiftUI app. Runway draws native widgets and Cairo
///   shapes, which the Cairo renderer paints with damage tracking and no GPU
///   context, so it is the default: about 126 → 59 MB resident, 14 → 5
///   threads, and launch about a third faster.
/// - With the Cairo renderer GDK still opens a GL context on X11 to choose a
///   visual; disabling GL skips loading the driver at all (most of the win
///   above). Nothing in Runway uses GL directly.
/// - glibc gives each thread that allocates its own malloc arena; GTK's few
///   helper threads (gmain, dconf, the GIO pool) don't need them. Two arenas
///   keep that memory bounded at no measurable cost.
///
/// Accessibility is deliberately left on: the AT-SPI bridge costs little
/// when no screen reader is running and is needed when one is.
enum RuntimeDefaults {
    static func applyBeforeToolkitInit() {
        let env = ProcessInfo.processInfo.environment
        if env["RUNWAY_RENDERER"]?.lowercased() != "gpu", env["GSK_RENDERER"] == nil {
            setenv("GSK_RENDERER", "cairo", 1)
            // GTK 4.16 moved feature switches from GDK_DEBUG to GDK_DISABLE.
            if gtk_get_major_version() == 4, gtk_get_minor_version() < 16 {
                if env["GDK_DEBUG"] == nil { setenv("GDK_DEBUG", "gl-disable", 1) }
            } else if env["GDK_DISABLE"] == nil {
                setenv("GDK_DISABLE", "gl,vulkan", 1)
            }
        }
        #if canImport(Glibc)
        if env["MALLOC_ARENA_MAX"] == nil { _ = glibc_mallopt(-8 /* M_ARENA_MAX */, 2) }
        #endif
    }
}

#if canImport(Glibc)
/// glibc's mallopt(3) (malloc.h isn't part of the Glibc module).
@_silgen_name("mallopt") private func glibc_mallopt(_ param: Int32, _ value: Int32) -> Int32
#endif
#endif
