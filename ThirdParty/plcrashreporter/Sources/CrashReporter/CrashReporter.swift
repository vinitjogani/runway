// PLCrashReporter's API with no crash handler behind it: `enable()` reports
// failure and there is never a pending report.

import Foundation

public enum PLCrashReporterSignalHandlerType: UInt { case BSD = 0, mach = 1 }

public struct PLCrashReporterSymbolicationStrategy: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let none = PLCrashReporterSymbolicationStrategy([])
    public static let symbolTable = PLCrashReporterSymbolicationStrategy(rawValue: 1)
    public static let objC = PLCrashReporterSymbolicationStrategy(rawValue: 2)
    public static let all = PLCrashReporterSymbolicationStrategy(rawValue: 3)
}

open class PLCrashReporterConfig: NSObject {
    public let signalHandlerType: PLCrashReporterSignalHandlerType
    public let symbolicationStrategy: PLCrashReporterSymbolicationStrategy
    public init(signalHandlerType: PLCrashReporterSignalHandlerType, symbolicationStrategy: PLCrashReporterSymbolicationStrategy) {
        self.signalHandlerType = signalHandlerType
        self.symbolicationStrategy = symbolicationStrategy
        super.init()
    }
    public convenience init(signalHandlerType: PLCrashReporterSignalHandlerType, symbolicationStrategy: PLCrashReporterSymbolicationStrategy,
                            shouldRegisterUncaughtExceptionHandler: Bool) {
        self.init(signalHandlerType: signalHandlerType, symbolicationStrategy: symbolicationStrategy)
    }
    public static func defaultConfiguration() -> PLCrashReporterConfig { PLCrashReporterConfig(signalHandlerType: .BSD, symbolicationStrategy: []) }
}

open class PLCrashReporter: NSObject {
    public init?(configuration: PLCrashReporterConfig) { super.init() }
    public override init() { super.init() }
    public static func shared() -> PLCrashReporter { PLCrashReporter() }

    /// False: crash reporting isn't available on this platform.
    @discardableResult public func enable() -> Bool { false }
    public func enableAndReturnError() throws {
        throw NSError(domain: "PLCrashReporterErrorDomain", code: 0, userInfo: [NSLocalizedDescriptionKey: "Crash reporting isn't available on this platform."])
    }
    public func hasPendingCrashReport() -> Bool { false }
    public func loadPendingCrashReportData() -> Data? { nil }
    public func loadPendingCrashReportDataAndReturnError() throws -> Data { Data() }
    @discardableResult public func purgePendingCrashReport() -> Bool { true }
    public func generateLiveReport() -> Data? { nil }
    public var crashReportPath: String? { nil }
}

public struct PLCrashReportTextFormat: RawRepresentable, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
}
public let PLCrashReportTextFormatiOS = PLCrashReportTextFormat(rawValue: 0)

open class PLCrashReport: NSObject {
    public init(data: Data) throws {
        throw NSError(domain: "PLCrashReporterErrorDomain", code: 0, userInfo: [NSLocalizedDescriptionKey: "No crash reports on this platform."])
    }
}

open class PLCrashReportTextFormatter: NSObject {
    public static func stringValue(for report: PLCrashReport, with format: PLCrashReportTextFormat) -> String? { nil }
}
