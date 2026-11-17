// A stress test for Runway's view graph, written as plain Mac SwiftUI: a
// ScrollView of 2,000 rows (each its own view with text, an icon and a
// toggle), a search field and a live character count.
//
// RUNWAY_STRESS_KEYS=N types N characters into the field once the window is
// up, one per main-loop turn, as a fast typist would; each keystroke is a
// state change the graph has to re-render. RUNWAY_STRESS_MODE=list (the
// default) keeps the typed text in the view that owns the rows, so every
// keystroke re-runs the list; =local keeps it in the search field's own
// view, as idiomatic SwiftUI would. With RUNWAY_METRICS=1 it reports
// `runway-metrics stress-done keys=N ms=…` when finished. Unset, the app
// just sits there (and should do no work at all while idle).

import SwiftUI
import RunwayCore

struct Item: Identifiable, Equatable {
    let id: Int
    var title: String
    var detail: String
    var starred: Bool
}

@Observable
final class Store {
    var items: [Item] = (0..<2000).map { i in
        Item(id: i, title: "Item \(i)", detail: "Row \(i) of 2,000 — some secondary text", starred: i % 7 == 0)
    }
    var selection: Int?
}

struct Row: View {
    let item: Item
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.starred ? "star.fill" : "star")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.headline)
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("#\(item.id)").monospacedDigit().foregroundStyle(.secondary)
            Button(item.starred ? "Unstar" : "Star", action: toggle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}

/// The search field as its own view: typing changes only its state (what
/// SwiftUI code is advised to do, and what RUNWAY_STRESS_MODE=local types
/// into).
struct SearchBar: View {
    @State private var draft = ""
    var body: some View {
        HStack {
            TextField("Type to stress the graph…", text: $draft)
            Text("\(draft.count) characters").monospacedDigit()
        }
        .onAppear { if StressDriver.mode == "local" { StressDriver.start { draft.append($0) } } }
    }
}

struct StressView: View {
    @Bindable var store: Store
    /// Typed into in the default mode: state of the view that owns the
    /// 2,000 rows, so every keystroke runs this body and every row's.
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if StressDriver.mode == "local" {
                    SearchBar()
                } else {
                    HStack {
                        TextField("Type to stress the graph…", text: $draft)
                        Text("\(draft.count) characters").monospacedDigit()
                    }
                }
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.items) { item in
                        Row(item: item, selected: store.selection == item.id) {
                            if let i = store.items.firstIndex(where: { $0.id == item.id }) { store.items[i].starred.toggle() }
                        }
                    }
                }
            }
        }
        .frame(width: 640, height: 720)
        .onAppear { if StressDriver.mode != "local" { StressDriver.start { draft.append($0) } } }
    }
}

/// Types characters, one per main-loop turn, when RUNWAY_STRESS_KEYS is set.
@MainActor enum StressDriver {
    /// RUNWAY_STRESS_MODE: "list" (default) or "local".
    static let mode = ProcessInfo.processInfo.environment["RUNWAY_STRESS_MODE"] ?? "list"
    static var started = false
    static func start(_ type: @escaping (Character) -> Void) {
        guard !started, let n = ProcessInfo.processInfo.environment["RUNWAY_STRESS_KEYS"].flatMap(Int.init), n > 0 else { return }
        started = true
        // Let the first frame land before typing.
        Runway.backend.schedule {
            let start = RunwayMetrics.monoMillis()
            let letters = Array("the quick brown fox jumps over the lazy dog ")
            var i = 0
            @MainActor func step() {
                guard i < n else {
                    let mem = RunwayMetrics.memoryMB()
                    RunwayMetrics.log("stress-done", [("keys", n), ("rss_mb", String(format: "%.1f", mem.rss)), ("anon_mb", String(format: "%.1f", mem.anon)),
                                                      ("ms", String(format: "%.1f", RunwayMetrics.monoMillis() - start))])
                    return
                }
                type(letters[i % letters.count])
                i += 1
                // Queued behind the render this keystroke scheduled.
                Runway.backend.schedule { step() }
            }
            step()
        }
    }
}

@main
struct RunwayStress: App {
    @State private var store = Store()
    var body: some Scene {
        WindowGroup("Runway Stress") {
            StressView(store: store)
        }
        .windowResizability(.contentSize)
    }
}
