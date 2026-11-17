// Network for Linux and Windows: NWPathMonitor over the kernel's network
// state (rtnetlink / NotifyAddrChange via RunwayNet), and NWConnection /
// NWListener over BSD sockets (TCP, UDP and Unix-domain; Linux). TLS isn't
// provided: a TLS connection fails with NWError.tls, which apps report as a
// connection failure.

@_exported import Foundation
import Dispatch
import RunwayNet

public struct NWInterface: Hashable, CustomDebugStringConvertible, Sendable {
    public enum InterfaceType: Hashable, Sendable {
        case other, wifi, cellular, wiredEthernet, loopback
    }
    public let type: InterfaceType
    public let name: String
    public let index: Int
    public var debugDescription: String { name }

    init(_ i: NetInterface) {
        name = i.name
        index = i.index
        switch i.kind {
        case .wifi: type = .wifi
        case .ethernet: type = .wiredEthernet
        case .cellular: type = .cellular
        case .loopback: type = .loopback
        case .other: type = .other
        }
    }
}

public struct NWPath: Equatable, CustomDebugStringConvertible, Sendable {
    public enum Status: Equatable, Sendable { case satisfied, unsatisfied, requiresConnection }
    public enum UnsatisfiedReason: Equatable, Sendable { case notAvailable, cellularDenied, wifiDenied, localNetworkDenied, vpnInactive }

    public let status: Status
    public let unsatisfiedReason: UnsatisfiedReason
    public let availableInterfaces: [NWInterface]
    public let isExpensive: Bool
    public let isConstrained: Bool
    public let supportsIPv4: Bool
    public let supportsIPv6: Bool
    public let supportsDNS: Bool
    public let gateways: [NWEndpoint]
    public let localEndpoint: NWEndpoint?
    public let remoteEndpoint: NWEndpoint?
    public var isUltraConstrained: Bool { false }

    public func usesInterfaceType(_ type: NWInterface.InterfaceType) -> Bool { availableInterfaces.first?.type == type }

    public var debugDescription: String {
        "\(status)" + (availableInterfaces.isEmpty ? "" : ", interface: \(availableInterfaces.map(\.name).joined(separator: ", "))")
            + (supportsIPv4 ? ", ipv4" : "") + (supportsIPv6 ? ", ipv6" : "") + (supportsDNS ? ", dns" : "") + (isExpensive ? ", expensive" : "")
    }

    public static func == (a: NWPath, b: NWPath) -> Bool {
        a.status == b.status && a.availableInterfaces == b.availableInterfaces && a.isExpensive == b.isExpensive
            && a.supportsIPv4 == b.supportsIPv4 && a.supportsIPv6 == b.supportsIPv6 && a.supportsDNS == b.supportsDNS
    }

    init(_ s: NetStatus, required: NWInterface.InterfaceType?, prohibited: [NWInterface.InterfaceType]) {
        let byName = Dictionary(s.interfaces.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var ifs = s.routeInterfaces.compactMap { byName[$0] }.filter { $0.isUp }.map(NWInterface.init)
        for i in s.interfaces where i.isUp && i.kind != .loopback && !ifs.contains(where: { $0.name == i.name }) { ifs.append(NWInterface(i)) }
        ifs.removeAll { prohibited.contains($0.type) }
        if let required { ifs.removeAll { $0.type != required } }
        let ok = s.connected && !ifs.isEmpty && (required == nil || ifs.contains { $0.type == required })
        status = ok ? .satisfied : .unsatisfied
        unsatisfiedReason = .notAvailable
        availableInterfaces = ifs
        isExpensive = ifs.first?.type == .cellular
        isConstrained = false
        supportsIPv4 = ok && s.hasIPv4Route
        supportsIPv6 = ok && s.hasIPv6Route
        supportsDNS = ok && s.dnsConfigured
        gateways = []
        localEndpoint = nil
        remoteEndpoint = nil
    }
}

public final class NWPathMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let required: NWInterface.InterfaceType?
    private let prohibited: [NWInterface.InterfaceType]
    private var token: UUID?
    private var _queue: DispatchQueue?
    private var _current: NWPath
    private var _handler: (@Sendable (NWPath) -> Void)?

    public init() { required = nil; prohibited = []; _current = NWPath(NetStatus.current(), required: nil, prohibited: []) }
    public init(requiredInterfaceType: NWInterface.InterfaceType) {
        required = requiredInterfaceType; prohibited = []
        _current = NWPath(NetStatus.current(), required: requiredInterfaceType, prohibited: [])
    }
    public init(prohibitedInterfaceTypes: [NWInterface.InterfaceType]) {
        required = nil; prohibited = prohibitedInterfaceTypes
        _current = NWPath(NetStatus.current(), required: nil, prohibited: prohibitedInterfaceTypes)
    }

    public var pathUpdateHandler: (@Sendable (NWPath) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }
    public var currentPath: NWPath { lock.lock(); defer { lock.unlock() }; return _current }
    public var queue: DispatchQueue? { lock.lock(); defer { lock.unlock() }; return _queue }

    /// Delivers the current path at once, then each change.
    public func start(queue: DispatchQueue) {
        lock.lock()
        guard token == nil else { lock.unlock(); return }
        _queue = queue
        lock.unlock()
        let id = NetMonitor.shared.observe { [weak self] in self?.refresh(force: false) }
        lock.lock(); token = id; lock.unlock()
        refresh(force: true)
    }

    private func refresh(force: Bool) {
        let p = NWPath(NetStatus.current(), required: required, prohibited: prohibited)
        lock.lock()
        let changed = force || p != _current
        _current = p
        let h = _handler, q = _queue
        lock.unlock()
        if changed, let h, let q { q.async { h(p) } }
    }

    public func cancel() {
        lock.lock(); let t = token; token = nil; lock.unlock()
        if let t { NetMonitor.shared.remove(t) }
    }

    deinit { if let token { NetMonitor.shared.remove(token) } }
}

extension NWPathMonitor: AsyncSequence {
    public typealias Element = NWPath
    public struct Iterator: AsyncIteratorProtocol {
        var base: AsyncStream<NWPath>.Iterator
        public mutating func next() async -> NWPath? { await base.next() }
    }
    public func makeAsyncIterator() -> Iterator {
        let stream = AsyncStream<NWPath> { cont in
            self.pathUpdateHandler = { cont.yield($0) }
            cont.onTermination = { [weak self] _ in self?.cancel() }
            self.start(queue: DispatchQueue(label: "runway.nwpathmonitor"))
        }
        return Iterator(base: stream.makeAsyncIterator())
    }
}
