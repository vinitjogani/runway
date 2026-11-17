// Opt-in measurement hooks for `Tools/measure.sh` (RUNWAY_METRICS=1).
//
// When the variable is unset every hook is a single cached Bool check: no
// clocks are read, nothing is formatted, nothing is scheduled.

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#elseif canImport(ucrt)
import ucrt
#endif

public enum RunwayMetrics {
    /// RUNWAY_METRICS is set.
    public static let enabled: Bool = getenv("RUNWAY_METRICS") != nil

    /// Wall-clock milliseconds since the Unix epoch (comparable with the
    /// harness's `date +%s%N`).
    public static func wallMillis() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
    }

    /// Monotonic milliseconds, for durations.
    public static func monoMillis() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
    }

    /// Resident and anonymous memory in MB, from /proc/self/status (Linux).
    public static func memoryMB() -> (rss: Double, anon: Double) {
        guard let f = fopen("/proc/self/status", "r") else { return (0, 0) }
        defer { fclose(f) }
        var rss = 0.0, anon = 0.0
        var buf = [CChar](repeating: 0, count: 256)
        while fgets(&buf, Int32(buf.count), f) != nil {
            let line = String(cString: buf)
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, let kb = Double(parts[1]) else { continue }
            if parts[0] == "VmRSS:" { rss = kb / 1024 } else if parts[0] == "RssAnon:" { anon = kb / 1024 }
        }
        return (rss, anon)
    }

    /// One `runway-metrics <event> key=value…` line on stderr.
    public static func log(_ event: String, _ fields: [(String, CustomStringConvertible)] = []) {
        guard enabled else { return }
        var line = "runway-metrics " + event
        for (k, v) in fields { line += " \(k)=\(v)" }
        line += "\n"
        _ = line.withCString { fputs($0, stderr) }
        fflush(stderr)
    }
}
