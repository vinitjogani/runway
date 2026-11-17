// D-Bus for Runway's system frameworks, over GIO's GDBus (already loaded by
// GTK). Method calls are synchronous on the caller's thread; signal
// handlers and exported objects are dispatched on one private thread
// running its own GMainContext, so they work whether or not a GTK loop
// runs (tests, command-line tools). Nothing polls: the thread sleeps in
// poll(2) on the bus socket.
//
// Linux only; on other platforms the type exists and every bus is nil.

import Foundation
#if os(Linux)
import CGio
import Glibc
#endif

/// A D-Bus value, typed as the wire needs it.
public indirect enum DBusValue: CustomStringConvertible, Equatable {
    case string(String)
    case objectPath(String)
    case signature(String)
    case bool(Bool)
    case byte(UInt8)
    case int16(Int16)
    case uint16(UInt16)
    case int32(Int32)
    case uint32(UInt32)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    /// A Unix fd index (type `h`); the fds travel alongside the message.
    case handle(Int32)
    case variant(DBusValue)
    /// Elements, with the element signature (needed when empty).
    case array(String, [DBusValue])
    /// Entries of `a{kv}`, with the key and value signatures.
    case dict(String, String, [(DBusValue, DBusValue)])
    case tuple([DBusValue])

    public static func == (a: DBusValue, b: DBusValue) -> Bool { a.description == b.description && a.signature == b.signature }

    public var signature: String {
        switch self {
        case .string: return "s"
        case .objectPath: return "o"
        case .signature: return "g"
        case .bool: return "b"
        case .byte: return "y"
        case .int16: return "n"
        case .uint16: return "q"
        case .int32: return "i"
        case .uint32: return "u"
        case .int64: return "x"
        case .uint64: return "t"
        case .double: return "d"
        case .handle: return "h"
        case .variant: return "v"
        case .array(let e, _): return "a" + e
        case .dict(let k, let v, _): return "a{\(k)\(v)}"
        case .tuple(let xs): return "(" + xs.map(\.signature).joined() + ")"
        }
    }

    public var description: String {
        switch self {
        case .string(let s), .objectPath(let s), .signature(let s): return "\"\(s)\""
        case .bool(let b): return "\(b)"
        case .byte(let v): return "\(v)"
        case .int16(let v): return "\(v)"
        case .uint16(let v): return "\(v)"
        case .int32(let v): return "\(v)"
        case .uint32(let v): return "\(v)"
        case .int64(let v): return "\(v)"
        case .uint64(let v): return "\(v)"
        case .double(let v): return "\(v)"
        case .handle(let v): return "h\(v)"
        case .variant(let v): return "<\(v)>"
        case .array(_, let xs): return "[" + xs.map(\.description).joined(separator: ", ") + "]"
        case .dict(_, _, let kv): return "{" + kv.map { "\($0.0): \($0.1)" }.joined(separator: ", ") + "}"
        case .tuple(let xs): return "(" + xs.map(\.description).joined(separator: ", ") + ")"
        }
    }

    // Accessors that look through variants.
    public var unwrapped: DBusValue { if case .variant(let v) = self { return v.unwrapped }; return self }
    public var string: String? {
        switch unwrapped { case .string(let s), .objectPath(let s), .signature(let s): return s; default: return nil }
    }
    public var bool: Bool? { if case .bool(let b) = unwrapped { return b }; return nil }
    public var int: Int? {
        switch unwrapped {
        case .byte(let v): return Int(v)
        case .int16(let v): return Int(v)
        case .uint16(let v): return Int(v)
        case .int32(let v): return Int(v)
        case .uint32(let v): return Int(v)
        case .int64(let v): return Int(v)
        case .uint64(let v): return Int(clamping: v)
        case .handle(let v): return Int(v)
        default: return nil
        }
    }
    public var double: Double? { if case .double(let d) = unwrapped { return d }; return int.map(Double.init) }
    public var children: [DBusValue] {
        switch unwrapped {
        case .array(_, let xs), .tuple(let xs): return xs
        case .dict(_, _, let kv): return kv.map { .tuple([$0.0, $0.1]) }
        default: return []
        }
    }
    public subscript(_ i: Int) -> DBusValue? { let c = children; return i < c.count ? c[i] : nil }
    /// `a{sv}` as a dictionary.
    public var dictionary: [String: DBusValue] {
        guard case .dict(_, _, let kv) = unwrapped else { return [:] }
        var out: [String: DBusValue] = [:]
        for (k, v) in kv { if let ks = k.string { out[ks] = v.unwrapped } }
        return out
    }

    public static func vardict(_ d: [String: DBusValue]) -> DBusValue {
        .dict("s", "v", d.sorted { $0.key < $1.key }.map { (.string($0.key), .variant($0.value)) })
    }
}

public struct DBusError: Error, CustomStringConvertible {
    public let name: String
    public let message: String
    public var description: String { "\(name): \(message)" }
}

/// A connection to a message bus.
public final class DBusConnection: @unchecked Sendable {
    #if os(Linux)
    let conn: OpaquePointer

    init(_ c: OpaquePointer) { conn = c }

    /// The session bus (nil without one: no DBUS_SESSION_BUS_ADDRESS and no
    /// user bus socket).
    public static let session: DBusConnection? = connect(G_BUS_TYPE_SESSION)
    public static let system: DBusConnection? = connect(G_BUS_TYPE_SYSTEM)

    private static func connect(_ type: GBusType) -> DBusConnection? {
        if type == G_BUS_TYPE_SESSION, ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"] == nil {
            let uid = getuid()
            let socket = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"].map { "\($0)/bus" } ?? "/run/user/\(uid)/bus"
            guard access(socket, F_OK) == 0 else { return nil }
        }
        var err: UnsafeMutablePointer<GError>?
        guard let c = g_bus_get_sync(type, nil, &err) else { if let err { g_error_free(err) }; return nil }
        g_dbus_connection_set_exit_on_close(c, 0)
        return DBusConnection(c)
    }

    /// A private connection to a bus at `address` (tests, peer buses).
    public static func connect(address: String) throws -> DBusConnection {
        var err: UnsafeMutablePointer<GError>?
        let flags = GDBusConnectionFlags(rawValue: G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT.rawValue | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION.rawValue)
        guard let c = g_dbus_connection_new_for_address_sync(address, flags, nil, nil, &err) else { throw DBusConnection.error(err) }
        g_dbus_connection_set_exit_on_close(c, 0)
        return DBusConnection(c)
    }

    static func error(_ err: UnsafeMutablePointer<GError>?) -> DBusError {
        guard let err else { return DBusError(name: "org.freedesktop.DBus.Error.Failed", message: "unknown error") }
        defer { g_error_free(err) }
        var name = "org.freedesktop.DBus.Error.Failed"
        if let remote = g_dbus_error_get_remote_error(err) { name = String(cString: remote); g_free(remote) }
        return DBusError(name: name, message: String(cString: err.pointee.message))
    }

    public var uniqueName: String? { g_dbus_connection_get_unique_name(conn).map { String(cString: $0) } }

    /// Calls a method; `args` is the argument list. Returns the reply's values.
    @discardableResult
    public func call(_ destination: String, _ path: String, _ interface: String, _ method: String, _ args: [DBusValue] = [],
                     timeout: Int32 = 5000) throws -> [DBusValue] {
        var err: UnsafeMutablePointer<GError>?
        let params = DBusValue.tuple(args).gvariant()
        guard let reply = g_dbus_connection_call_sync(conn, destination, path, interface, method, params, nil,
                                                      G_DBUS_CALL_FLAGS_NONE, timeout, nil, &err) else { throw DBusConnection.error(err) }
        defer { g_variant_unref(reply) }
        return DBusValue(reply).children
    }

    /// Calls a method whose reply carries Unix fds (`h` values index them).
    public func callReturningFDs(_ destination: String, _ path: String, _ interface: String, _ method: String, _ args: [DBusValue] = [],
                                 timeout: Int32 = 5000) throws -> ([DBusValue], [Int32]) {
        var err: UnsafeMutablePointer<GError>?
        var outList: UnsafeMutablePointer<GUnixFDList>?
        let params = DBusValue.tuple(args).gvariant()
        guard let reply = g_dbus_connection_call_with_unix_fd_list_sync(conn, destination, path, interface, method, params, nil,
                                                                        G_DBUS_CALL_FLAGS_NONE, timeout, nil, &outList, nil, &err)
        else { throw DBusConnection.error(err) }
        defer { g_variant_unref(reply) }
        var fds: [Int32] = []
        if let outList {
            let n = g_unix_fd_list_get_length(outList)
            for i in 0..<n {
                let fd = g_unix_fd_list_get(outList, i, nil)
                if fd >= 0 { fds.append(fd) }
            }
            g_object_unref(UnsafeMutableRawPointer(outList))
        }
        return (DBusValue(reply).children, fds)
    }

    /// Whether a name currently has an owner on this bus.
    public func hasOwner(_ name: String) -> Bool {
        (try? call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", [.string(name)]))?.first?.bool ?? false
    }

    /// Asks the bus for a well-known name. True when this connection owns it.
    @discardableResult
    public func requestName(_ name: String) -> Bool {
        let r = try? call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", [.string(name), .uint32(4)])
        return r?.first?.int == 1 || r?.first?.int == 4
    }

    // MARK: Signals

    public struct Signal {
        public let sender: String
        public let path: String
        public let interface: String
        public let member: String
        public let arguments: [DBusValue]
    }

    final class SignalBox {
        let handler: (Signal) -> Void
        init(_ h: @escaping (Signal) -> Void) { handler = h }
    }

    /// Subscribes to a signal; the handler runs on the D-Bus thread.
    /// Returns an id for `unsubscribe`.
    @discardableResult
    public func subscribe(sender: String? = nil, interface: String? = nil, member: String? = nil, path: String? = nil,
                          _ handler: @escaping (Signal) -> Void) -> UInt32 {
        let box = Unmanaged.passRetained(SignalBox(handler)).toOpaque()
        let conn = self.conn
        return DBusThread.shared.sync {
            g_dbus_connection_signal_subscribe(conn, sender, interface, member, path, nil, G_DBUS_SIGNAL_FLAGS_NONE, { _, sender, path, iface, member, params, data in
                guard let data else { return }
                let box = Unmanaged<SignalBox>.fromOpaque(data).takeUnretainedValue()
                let args = params.map { DBusValue($0).children } ?? []
                box.handler(Signal(sender: sender.map { String(cString: $0) } ?? "", path: path.map { String(cString: $0) } ?? "",
                                   interface: iface.map { String(cString: $0) } ?? "", member: member.map { String(cString: $0) } ?? "",
                                   arguments: args))
            }, box, { data in
                if let data { Unmanaged<SignalBox>.fromOpaque(data).release() }
            })
        }
    }

    public func unsubscribe(_ id: UInt32) {
        let conn = self.conn
        DBusThread.shared.sync { g_dbus_connection_signal_unsubscribe(conn, id) }
    }

    // MARK: Exported objects

    public struct MethodCall {
        public let sender: String
        public let path: String
        public let interface: String
        public let method: String
        public let arguments: [DBusValue]
    }

    final class ObjectBox {
        let handler: (MethodCall) -> Result<[DBusValue], DBusError>
        init(_ h: @escaping (MethodCall) -> Result<[DBusValue], DBusError>) { handler = h }
    }

    /// Serves an object at `path` implementing the interfaces in
    /// `introspectionXML`; `handler` answers each call on the D-Bus thread.
    @discardableResult
    public func export(path: String, introspectionXML: String,
                       _ handler: @escaping (MethodCall) -> Result<[DBusValue], DBusError>) throws -> [UInt32] {
        var err: UnsafeMutablePointer<GError>?
        guard let node = g_dbus_node_info_new_for_xml(introspectionXML, &err) else { throw DBusConnection.error(err) }
        defer { g_dbus_node_info_unref(node) }
        var ids: [UInt32] = []
        var i = 0
        let conn = self.conn
        while let iface = node.pointee.interfaces?[i] {
            let box = Unmanaged.passRetained(ObjectBox(handler)).toOpaque()
            let ifacePtr = UnsafeMutableRawPointer(iface)
            let id: UInt32 = try DBusThread.shared.sync {
                var vtable = GDBusInterfaceVTable()
                vtable.method_call = { _, sender, path, iface, method, params, invocation, data in
                    guard let data, let invocation else { return }
                    let box = Unmanaged<ObjectBox>.fromOpaque(data).takeUnretainedValue()
                    let call = MethodCall(sender: sender.map { String(cString: $0) } ?? "", path: path.map { String(cString: $0) } ?? "",
                                          interface: iface.map { String(cString: $0) } ?? "", method: method.map { String(cString: $0) } ?? "",
                                          arguments: params.map { DBusValue($0).children } ?? [])
                    switch box.handler(call) {
                    case .success(let out): g_dbus_method_invocation_return_value(invocation, DBusValue.tuple(out).gvariant())
                    case .failure(let e): g_dbus_method_invocation_return_dbus_error(invocation, e.name, e.message)
                    }
                }
                var e2: UnsafeMutablePointer<GError>?
                let id = g_dbus_connection_register_object(conn, path, ifacePtr.assumingMemoryBound(to: GDBusInterfaceInfo.self), &vtable, box, { data in
                    if let data { Unmanaged<ObjectBox>.fromOpaque(data).release() }
                }, &e2)
                if id == 0 { throw DBusConnection.error(e2) }
                return id
            }
            ids.append(id)
            i += 1
        }
        return ids
    }

    /// Emits a signal from this connection.
    public func emit(path: String, interface: String, member: String, _ args: [DBusValue], destination: String? = nil) {
        g_dbus_connection_emit_signal(conn, destination, path, interface, member, DBusValue.tuple(args).gvariant(), nil)
        g_dbus_connection_flush_sync(conn, nil, nil)
    }
    #else
    public static let session: DBusConnection? = nil
    public static let system: DBusConnection? = nil
    #endif
}

#if os(Linux)

// MARK: GVariant conversion

extension DBusValue {
    /// A new floating GVariant.
    func gvariant() -> OpaquePointer {
        switch self {
        case .string(let s): return g_variant_new_string(s)
        case .objectPath(let s): return g_variant_new_object_path(s)
        case .signature(let s): return g_variant_new_signature(s)
        case .bool(let b): return g_variant_new_boolean(b ? 1 : 0)
        case .byte(let v): return g_variant_new_byte(v)
        case .int16(let v): return g_variant_new_int16(v)
        case .uint16(let v): return g_variant_new_uint16(v)
        case .int32(let v): return g_variant_new_int32(v)
        case .uint32(let v): return g_variant_new_uint32(v)
        case .int64(let v): return g_variant_new_int64(gint64(v))
        case .uint64(let v): return g_variant_new_uint64(guint64(v))
        case .double(let v): return g_variant_new_double(v)
        case .handle(let v): return g_variant_new_handle(v)
        case .variant(let v): return g_variant_new_variant(v.gvariant())
        case .tuple(let xs):
            var kids: [OpaquePointer?] = xs.map { $0.gvariant() }
            return g_variant_new_tuple(&kids, gsize(kids.count))
        case .array(let elem, let xs):
            let t = g_variant_type_new(elem)
            defer { g_variant_type_free(t) }
            var kids: [OpaquePointer?] = xs.map { $0.gvariant() }
            return g_variant_new_array(t, &kids, gsize(kids.count))
        case .dict(let k, let v, let kv):
            let t = g_variant_type_new("{\(k)\(v)}")
            defer { g_variant_type_free(t) }
            var kids: [OpaquePointer?] = kv.map { g_variant_new_dict_entry($0.0.gvariant(), $0.1.gvariant()) }
            return g_variant_new_array(t, &kids, gsize(kids.count))
        }
    }

    init(_ v: OpaquePointer) {
        let sig = String(cString: g_variant_get_type_string(v))
        switch sig.first {
        case "s": self = .string(String(cString: g_variant_get_string(v, nil)))
        case "o": self = .objectPath(String(cString: g_variant_get_string(v, nil)))
        case "g": self = .signature(String(cString: g_variant_get_string(v, nil)))
        case "b": self = .bool(g_variant_get_boolean(v) != 0)
        case "y": self = .byte(g_variant_get_byte(v))
        case "n": self = .int16(g_variant_get_int16(v))
        case "q": self = .uint16(g_variant_get_uint16(v))
        case "i": self = .int32(g_variant_get_int32(v))
        case "u": self = .uint32(g_variant_get_uint32(v))
        case "x": self = .int64(Int64(g_variant_get_int64(v)))
        case "t": self = .uint64(UInt64(g_variant_get_uint64(v)))
        case "d": self = .double(g_variant_get_double(v))
        case "h": self = .handle(g_variant_get_handle(v))
        case "v":
            let inner = g_variant_get_variant(v)!
            defer { g_variant_unref(inner) }
            self = .variant(DBusValue(inner))
        case "(":
            self = .tuple(DBusValue.kids(v))
        case "a":
            let rest = String(sig.dropFirst())
            if rest.hasPrefix("{") {
                let inner = String(rest.dropFirst().dropLast())
                let keySig = String(inner.prefix(1))
                let valueSig = String(inner.dropFirst())
                let entries = DBusValue.kids(v).map { e -> (DBusValue, DBusValue) in
                    let c = e.children
                    return (c.first ?? .string(""), c.count > 1 ? c[1] : .string(""))
                }
                self = .dict(keySig, valueSig, entries)
            } else {
                self = .array(rest, DBusValue.kids(v))
            }
        case "{":
            self = .tuple(DBusValue.kids(v))
        default:
            self = .string("")
        }
    }

    static func kids(_ v: OpaquePointer) -> [DBusValue] {
        (0..<g_variant_n_children(v)).map { i in
            let c = g_variant_get_child_value(v, i)!
            defer { g_variant_unref(c) }
            return DBusValue(c)
        }
    }
}

// MARK: The D-Bus thread

/// One thread running a private GMainContext for signal and method
/// dispatch.
final class DBusThread: @unchecked Sendable {
    static let shared = DBusThread()
    let context: OpaquePointer
    private var thread: Thread!

    private init() {
        context = g_main_context_new()
        let ctx = context
        let ready = DispatchSemaphore(value: 0)
        thread = Thread {
            g_main_context_push_thread_default(ctx)
            let loop = g_main_loop_new(ctx, 0)
            ready.signal()
            g_main_loop_run(loop)
        }
        thread.name = "runway.dbus"
        thread.start()
        ready.wait()
    }

    final class Work {
        let body: () -> Void
        init(_ b: @escaping () -> Void) { body = b }
    }

    /// Runs `body` on the D-Bus thread and waits for it.
    func sync<T>(_ body: @escaping () throws -> T) rethrows -> T {
        if Thread.current === thread { return try body() }
        var result: Result<T, Error>!
        let done = DispatchSemaphore(value: 0)
        let work = Work {
            do { result = .success(try body()) } catch { result = .failure(error) }
            done.signal()
        }
        g_main_context_invoke(context, { data in
            Unmanaged<Work>.fromOpaque(data!).takeRetainedValue().body()
            return 0
        }, Unmanaged.passRetained(work).toOpaque())
        done.wait()
        switch result! {
        case .success(let v): return v
        case .failure(let e): return try { throw e }()
        }
    }
}
#endif
