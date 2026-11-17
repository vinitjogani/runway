// ServiceManagement for Linux and Windows. SMAppService.mainApp ("open at
// login") maps to an XDG autostart entry (~/.config/autostart/<app>.desktop)
// on Linux, and to the HKCU …\CurrentVersion\Run value on Windows.

import Foundation

public final class SMAppService: @unchecked Sendable {
    public enum Status: Int, Sendable { case notRegistered, enabled, requiresApproval, notFound }

    public static let mainApp = SMAppService()
    public static func agent(plistName: String) -> SMAppService { SMAppService() }
    public static func loginItem(identifier: String) -> SMAppService { SMAppService() }
    public static func openSystemSettingsLoginItems() {}

    var appName: String {
        let id = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return id.replacingOccurrences(of: "/", with: "-")
    }

    #if os(Windows)
    private var runKey: String { #"HKCU\Software\Microsoft\Windows\CurrentVersion\Run"# }
    public var status: Status {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: #"C:\Windows\System32\reg.exe"#)
        p.arguments = ["query", runKey, "/v", appName]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return .notFound }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? .enabled : .notRegistered
    }
    public func register() throws {
        try reg(["add", runKey, "/v", appName, "/t", "REG_SZ", "/d", "\"\(CommandLine.arguments[0])\"", "/f"])
    }
    public func unregister() throws { try reg(["delete", runKey, "/v", appName, "/f"]) }
    private func reg(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: #"C:\Windows\System32\reg.exe"#)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw CocoaError(.fileWriteUnknown) }
    }
    #else
    var entry: URL {
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return config.appendingPathComponent("autostart/\(appName).desktop")
    }
    public var status: Status { FileManager.default.fileExists(atPath: entry.path) ? .enabled : .notRegistered }
    public func register() throws {
        let exec = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
        let desktop = """
        [Desktop Entry]
        Type=Application
        Name=\(name)
        Exec="\(exec)" --launched-at-login
        X-GNOME-Autostart-enabled=true
        """
        try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try desktop.write(to: entry, atomically: true, encoding: .utf8)
    }
    public func unregister() throws {
        if FileManager.default.fileExists(atPath: entry.path) { try FileManager.default.removeItem(at: entry) }
    }
    #endif
}
