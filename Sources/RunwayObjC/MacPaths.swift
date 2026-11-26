// macOS developer-tool locations in Mac code — the Command Line Tools'
// /Library/Developer/CommandLineTools/usr/bin/git, Xcode's
// /Applications/Xcode.app/Contents/Developer/usr/bin/swift — name tools
// that live elsewhere on other systems. The transpiler turns such string
// literals into `MacPaths.hostTool(...)`, which gives the host's tool of the
// same name (on the PATH, then the usual bin directories), or the path as
// written when the host has none.

import Foundation

public enum MacPaths {
    /// Literal prefixes that name a macOS developer directory's tools.
    public static let developerToolPrefixes = [
        "/Library/Developer/CommandLineTools/usr/bin/",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/",
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/",
    ]

    /// Whether `literal` names a tool in a macOS developer directory.
    public static func isDeveloperToolPath(_ literal: String) -> Bool {
        developerToolPrefixes.contains { literal.hasPrefix($0) && literal.count > $0.count && !literal.dropFirst($0.count).contains("/") }
    }

    public static func hostTool(_ path: String) -> String {
        #if os(macOS)
        return path
        #else
        guard isDeveloperToolPath(path), let name = path.split(separator: "/").last.map(String.init) else { return path }
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = env.split(separator: ":").map(String.init) + ["/usr/local/bin", "/usr/bin", "/bin"]
        for dir in dirs where !dir.isEmpty {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return path
        #endif
    }
}
