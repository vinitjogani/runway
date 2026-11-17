// Display identity from the monitors' EDID (Linux: /sys/class/drm, one
// file per connected output): vendor (the EDID manufacturer id, as the Mac
// reports it), model (product code) and serial number. Displays map to
// connected outputs in order; without EDID the numbers are 0, as for a
// display that doesn't report them on a Mac.

import Foundation

enum DisplayEDID {
    struct Identity { var vendor: UInt32; var model: UInt32; var serial: UInt32; var name: String?; var widthMM: Int; var heightMM: Int }

    static func connectedEDIDs() -> [[UInt8]] {
        let root = "/sys/class/drm"
        let outputs = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { $0.contains("-") }.sorted()
        var out: [[UInt8]] = []
        for o in outputs {
            let status = (try? String(contentsOfFile: "\(root)/\(o)/status", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard status == "connected", let data = FileManager.default.contents(atPath: "\(root)/\(o)/edid"), data.count >= 128 else { continue }
            out.append(Array(data))
        }
        return out
    }

    static func parse(_ e: [UInt8]) -> Identity {
        let vendor = UInt32(e[8]) << 8 | UInt32(e[9])
        let model = UInt32(e[10]) | UInt32(e[11]) << 8
        let serial = UInt32(e[12]) | UInt32(e[13]) << 8 | UInt32(e[14]) << 16 | UInt32(e[15]) << 24
        var name: String?
        for d in stride(from: 54, through: 108, by: 18) where e[d] == 0 && e[d + 1] == 0 && e[d + 3] == 0xFC {
            name = String(decoding: e[(d + 5)..<(d + 18)].prefix { $0 != 0x0A }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        return Identity(vendor: vendor, model: model, serial: serial, name: name, widthMM: Int(e[21]) * 10, heightMM: Int(e[22]) * 10)
    }

    static func identity(_ display: CGDirectDisplayID) -> Identity? {
        guard let index = CGDisplayServices.displays.firstIndex(where: { $0.id == display }) else { return nil }
        let edids = connectedEDIDs()
        guard index < edids.count else { return nil }
        return parse(edids[index])
    }
}

public func CGDisplayVendorNumber(_ display: CGDirectDisplayID) -> UInt32 { DisplayEDID.identity(display)?.vendor ?? 0 }
public func CGDisplayModelNumber(_ display: CGDirectDisplayID) -> UInt32 { DisplayEDID.identity(display)?.model ?? 0 }
public func CGDisplaySerialNumber(_ display: CGDirectDisplayID) -> UInt32 { DisplayEDID.identity(display)?.serial ?? 0 }
public func CGDisplayUnitNumber(_ display: CGDirectDisplayID) -> UInt32 {
    UInt32(CGDisplayServices.displays.firstIndex { $0.id == display } ?? 0)
}
public func CGDisplayIsInMirrorSet(_ display: CGDirectDisplayID) -> UInt32 { 0 }
public func CGDisplayMirrorsDisplay(_ display: CGDirectDisplayID) -> CGDirectDisplayID { kCGNullDirectDisplay }
public func CGDisplayPrimaryDisplay(_ display: CGDirectDisplayID) -> CGDirectDisplayID { display }
public func CGDisplayIsInHWMirrorSet(_ display: CGDirectDisplayID) -> UInt32 { 0 }
public func CGDisplayIsAsleep(_ display: CGDirectDisplayID) -> UInt32 { 0 }
public func CGDisplayIsStereo(_ display: CGDirectDisplayID) -> UInt32 { 0 }
public func CGDisplayUsesOpenGLAcceleration(_ display: CGDirectDisplayID) -> UInt32 { 1 }
public func CGDisplayRotation(_ display: CGDirectDisplayID) -> Double { 0 }
/// The EDID's monitor name (descriptor 0xFC), when it has one.
public func _CGDisplayEDIDName(_ display: CGDirectDisplayID) -> String? { DisplayEDID.identity(display)?.name }
