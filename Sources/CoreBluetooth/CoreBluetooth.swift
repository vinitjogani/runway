// CoreBluetooth: the central role's API answering as a Mac with Bluetooth
// switched off. Managers report `.poweredOff` to their delegate; scans
// find nothing, retrieval returns no peripherals, connections fail.
// (BlueZ over D-Bus would be the native route.)

@_exported import Foundation

public enum CBManagerState: Int, Sendable { case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn }
public enum CBManagerAuthorization: Int, Sendable { case notDetermined, restricted, denied, allowedAlways }
public enum CBPeripheralState: Int, Sendable { case disconnected, connecting, connected, disconnecting }
public enum CBCharacteristicWriteType: Int, Sendable { case withResponse, withoutResponse }

public struct CBCharacteristicProperties: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let broadcast = Self(rawValue: 1), read = Self(rawValue: 2), writeWithoutResponse = Self(rawValue: 4),
                      write = Self(rawValue: 8), notify = Self(rawValue: 16), indicate = Self(rawValue: 32)
}

public let CBCentralManagerScanOptionAllowDuplicatesKey = "kCBScanOptionAllowDuplicates"
public let CBCentralManagerScanOptionSolicitedServiceUUIDsKey = "kCBScanOptionSolicitedServiceUUIDs"
public let CBCentralManagerOptionShowPowerAlertKey = "kCBInitOptionShowPowerAlert"
public let CBCentralManagerOptionRestoreIdentifierKey = "kCBInitOptionRestoreIdentifier"
public let CBAdvertisementDataLocalNameKey = "kCBAdvDataLocalName"
public let CBAdvertisementDataServiceUUIDsKey = "kCBAdvDataServiceUUIDs"
public let CBAdvertisementDataManufacturerDataKey = "kCBAdvDataManufacturerData"
public let CBConnectPeripheralOptionNotifyOnDisconnectionKey = "kCBConnectOptionNotifyOnDisconnection"

public let CBErrorDomain = "CBErrorDomain"
public struct CBError: Error, Sendable {
    public enum Code: Int, Sendable { case unknown = 0, invalidParameters, invalidHandle, notConnected, outOfSpace, operationCancelled,
                                           connectionTimeout, peripheralDisconnected, uuidNotAllowed, alreadyAdvertising, connectionFailed }
    public let code: Code
    public init(_ code: Code) { self.code = code }
}

open class CBUUID: NSObject, NSCopying, @unchecked Sendable {
    public let uuidString: String
    public init(string: String) { uuidString = string.uppercased() }
    public init(nsuuid: UUID) { uuidString = nsuuid.uuidString }
    public init(data: Data) { uuidString = data.map { String(format: "%02X", $0) }.joined() }
    open var data: Data {
        var out = Data()
        var hex = uuidString.replacingOccurrences(of: "-", with: "")[...]
        while hex.count >= 2 { out.append(UInt8(hex.prefix(2), radix: 16) ?? 0); hex = hex.dropFirst(2) }
        return out
    }
    open override func isEqual(_ object: Any?) -> Bool { (object as? CBUUID)?.uuidString == uuidString }
    open override var hash: Int { uuidString.hashValue }
    open override var description: String { uuidString }
    open func copy(with zone: NSZone? = nil) -> Any { self }
}

open class CBAttribute: NSObject, @unchecked Sendable {
    open var uuid: CBUUID
    init(uuid: CBUUID) { self.uuid = uuid }
}

open class CBDescriptor: CBAttribute, @unchecked Sendable {
    open var value: Any?
    open unowned(unsafe) var characteristic: CBCharacteristic?
}

open class CBCharacteristic: CBAttribute, @unchecked Sendable {
    open var value: Data?
    open var properties: CBCharacteristicProperties = []
    open var isNotifying = false
    open var descriptors: [CBDescriptor]?
    open weak var service: CBService?
}

open class CBService: CBAttribute, @unchecked Sendable {
    open var isPrimary = true
    open var characteristics: [CBCharacteristic]?
    open var includedServices: [CBService]?
    open weak var peripheral: CBPeripheral?
}

open class CBPeer: NSObject, @unchecked Sendable {
    public let identifier: UUID
    init(identifier: UUID) { self.identifier = identifier }
}

public protocol CBPeripheralDelegate: AnyObject {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService])
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?)
    func peripheralDidUpdateName(_ peripheral: CBPeripheral)
}

extension CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {}
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {}
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {}
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {}
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {}
    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {}
    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {}
    public func peripheralDidUpdateName(_ peripheral: CBPeripheral) {}
}

open class CBPeripheral: CBPeer, @unchecked Sendable {
    open weak var delegate: CBPeripheralDelegate?
    open var name: String?
    open var state: CBPeripheralState = .disconnected
    open var services: [CBService]?
    open var canSendWriteWithoutResponse: Bool { false }

    open func discoverServices(_ serviceUUIDs: [CBUUID]?) { report { $0.peripheral(self, didDiscoverServices: CBError(.notConnected)) } }
    open func discoverCharacteristics(_ uuids: [CBUUID]?, for service: CBService) {
        report { $0.peripheral(self, didDiscoverCharacteristicsFor: service, error: CBError(.notConnected)) }
    }
    open func discoverIncludedServices(_ uuids: [CBUUID]?, for service: CBService) {}
    open func discoverDescriptors(for characteristic: CBCharacteristic) {}
    open func readValue(for characteristic: CBCharacteristic) {
        report { $0.peripheral(self, didUpdateValueFor: characteristic, error: CBError(.notConnected)) }
    }
    open func readValue(for descriptor: CBDescriptor) {}
    open func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        if type == .withResponse { report { $0.peripheral(self, didWriteValueFor: characteristic, error: CBError(.notConnected)) } }
    }
    open func writeValue(_ data: Data, for descriptor: CBDescriptor) {}
    open func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        report { $0.peripheral(self, didUpdateNotificationStateFor: characteristic, error: CBError(.notConnected)) }
    }
    open func readRSSI() { report { $0.peripheral(self, didReadRSSI: 0, error: CBError(.notConnected)) } }
    open func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { 0 }

    private func report(_ body: @escaping (CBPeripheralDelegate) -> Void) {
        DispatchQueue.main.async { [weak self] in if let d = self?.delegate { body(d) } }
    }
}

public protocol CBCentralManagerDelegate: AnyObject {
    func centralManagerDidUpdateState(_ central: CBCentralManager)
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber)
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral)
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?)
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?)
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any])
}

extension CBCentralManagerDelegate {
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {}
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {}
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {}
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {}
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {}
}

open class CBManager: NSObject, @unchecked Sendable {
    open var state: CBManagerState { .poweredOff }
    open var authorization: CBManagerAuthorization { .allowedAlways }
    open class var authorization: CBManagerAuthorization { .allowedAlways }
}

open class CBCentralManager: CBManager, @unchecked Sendable {
    open weak var delegate: CBCentralManagerDelegate?
    let queue: DispatchQueue
    open private(set) var isScanning = false

    public init(delegate: CBCentralManagerDelegate?, queue: DispatchQueue?, options: [String: Any]? = nil) {
        self.delegate = delegate
        self.queue = queue ?? .main
        super.init()
        self.queue.async { [weak self] in
            guard let self else { return }
            self.delegate?.centralManagerDidUpdateState(self)
        }
    }
    public convenience override init() { self.init(delegate: nil, queue: nil) }

    open func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]? = nil) {}
    open func stopScan() { isScanning = false }
    open func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [CBPeripheral] { [] }
    open func retrieveConnectedPeripherals(withServices serviceUUIDs: [CBUUID]) -> [CBPeripheral] { [] }
    open func connect(_ peripheral: CBPeripheral, options: [String: Any]? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.delegate?.centralManager(self, didFailToConnect: peripheral, error: CBError(.connectionFailed))
        }
    }
    open func cancelPeripheralConnection(_ peripheral: CBPeripheral) {}
}
