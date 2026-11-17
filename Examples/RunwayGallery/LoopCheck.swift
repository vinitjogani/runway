// RUNWAY_LOOP_CHECK=1: verifies the main loop runs MainActor tasks,
// DispatchQueue.main and Foundation timers, then quits.
import SwiftUI

@MainActor enum LoopCheck {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["RUNWAY_LOOP_CHECK"] != nil else { return }
        var hits: [String] = []
        func report() {
            guard hits.count == 4 else { return }
            print("loop-check:", hits.sorted().joined(separator: ","))
            exit(0)
        }
        Task { @MainActor in hits.append("task"); report() }
        DispatchQueue.main.async { hits.append("dispatch"); report() }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            hits.append("sleep"); report()
        }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated { hits.append("timer"); report() }
        }
    }
}
