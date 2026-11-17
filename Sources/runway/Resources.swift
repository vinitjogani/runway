// Resource conversion at staging time:
//
//   .xcassets   → RunwayAssets/RunwayAssets.json + the image files, which
//                 RunwayCore's RunwayAssets loader reads at run time (colour
//                 sets as light/dark sRGB, image sets as files per scale).
//   .xcstrings  → <lang>.lproj/<table>.strings (plurals as their "other"
//                 form: corelibs Foundation 6.4 crashes in localizedString
//                 when a .stringsdict is present, so none is written),
//                 what corelibs Foundation's Bundle.localizedString reads.

import Foundation
import RunwayImport

// MARK: Asset catalogs

/// RunwayAssets.json, version 1:
///   { "version": 1,
///     "colors": { "Name": { "light": [r,g,b,a], "dark": [r,g,b,a] } },
///     "images": { "Name": { "files": { "1x": "Name/a.png", "2x": "…", "any": "…" },
///                           "dark": { "1x": … }, "template": true } },
///     "data":   { "Name": "Name/file.json" } }
/// Paths are relative to the JSON file; colours are sRGB components 0…1.
func convertAssetCatalogs(_ catalogs: [URL], into out: URL) throws {
    var colors: [String: Any] = [:], images: [String: Any] = [:], data: [String: Any] = [:]
    try? fm.removeItem(at: out)
    ensureDir(out)

    func contents(_ dir: URL) -> [String: Any] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("Contents.json")) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }
    func isDark(_ entry: [String: Any]) -> Bool {
        (entry["appearances"] as? [[String: Any]] ?? []).contains { ($0["appearance"] as? String) == "luminosity" && ($0["value"] as? String) == "dark" }
    }
    func copyFile(_ src: URL, as name: String) -> String? {
        let rel = c99Name(name) + "/" + src.lastPathComponent
        do { try copyItem(src, out.appendingPathComponent(rel)) } catch { log("warning: couldn't copy \(src.path): \(error)"); return nil }
        return rel
    }
    /// A vector PDF as PNGs at 1x and 2x (GdkPixbuf and WIC don't decode
    /// PDF), when Poppler's pdftocairo is installed.
    func rasterize(_ src: URL, as name: String) -> [String: String] {
        guard src.pathExtension.lowercased() == "pdf", let tool = pdfRasterizer else { return [:] }
        var made: [String: String] = [:]
        for (key, dpi, suffix) in [("1x", "72", ""), ("2x", "144", "@2x")] {
            let base = c99Name(name) + "/" + src.deletingPathExtension().lastPathComponent + suffix
            let dst = out.appendingPathComponent(base)
            ensureDir(dst.deletingLastPathComponent())
            if run(tool, ["-png", "-singlefile", "-transp", "-r", dpi, src.path, dst.path], capture: true, quiet: true).status == 0,
               exists(dst.appendingPathExtension("png")) { made[key] = base + ".png" }
        }
        return made
    }

    func walk(_ dir: URL, prefix: String) {
        for entry in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() {
            let url = dir.appendingPathComponent(entry)
            guard isDirectory(url) else { continue }
            let ext = url.pathExtension
            let base = (entry as NSString).deletingPathExtension
            let name = prefix + base
            let c = contents(url)
            switch ext {
            case "colorset":
                var light: [Double]?, dark: [Double]?
                for e in c["colors"] as? [[String: Any]] ?? [] {
                    guard let rgba = parseColor(e["color"] as? [String: Any] ?? [:]) else { continue }
                    if isDark(e) { dark = rgba } else if light == nil || (e["idiom"] as? String) == "mac" { light = rgba }
                }
                if let l = light ?? dark { colors[name] = ["light": l, "dark": dark ?? l] }
            case "imageset", "appiconset", "symbolset", "iconset":
                var files: [String: String] = [:], darkFiles: [String: String] = [:]
                let entries = (c["images"] as? [[String: Any]]) ?? (c["symbols"] as? [[String: Any]]) ?? []
                for e in entries {
                    guard let file = e["filename"] as? String else { continue }
                    let raster = rasterize(url.appendingPathComponent(file), as: name)
                    if !raster.isEmpty {
                        for (k, v) in raster { if isDark(e) { darkFiles[k] = darkFiles[k] ?? v } else { files[k] = files[k] ?? v } }
                        continue
                    }
                    guard let rel = copyFile(url.appendingPathComponent(file), as: name) else { continue }
                    var key = (e["scale"] as? String) ?? "any"
                    if let size = e["size"] as? String { key = size + "@" + key }  // app icons
                    if isDark(e) { darkFiles[key] = darkFiles[key] ?? rel } else { files[key] = files[key] ?? rel }
                }
                if files.isEmpty && darkFiles.isEmpty { continue }
                var img: [String: Any] = ["files": files.isEmpty ? darkFiles : files]
                if !darkFiles.isEmpty { img["dark"] = darkFiles }
                let props = c["properties"] as? [String: Any] ?? [:]
                if (props["template-rendering-intent"] as? String) == "template" || ext == "symbolset" { img["template"] = true }
                images[name] = img
            case "dataset":
                for e in c["data"] as? [[String: Any]] ?? [] {
                    if let file = e["filename"] as? String, let rel = copyFile(url.appendingPathComponent(file), as: name) { data[name] = rel; break }
                }
            default:
                // A folder; it namespaces its children when it says so.
                let ns = ((c["properties"] as? [String: Any])?["provides-namespace"] as? Bool) == true
                walk(url, prefix: ns ? name + "/" : prefix)
            }
        }
    }
    for catalog in catalogs { walk(catalog, prefix: "") }
    let json: [String: Any] = ["version": 1, "colors": colors, "images": images, "data": data]
    let d = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try d.write(to: out.appendingPathComponent("RunwayAssets.json"))
}

/// Poppler's `pdftocairo`, when installed.
let pdfRasterizer: String? = whichIfPresent("pdftocairo")

/// A colour set entry's colour as sRGB [r, g, b, a].
func parseColor(_ color: [String: Any]) -> [Double]? {
    if let ref = color["reference"] as? String { return systemColors[ref] }
    guard let comps = color["components"] as? [String: Any] else { return nil }
    func num(_ key: String) -> Double? {
        guard let raw = comps[key] else { return nil }
        let s = (raw as? String) ?? "\(raw)"
        if s.hasPrefix("0x") || s.hasPrefix("0X") { return Double(Int(s.dropFirst(2), radix: 16) ?? 0) / 255 }
        guard let v = Double(s) else { return nil }
        return s.contains(".") || v <= 1 ? v : v / 255
    }
    let a = num("alpha") ?? 1
    if let w = num("white") { return [w, w, w, a] }
    guard var r = num("red"), var g = num("green"), var b = num("blue") else { return nil }
    if (color["color-space"] as? String)?.contains("p3") == true { (r, g, b) = displayP3ToSRGB(r, g, b) }
    return [r, g, b, a].map { min(max($0, 0), 1) }
}

/// Display P3 → sRGB, through linear light.
func displayP3ToSRGB(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
    func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    func enc(_ c: Double) -> Double { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }
    let (lr, lg, lb) = (lin(r), lin(g), lin(b))
    return (enc(1.2249 * lr - 0.2247 * lg + 0.0000 * lb),
            enc(-0.0420 * lr + 1.0419 * lg + 0.0000 * lb),
            enc(-0.0197 * lr - 0.0786 * lg + 1.0979 * lb))
}

/// macOS system colours a colour set can reference (light appearance).
let systemColors: [String: [Double]] = [
    "systemBlueColor": [0, 0.478, 1, 1], "systemRedColor": [1, 0.231, 0.188, 1], "systemGreenColor": [0.204, 0.78, 0.349, 1],
    "systemOrangeColor": [1, 0.584, 0, 1], "systemYellowColor": [1, 0.8, 0, 1], "systemPinkColor": [1, 0.176, 0.333, 1],
    "systemPurpleColor": [0.686, 0.322, 0.871, 1], "systemGrayColor": [0.557, 0.557, 0.576, 1], "systemTealColor": [0.353, 0.784, 0.98, 1],
    "systemIndigoColor": [0.345, 0.337, 0.839, 1], "labelColor": [0, 0, 0, 0.85], "secondaryLabelColor": [0, 0, 0, 0.5],
    "textColor": [0, 0, 0, 1], "textBackgroundColor": [1, 1, 1, 1], "windowBackgroundColor": [0.925, 0.925, 0.925, 1],
    "controlAccentColor": [0, 0.478, 1, 1], "separatorColor": [0, 0, 0, 0.1], "whiteColor": [1, 1, 1, 1], "blackColor": [0, 0, 0, 1],
    "clearColor": [0, 0, 0, 0],
]

// MARK: String catalogs

/// Writes `<lang>.lproj/<table>.strings` for each catalog (a plural key gets
/// its "other" form); returns the written paths relative to `out`.
func convertStringCatalogs(_ catalogs: [URL], into out: URL, sourceLanguage fallback: String) throws -> [String] {
    var written: [String] = []
    for catalog in catalogs {
        let table = catalog.deletingPathExtension().lastPathComponent
        guard let d = try? Data(contentsOf: catalog), let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            log("warning: couldn't read string catalog \(catalog.path)"); continue
        }
        let source = json["sourceLanguage"] as? String ?? fallback
        var strings: [String: [(String, String)]] = [:]
        var languages: Set<String> = [source]
        let entries = json["strings"] as? [String: Any] ?? [:]
        for (key, raw) in entries.sorted(by: { $0.key < $1.key }) {
            let entry = raw as? [String: Any] ?? [:]
            let locs = entry["localizations"] as? [String: Any] ?? [:]
            languages.formUnion(locs.keys)
            var hasSource = false
            for (lang, lraw) in locs {
                let loc = lraw as? [String: Any] ?? [:]
                if let unit = loc["stringUnit"] as? [String: Any], let v = unit["value"] as? String {
                    strings[lang, default: []].append((key, v))
                    if lang == source { hasSource = true }
                } else if let variations = loc["variations"] as? [String: Any] {
                    let plural = (variations["plural"] as? [String: Any])
                        ?? ((variations["device"] as? [String: Any]).flatMap { ($0["mac"] ?? $0["other"]) as? [String: Any] }?["variations"] as? [String: Any])?["plural"] as? [String: Any]
                    if let plural {
                        var forms: [String: String] = [:]
                        for (form, f) in plural { if let v = ((f as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String { forms[form] = v } }
                        if let other = forms["other"] { strings[lang, default: []].append((key, other)) }
                        if lang == source { hasSource = true }
                    } else if let device = variations["device"] as? [String: Any],
                              let v = (((device["mac"] ?? device["other"]) as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String {
                        strings[lang, default: []].append((key, v))
                        if lang == source { hasSource = true }
                    }
                }
            }
            // Keys with no source-language entry are their own value.
            if !hasSource, (entry["shouldTranslate"] as? Bool) != false || locs.isEmpty { strings[source, default: []].append((key, key)) }
        }
        for lang in languages.sorted() {
            let pairs = strings[lang] ?? []
            let rel = "\(lang).lproj/\(table).strings"
            let body = pairs.map { "\(stringsLiteral($0.0)) = \(stringsLiteral($0.1));" }.joined(separator: "\n") + "\n"
            try write(body, to: out.appendingPathComponent(rel))
            written.append(rel)
        }
    }
    return written
}

private func stringsLiteral(_ s: String) -> String {
    var out = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        default: out.unicodeScalars.append(c)
        }
    }
    return out + "\""
}
