// CoreWLAN: Wi-Fi interfaces and their state. Interfaces come from
// /sys/class/net (those with a `wireless` directory); details a Mac reads
// from the driver (SSID, RSSI, channel) need NetworkManager or nl80211 and
// read as unknown (nil / 0) here. Event monitoring delivers nothing.

@_exported import Foundation

public enum CWPHYMode: Int, Sendable { case modeNone = 0, mode11a, mode11b, mode11g, mode11n, mode11ac, mode11ax }
public enum CWInterfaceMode: Int, Sendable { case none = 0, station, IBSS, hostAP }
public enum CWSecurity: Int, Sendable {
    case none = 0, WEP, wpaPersonal, wpaPersonalMixed, wpa2Personal, personal, dynamicWEP, wpaEnterprise, wpaEnterpriseMixed,
         wpa2Enterprise, enterprise, wpa3Personal, wpa3Enterprise, wpa3Transition, OWE, oweTransition, unknown = 9223372036854775807
}
public enum CWChannelWidth: Int, Sendable { case widthUnknown = 0, width20MHz, width40MHz, width80MHz, width160MHz }
public enum CWChannelBand: Int, Sendable { case bandUnknown = 0, band2GHz, band5GHz, band6GHz }
public enum CWEventType: Int, Sendable {
    case none = 0, powerDidChange, ssidDidChange, bssidDidChange, countryCodeDidChange, linkDidChange, linkQualityDidChange,
         modeDidChange, scanCacheUpdated, btCoexStats, unknown = 9223372036854775807
}

open class CWChannel: NSObject, @unchecked Sendable {
    open var channelNumber: Int = 0
    open var channelWidth: CWChannelWidth = .widthUnknown
    open var channelBand: CWChannelBand = .bandUnknown
}

open class CWNetwork: NSObject, @unchecked Sendable {
    open var ssid: String?
    open var bssid: String?
    open var rssiValue: Int = 0
    open var noiseMeasurement: Int = 0
    open var wlanChannel: CWChannel?
    open func supportsSecurity(_ security: CWSecurity) -> Bool { false }
}

open class CWInterface: NSObject, @unchecked Sendable {
    public let interfaceName: String?
    public init(interfaceName name: String?) { interfaceName = name }
    public override convenience init() { self.init(interfaceName: CWWiFiClient.interfaceNames()?.first) }

    private func sys(_ file: String) -> String? {
        guard let n = interfaceName else { return nil }
        return (try? String(contentsOfFile: "/sys/class/net/\(n)/\(file)", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    open func powerOn() -> Bool { sys("operstate") == "up" }
    open func serviceActive() -> Bool { powerOn() }
    open func hardwareAddress() -> String? { sys("address") }
    open func ssid() -> String? { nil }
    open func ssidData() -> Data? { nil }
    open func bssid() -> String? { nil }
    open func rssiValue() -> Int { 0 }
    open func noiseMeasurement() -> Int { 0 }
    open func transmitRate() -> Double { 0 }
    open func transmitPower() -> Int { 0 }
    open func security() -> CWSecurity { .unknown }
    open func activePHYMode() -> CWPHYMode { .modeNone }
    open func interfaceMode() -> CWInterfaceMode { powerOn() ? .station : .none }
    open func wlanChannel() -> CWChannel? { nil }
    open func countryCode() -> String? { nil }
    open func supportedWLANChannels() -> Set<CWChannel>? { [] }
    open func scanForNetworks(withName networkName: String?) throws -> Set<CWNetwork> { [] }
    open func scanForNetworks(withSSID ssid: Data?) throws -> Set<CWNetwork> { [] }
    open func cachedScanResults() -> Set<CWNetwork>? { [] }
    open func disassociate() {}
}

public protocol CWEventDelegate: AnyObject {
    func clientConnectionInterrupted()
    func clientConnectionInvalidated()
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String)
    func ssidDidChangeForWiFiInterface(withName interfaceName: String)
    func bssidDidChangeForWiFiInterface(withName interfaceName: String)
    func linkDidChangeForWiFiInterface(withName interfaceName: String)
    func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double)
}

extension CWEventDelegate {
    public func clientConnectionInterrupted() {}
    public func clientConnectionInvalidated() {}
    public func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {}
    public func ssidDidChangeForWiFiInterface(withName interfaceName: String) {}
    public func bssidDidChangeForWiFiInterface(withName interfaceName: String) {}
    public func linkDidChangeForWiFiInterface(withName interfaceName: String) {}
    public func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double) {}
}

open class CWWiFiClient: NSObject, @unchecked Sendable {
    public static let shared = CWWiFiClient()
    open weak var delegate: CWEventDelegate?
    public override init() {}

    open class func interfaceNames() -> [String]? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/sys/class/net")) ?? []
        return names.filter { FileManager.default.fileExists(atPath: "/sys/class/net/\($0)/wireless") }.sorted()
    }
    open func interface() -> CWInterface? { Self.interfaceNames()?.first.map { CWInterface(interfaceName: $0) } }
    open func interface(withName name: String?) -> CWInterface? { name.map { CWInterface(interfaceName: $0) } }
    open func interfaces() -> [CWInterface]? { Self.interfaceNames()?.map { CWInterface(interfaceName: $0) } }
    open func startMonitoringEvent(with type: CWEventType) throws {}
    open func stopMonitoringEvent(with type: CWEventType) throws {}
    open func stopMonitoringAllEvents() throws {}
}
