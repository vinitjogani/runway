// NWEndpoint, NWParameters, NWError, NWConnection and NWListener over
// sockets. Each connection does its socket work on a private serial queue
// and reads when a dispatch read source says the socket is readable; the
// app's handlers run on the queue it passed to start(queue:).

import Foundation
import Dispatch
#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

// MARK: Endpoints

public struct IPv4Address: Hashable, CustomDebugStringConvertible, Sendable {
    public let rawValue: Data
    public init?(_ string: String) {
        var a = in_addr()
        guard inet_pton(AF_INET, string, &a) == 1 else { return nil }
        rawValue = withUnsafeBytes(of: &a) { Data($0) }
    }
    public init?(_ rawValue: Data) { guard rawValue.count == 4 else { return nil }; self.rawValue = rawValue }
    public static let any = IPv4Address("0.0.0.0")!
    public static let loopback = IPv4Address("127.0.0.1")!
    public static let broadcast = IPv4Address("255.255.255.255")!
    public var debugDescription: String { rawValue.map(String.init).joined(separator: ".") }
    public var isLoopback: Bool { rawValue.first == 127 }
}

public struct IPv6Address: Hashable, CustomDebugStringConvertible, Sendable {
    public let rawValue: Data
    public init?(_ string: String) {
        var a = in6_addr()
        guard inet_pton(AF_INET6, string, &a) == 1 else { return nil }
        rawValue = withUnsafeBytes(of: &a) { Data($0) }
    }
    public init?(_ rawValue: Data) { guard rawValue.count == 16 else { return nil }; self.rawValue = rawValue }
    public static let any = IPv6Address("::")!
    public static let loopback = IPv6Address("::1")!
    public var debugDescription: String {
        var out = [CChar](repeating: 0, count: 64)
        _ = rawValue.withUnsafeBytes { inet_ntop(AF_INET6, $0.baseAddress, &out, 64) }
        return String(cString: out)
    }
    public var isLoopback: Bool { self == .loopback }
}

public enum NWEndpoint: Hashable, CustomDebugStringConvertible, Sendable {
    public enum Host: Hashable, CustomDebugStringConvertible, ExpressibleByStringLiteral, Sendable {
        case name(String, NWInterface?)
        case ipv4(IPv4Address)
        case ipv6(IPv6Address)
        public init(_ string: String) {
            if let a = IPv4Address(string) { self = .ipv4(a) } else if let a = IPv6Address(string) { self = .ipv6(a) } else { self = .name(string, nil) }
        }
        public init(stringLiteral value: String) { self.init(value) }
        public var debugDescription: String {
            switch self {
            case .name(let n, _): return n
            case .ipv4(let a): return a.debugDescription
            case .ipv6(let a): return a.debugDescription
            }
        }
        public var interface: NWInterface? { if case .name(_, let i) = self { return i }; return nil }
    }

    public struct Port: Hashable, CustomDebugStringConvertible, ExpressibleByIntegerLiteral, RawRepresentable, Sendable {
        public let rawValue: UInt16
        public init?(rawValue: UInt16) { self.rawValue = rawValue }
        public init(integerLiteral value: UInt16) { rawValue = value }
        public init?(_ string: String) {
            if let v = UInt16(string) { rawValue = v; return }
            let known: [String: UInt16] = ["http": 80, "https": 443, "ssh": 22, "smtp": 25, "imap": 143, "imaps": 993, "socks": 1080]
            guard let v = known[string] else { return nil }
            rawValue = v
        }
        public static let any: Port = 0
        public static let ssh: Port = 22
        public static let smtp: Port = 25
        public static let http: Port = 80
        public static let pop: Port = 110
        public static let imap: Port = 143
        public static let https: Port = 443
        public static let imaps: Port = 993
        public static let socks: Port = 1080
        public var debugDescription: String { "\(rawValue)" }
    }

    case hostPort(host: Host, port: Port)
    case service(name: String, type: String, domain: String, interface: NWInterface?)
    case unix(path: String)
    case url(URL)
    case opaque(String)

    public var debugDescription: String {
        switch self {
        case .hostPort(let h, let p): return "\(h.debugDescription):\(p.rawValue)"
        case .service(let n, let t, let d, _): return "\(n).\(t)\(d)"
        case .unix(let p): return p
        case .url(let u): return u.absoluteString
        case .opaque(let s): return s
        }
    }
    public var interface: NWInterface? { nil }
}

// MARK: Errors

public typealias DNSServiceErrorType = Int32

public enum NWError: Error, Equatable, CustomDebugStringConvertible, LocalizedError, Sendable {
    case posix(POSIXErrorCode)
    case dns(DNSServiceErrorType)
    case tls(Int32)
    public var debugDescription: String {
        switch self {
        case .posix(let c): return "POSIXErrorCode(rawValue: \(c.rawValue)): \(String(cString: strerror(c.rawValue)))"
        case .dns(let e): return "DNS error \(e)"
        case .tls(let s): return "TLS error \(s)"
        }
    }
    public var errorDescription: String? { debugDescription }
    public var errorCode: Int32 {
        switch self { case .posix(let c): return c.rawValue; case .dns(let e): return e; case .tls(let s): return s }
    }
}

// MARK: Protocols and parameters

public class NWProtocolOptions: @unchecked Sendable { init() {} }
public enum NWProtocolTCP {
    public final class Options: NWProtocolOptions, @unchecked Sendable {
        public var noDelay = false
        public var enableKeepalive = false
        public var keepaliveIdle = 0
        public var keepaliveInterval = 0
        public var keepaliveCount = 0
        public var connectionTimeout = 0
        public var persistTimeout = 0
        public var enableFastOpen = false
        public var noPush = false
        public var maximumSegmentSize = 0
        public var disableAckStretching = false
        public var disableECN = false
        public override init() {}
    }
}
public enum NWProtocolUDP {
    public final class Options: NWProtocolOptions, @unchecked Sendable {
        public var preferNoChecksum = false
        public override init() {}
    }
}
public enum NWProtocolTLS {
    public final class Options: NWProtocolOptions, @unchecked Sendable {
        public override init() {}
    }
}
public enum NWProtocolWebSocket {
    public final class Options: NWProtocolOptions, @unchecked Sendable {
        public var autoReplyPing = false
        public init(_ version: Int = 13) {}
    }
}

public final class NWParameters: @unchecked Sendable, CustomDebugStringConvertible {
    public enum ServiceClass: Sendable { case bestEffort, background, interactiveVideo, interactiveVoice, responsiveData, signaling }
    public enum MultipathServiceType: Sendable { case disabled, handover, interactive, aggregate }
    public enum ExpiredDNSBehavior: Sendable { case systemDefault, allow, prohibit }

    let transport: Int32   // SOCK_STREAM or SOCK_DGRAM
    let tls: Bool
    public var requiredLocalEndpoint: NWEndpoint?
    public var requiredInterfaceType: NWInterface.InterfaceType = .other
    public var requiredInterface: NWInterface?
    public var prohibitedInterfaceTypes: [NWInterface.InterfaceType]?
    public var prohibitExpensivePaths = false
    public var prohibitConstrainedPaths = false
    public var allowLocalEndpointReuse = false
    public var acceptLocalOnly = false
    public var includePeerToPeer = false
    public var allowFastOpen = false
    public var preferNoProxies = false
    public var serviceClass: ServiceClass = .bestEffort
    public var multipathServiceType: MultipathServiceType = .disabled
    public var expiredDNSBehavior: ExpiredDNSBehavior = .systemDefault

    init(transport: Int32, tls: Bool) { self.transport = transport; self.tls = tls }
    public convenience init() { self.init(transport: Int32(NWParameters.stream), tls: false) }
    public convenience init(tls: NWProtocolTLS.Options?, tcp: NWProtocolTCP.Options = .init()) { self.init(transport: Int32(NWParameters.stream), tls: tls != nil) }
    public convenience init(dtls: NWProtocolTLS.Options?, udp: NWProtocolUDP.Options = .init()) { self.init(transport: Int32(NWParameters.dgram), tls: dtls != nil) }

    #if os(Linux)
    static let stream = Int(SOCK_STREAM.rawValue)
    static let dgram = Int(SOCK_DGRAM.rawValue)
    #else
    static let stream = 1
    static let dgram = 2
    #endif

    public class var tcp: NWParameters { NWParameters(transport: Int32(stream), tls: false) }
    public class var udp: NWParameters { NWParameters(transport: Int32(dgram), tls: false) }
    public class var tls: NWParameters { NWParameters(transport: Int32(stream), tls: true) }
    public class var dtls: NWParameters { NWParameters(transport: Int32(dgram), tls: true) }
    public class var quic: NWParameters { NWParameters(transport: Int32(dgram), tls: true) }

    public func copy() -> NWParameters {
        let p = NWParameters(transport: transport, tls: tls)
        p.requiredLocalEndpoint = requiredLocalEndpoint; p.allowLocalEndpointReuse = allowLocalEndpointReuse
        p.acceptLocalOnly = acceptLocalOnly; p.includePeerToPeer = includePeerToPeer
        return p
    }
    public var debugDescription: String { transport == Int32(NWParameters.dgram) ? "udp" : (tls ? "tls" : "tcp") }
}

// MARK: Sockets

enum Sock {
    static var lastError: NWError { .posix(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    /// Socket address(es) for an endpoint (resolving names).
    static func addresses(_ e: NWEndpoint, type: Int32) -> Result<[(Int32, Data)], NWError> {
        #if os(Linux)
        switch e {
        case .unix(let path):
            var a = sockaddr_un()
            a.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: a.sun_path) else { return .failure(.posix(.ENAMETOOLONG)) }
            withUnsafeMutableBytes(of: &a.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = b } }
            return .success([(AF_UNIX, withUnsafeBytes(of: &a) { Data($0) })])
        case .hostPort(let host, let port):
            var hints = addrinfo()
            hints.ai_socktype = type
            hints.ai_flags = AI_ADDRCONFIG
            var res: UnsafeMutablePointer<addrinfo>?
            let rc = getaddrinfo(host.debugDescription, String(port.rawValue), &hints, &res)
            guard rc == 0, let first = res else { return .failure(.dns(rc)) }
            defer { freeaddrinfo(first) }
            var out: [(Int32, Data)] = []
            var p: UnsafeMutablePointer<addrinfo>? = first
            while let a = p {
                out.append((a.pointee.ai_family, Data(bytes: a.pointee.ai_addr, count: Int(a.pointee.ai_addrlen))))
                p = a.pointee.ai_next
            }
            return .success(out)
        case .url(let u):
            guard let h = u.host else { return .failure(.posix(.EINVAL)) }
            let port = u.port.map { UInt16($0) } ?? (u.scheme == "https" ? 443 : 80)
            return addresses(.hostPort(host: .init(h), port: .init(rawValue: port)!), type: type)
        default:
            return .failure(.posix(.EAFNOSUPPORT))
        }
        #else
        return .failure(.posix(.EOPNOTSUPP))
        #endif
    }

    static func connect(_ e: NWEndpoint, type: Int32) -> Result<Int32, NWError> {
        #if os(Linux)
        switch addresses(e, type: type) {
        case .failure(let err): return .failure(err)
        case .success(let addrs):
            var last: NWError = .posix(.ECONNREFUSED)
            for (family, addr) in addrs {
                let fd = socket(family, type | Int32(SOCK_CLOEXEC.rawValue), 0)
                guard fd >= 0 else { last = lastError; continue }
                let rc = addr.withUnsafeBytes { Glibc.connect(fd, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(addr.count)) }
                if rc == 0 { return .success(fd) }
                last = lastError
                close(fd)
            }
            return .failure(last)
        }
        #else
        return .failure(.posix(.EOPNOTSUPP))
        #endif
    }
}

// MARK: Connection

public final class NWConnection: @unchecked Sendable, CustomDebugStringConvertible {
    public enum State: Equatable, Sendable {
        case setup
        case waiting(NWError)
        case preparing
        case ready
        case failed(NWError)
        case cancelled
    }

    public final class ContentContext: @unchecked Sendable {
        public let identifier: String
        public let isFinal: Bool
        public var expirationMilliseconds: UInt64
        public var relativePriority: Double
        public init(identifier: String, expiration: UInt64 = 0, priority: Double = 0.5, isFinal: Bool = false,
                    antecedent: ContentContext? = nil, metadata: [Any]? = []) {
            self.identifier = identifier; self.isFinal = isFinal; expirationMilliseconds = expiration; relativePriority = priority
        }
        public static let defaultMessage = ContentContext(identifier: "defaultMessage")
        public static let finalMessage = ContentContext(identifier: "finalMessage", isFinal: true)
        public static let defaultStream = ContentContext(identifier: "defaultStream")
    }

    public enum SendCompletion {
        case contentProcessed(@Sendable (NWError?) -> Void)
        case idempotent
    }

    public let endpoint: NWEndpoint
    public let parameters: NWParameters
    public var currentPath: NWPath? { nil }

    private let lock = NSLock()
    private let io: DispatchQueue
    private var queue: DispatchQueue?
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var eof = false
    private var receives: [(min: Int, max: Int, message: Bool, done: (Data?, ContentContext?, Bool, NWError?) -> Void)] = []
    private var _state: State = .setup
    private var _stateHandler: (@Sendable (State) -> Void)?
    private var _viabilityHandler: (@Sendable (Bool) -> Void)?

    public var stateUpdateHandler: (@Sendable (State) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _stateHandler }
        set { lock.lock(); _stateHandler = newValue; lock.unlock() }
    }
    public var viabilityUpdateHandler: (@Sendable (Bool) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _viabilityHandler }
        set { lock.lock(); _viabilityHandler = newValue; lock.unlock() }
    }
    public var betterPathUpdateHandler: (@Sendable (Bool) -> Void)?
    public var pathUpdateHandler: (@Sendable (NWPath) -> Void)?
    public var state: State { lock.lock(); defer { lock.unlock() }; return _state }
    public var debugDescription: String { "[\(parameters.debugDescription) \(endpoint.debugDescription)]" }
    public var maximumDatagramSize: Int { 65507 }

    public init(to endpoint: NWEndpoint, using parameters: NWParameters) {
        self.endpoint = endpoint
        self.parameters = parameters
        io = DispatchQueue(label: "runway.nwconnection")
    }
    public convenience init(host: NWEndpoint.Host, port: NWEndpoint.Port, using parameters: NWParameters) {
        self.init(to: .hostPort(host: host, port: port), using: parameters)
    }

    /// An accepted connection (from NWListener), already connected.
    init(accepted fd: Int32, endpoint: NWEndpoint, parameters: NWParameters) {
        self.endpoint = endpoint
        self.parameters = parameters
        io = DispatchQueue(label: "runway.nwconnection")
        self.fd = fd
    }

    private func setState(_ s: State) {
        lock.lock()
        if _state == s || _state == .cancelled { lock.unlock(); return }
        _state = s
        let h = _stateHandler, q = queue
        lock.unlock()
        if let h, let q { q.async { h(s) } }
    }

    public func start(queue: DispatchQueue) {
        lock.lock()
        guard self.queue == nil else { lock.unlock(); return }
        self.queue = queue
        let accepted = fd >= 0
        lock.unlock()
        setState(.preparing)
        io.async { [self] in
            if parameters.tls { setState(.failed(.tls(-9810))); return }   // errSSLInternal: no TLS stack
            if !accepted {
                switch Sock.connect(endpoint, type: parameters.transport) {
                case .failure(let e): setState(.failed(e)); return
                case .success(let f): lock.lock(); fd = f; lock.unlock()
                }
            }
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
            src.setEventHandler { [weak self] in self?.readable() }
            source = src
            src.resume()
            setState(.ready)
        }
    }

    private func readable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        #if os(Linux)
        let n = recv(fd, &chunk, chunk.count, Int32(MSG_DONTWAIT))
        #else
        let n = -1
        #endif
        if n > 0 { buffer.append(contentsOf: chunk[0..<n]) }
        else if n == 0 { eof = true; source?.cancel() }
        else if errno != EAGAIN && errno != EINTR { eof = true; source?.cancel(); failReceives(Sock.lastError); return }
        serviceReceives()
    }

    private func failReceives(_ e: NWError) {
        let rs = receives
        receives.removeAll()
        for r in rs { queue?.async { r.done(nil, nil, true, e) } }
    }

    private func serviceReceives() {
        while let r = receives.first {
            let datagram = parameters.transport == Int32(NWParameters.dgram)
            if r.message && !datagram && !eof { return }
            if buffer.count >= Swift.max(r.min, 1) || eof || (datagram && !buffer.isEmpty) {
                receives.removeFirst()
                let take = r.message ? buffer.count : Swift.min(buffer.count, r.max)
                let data = take > 0 ? buffer.prefix(take) : nil
                buffer.removeFirst(take)
                let complete = eof && buffer.isEmpty
                let ctx: ContentContext = complete ? .finalMessage : .defaultMessage
                let q = queue
                q?.async { r.done(data.map { Data($0) }, ctx, complete, nil) }
                if !complete && buffer.isEmpty { return }
            } else {
                return
            }
        }
    }

    public func receive(minimumIncompleteLength: Int, maximumLength: Int,
                        completion: @escaping @Sendable (Data?, ContentContext?, Bool, NWError?) -> Void) {
        io.async { [self] in
            receives.append((minimumIncompleteLength, maximumLength, false, completion))
            serviceReceives()
        }
    }

    public func receiveMessage(completion: @escaping @Sendable (Data?, ContentContext?, Bool, NWError?) -> Void) {
        io.async { [self] in
            receives.append((1, Int.max, true, completion))
            serviceReceives()
        }
    }

    public func send(content: Data?, contentContext: ContentContext = .defaultMessage, isComplete: Bool = true, completion: SendCompletion) {
        io.async { [self] in
            var error: NWError?
            if fd < 0 { error = .posix(.ENOTCONN) }
            #if os(Linux)
            if error == nil, let content, !content.isEmpty {
                var sent = 0
                content.withUnsafeBytes { buf in
                    while sent < buf.count {
                        let n = Glibc.send(fd, buf.baseAddress! + sent, buf.count - sent, Int32(MSG_NOSIGNAL))
                        if n < 0 { if errno == EINTR { continue }; error = Sock.lastError; return }
                        sent += n
                    }
                }
            }
            if error == nil, isComplete, contentContext.isFinal, parameters.transport == Int32(NWParameters.stream) { shutdown(fd, Int32(SHUT_WR)) }
            #else
            if error == nil { error = .posix(.EOPNOTSUPP) }
            #endif
            if case .contentProcessed(let done) = completion { let e = error; queue?.async { done(e) } }
        }
    }

    public func batch(_ block: () -> Void) { block() }

    public func cancel() {
        io.async { [self] in
            source?.cancel()
            source = nil
            if fd >= 0 { close(fd); fd = -1 }
            failReceives(.posix(.ECANCELED))
            setState(.cancelled)
        }
    }
    public func forceCancel() { cancel() }
    public func restart() {}
    public func cancelCurrentEndpoint() {}
}

// MARK: Listener

public final class NWListener: @unchecked Sendable, CustomDebugStringConvertible {
    public enum State: Equatable, Sendable { case setup, waiting(NWError), ready, failed(NWError), cancelled }

    public let parameters: NWParameters
    public private(set) var port: NWEndpoint.Port?
    public var newConnectionHandler: (@Sendable (NWConnection) -> Void)?
    public var stateUpdateHandler: (@Sendable (State) -> Void)?
    public var newConnectionLimit: Int = Int.max
    public var debugDescription: String { "listener \(parameters.debugDescription) \(port.map { "\($0.rawValue)" } ?? "")" }
    public private(set) var state: State = .setup

    private let io = DispatchQueue(label: "runway.nwlistener")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var queue: DispatchQueue?
    private let local: NWEndpoint

    public init(using parameters: NWParameters, on port: NWEndpoint.Port) throws {
        self.parameters = parameters
        local = .hostPort(host: parameters.acceptLocalOnly ? "127.0.0.1" : "0.0.0.0", port: port)
        try bindNow()
    }

    public init(using parameters: NWParameters) throws {
        self.parameters = parameters
        local = parameters.requiredLocalEndpoint ?? .hostPort(host: "0.0.0.0", port: .any)
        try bindNow()
    }

    private func bindNow() throws {
        #if os(Linux)
        if parameters.tls { throw NWError.tls(-9810) }
        let addrs: [(Int32, Data)]
        switch Sock.addresses(local, type: parameters.transport) {
        case .failure(let e): throw e
        case .success(let a): addrs = a
        }
        guard let (family, addr) = addrs.first else { throw NWError.posix(.EADDRNOTAVAIL) }
        if case .unix(let path) = local { unlink(path) }
        fd = socket(family, parameters.transport | Int32(SOCK_CLOEXEC.rawValue), 0)
        guard fd >= 0 else { throw Sock.lastError }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        let rc = addr.withUnsafeBytes { bind(fd, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(addr.count)) }
        guard rc == 0 else { let e = Sock.lastError; close(fd); throw e }
        if parameters.transport == Int32(NWParameters.stream) { guard listen(fd, 128) == 0 else { let e = Sock.lastError; close(fd); throw e } }
        if family == AF_INET || family == AF_INET6 {
            var ss = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            withUnsafeMutablePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) } }
            let p = withUnsafeBytes(of: &ss) { raw -> UInt16 in raw.load(fromByteOffset: 2, as: UInt16.self).bigEndian }
            port = NWEndpoint.Port(rawValue: p)
        }
        #else
        throw NWError.posix(.EOPNOTSUPP)
        #endif
    }

    private func setState(_ s: State) {
        state = s
        if let h = stateUpdateHandler, let q = queue { q.async { h(s) } }
    }

    public func start(queue: DispatchQueue) {
        self.queue = queue
        io.async { [self] in
            #if os(Linux)
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
            src.setEventHandler { [weak self] in
                guard let self else { return }
                let c = accept(self.fd, nil, nil)
                guard c >= 0 else { return }
                let conn = NWConnection(accepted: c, endpoint: self.local, parameters: self.parameters)
                if let h = self.newConnectionHandler { queue.async { h(conn) } } else { close(c) }
            }
            source = src
            src.resume()
            #endif
            setState(.ready)
        }
    }

    public func cancel() {
        io.async { [self] in
            source?.cancel()
            source = nil
            if fd >= 0 { close(fd); fd = -1 }
            if case .unix(let path) = local { unlink(path) }
            setState(.cancelled)
        }
    }
}
