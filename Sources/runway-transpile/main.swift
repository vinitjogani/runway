// runway-transpile: runs RunwayTranspiler over files or package directories
// and checks the output (parses, nothing Objective-C-only left, lines kept).
//
//   runway-transpile [--out DIR] [--quiet] PATH...
//
// A directory is one package: all of its .swift files are indexed together.
// Prints per-file problems and a summary with timings.

import Foundation
import RunwayTranspiler

var args = Array(CommandLine.arguments.dropFirst())

// --registry MODULE OUT FILE...: write the module's generated class table
// (RunwayTranspiler.classRegistrySource) to OUT; an empty table when the
// files declare no classes.
if args.first == "--registry", args.count >= 3 {
    let module = args[1], output = args[2]
    let files = args.dropFirst(3).compactMap { p in (try? String(contentsOfFile: p, encoding: .utf8)).map { (path: p, source: $0) } }
    let text = RunwayTranspiler.classRegistrySource(module: module, files: files) ?? "// No classes.\n"
    try text.write(toFile: output, atomically: true, encoding: .utf8)
    exit(0)
}

// --emit IN OUT [--stub] [--with FILE]...: write IN's transform to OUT (the
// test plugin's mode), indexed with the other fixtures of its target as one
// module (an override in one fixture's extension moves into another's
// class). With --stub, write the fixture's `// stub:` lines instead.
if args.first == "--emit", args.count >= 3 {
    let input = args[1], output = args[2]
    let source = try String(contentsOfFile: input, encoding: .utf8)
    let text: String
    if args.contains("--stub") {
        text = source.split(separator: "\n").filter { $0.hasPrefix("// stub: ") }.map { $0.dropFirst(9) }.joined(separator: "\n") + "\n"
    } else {
        // Real paths, so a moved member's #sourceLocation names its fixture.
        func standard(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.path }
        let path = standard(input)
        var files = [(path: path, source: source)]
        var i = 3
        while i < args.count {
            if args[i] == "--with", i + 1 < args.count {
                let p = standard(args[i + 1])
                if p != path, let s = try? String(contentsOfFile: p, encoding: .utf8) { files.append((p, s)) }
                i += 2
            } else {
                i += 1
            }
        }
        text = RunwayTranspiler.transform(source: source, fileName: path, index: PackageIndex(files: files))
    }
    try text.write(toFile: output, atomically: true, encoding: .utf8)
    exit(0)
}
var outDir: String?
var quiet = false
var printFile = false
var paths: [String] = []
while let a = args.first {
    args.removeFirst()
    switch a {
    case "--out": outDir = args.isEmpty ? nil : args.removeFirst()
    case "--quiet": quiet = true
    case "--print": printFile = true
    default: paths.append(a)
    }
}
if paths.isEmpty {
    FileHandle.standardError.write(Data("usage: runway-transpile [--out DIR] [--print] [--quiet] PATH...\n".utf8))
    exit(2)
}

func swiftFiles(_ path: String) -> [String] {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return [] }
    if !isDir.boolValue { return path.hasSuffix(".swift") ? [path] : [] }
    var out: [String] = []
    let e = FileManager.default.enumerator(atPath: path)
    while let rel = e?.nextObject() as? String {
        if rel.hasSuffix(".swift"), !rel.contains(".build/"), !rel.hasPrefix(".build") { out.append((path as NSString).appendingPathComponent(rel)) }
    }
    return out.sorted()
}

var totalFiles = 0, changed = 0, problems = 0, totalBytes = 0
var indexTime = 0.0, transformTime = 0.0
for p in paths {
    let files = swiftFiles(p)
    let sources = files.compactMap { f in (try? String(contentsOfFile: f, encoding: .utf8)).map { (path: f, source: $0) } }
    var t0 = Date()
    let index = PackageIndex(files: sources)
    indexTime += Date().timeIntervalSince(t0)
    for (path, source) in sources {
        totalFiles += 1
        totalBytes += source.utf8.count
        t0 = Date()
        let out = RunwayTranspiler.transform(source: source, fileName: path, index: index)
        transformTime += Date().timeIntervalSince(t0)
        if out != source { changed += 1 }
        if printFile { print(out) }
        let r = RunwayTranspiler.verify(original: source, output: out)
        var issues: [String] = []
        if r.parseErrors && !RunwayTranspiler.verify(original: source, output: source).parseErrors { issues.append("output doesn't parse") }
        if !r.leftovers.isEmpty { issues.append("left: " + Set(r.leftovers).sorted().joined(separator: " ")) }
        if r.linesShifted { issues.append("lines shifted") }
        if !issues.isEmpty {
            problems += 1
            print("\(path): \(issues.joined(separator: "; "))")
        } else if !quiet && out != source {
            print("ok \(path)")
        }
        if let outDir {
            let dest = (outDir as NSString).appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
            try? out.write(toFile: dest, atomically: true, encoding: .utf8)
        }
    }
}
print(String(format: "%d files (%.1f MB), %d changed, %d with problems; index %.0f ms, transform %.0f ms (%.2f ms/file)",
             totalFiles, Double(totalBytes) / 1e6, changed, problems, indexTime * 1000, transformTime * 1000,
             totalFiles == 0 ? 0 : transformTime * 1000 / Double(totalFiles)))
exit(problems == 0 ? 0 : 1)
