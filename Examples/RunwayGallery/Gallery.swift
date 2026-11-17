// A plain SwiftUI app, written as it would be for the Mac, that Runway
// builds and runs on Linux (GTK 4) and Windows (Win32). It exercises the
// layer: @Observable models, @State, bindings, forms, pickers, toggles,
// sliders, text fields, lists, shapes, gradients, sheets and alerts.

import SwiftUI

@Observable
final class Settings {
    var name = "Flight"
    var fps = 30
    var quality = Quality.high
    var notifications = true
    var volume = 0.6
    var tags: [String] = ["swift", "linux", "windows"]
    var retries = 3
    var highlight = Color.orange
    var codec = "HEVC"
    var hdr = true
    var stereo = false
    var mode = 1
}

enum Quality: String, CaseIterable, Identifiable {
    case low = "Low", medium = "Medium", high = "High"
    var id: Self { self }
}

struct Swatch: View {
    let colors: [Color]
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 56, height: 36)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.1)))
    }
}

struct Counter: View {
    @State private var count = 0
    var body: some View {
        HStack(spacing: 8) {
            Button { count -= 1 } label: { Image(systemName: "minus") }
            Text("\(count)")
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 30)
            Button { count += 1 } label: { Image(systemName: "plus") }
        }
    }
}

/// Controls outside a form, in their states: pop-up and pull-down
/// buttons, checkboxes, roles, disabled, small sizes, activity.
struct ControlsShowcase: View {
    @Bindable var settings: Settings
    @State private var search = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Codec", selection: $settings.codec) {
                    Text("H.264").tag("H.264")
                    Text("HEVC").tag("HEVC")
                    Text("ProRes 422").tag("ProRes 422")
                }
                .labelsHidden()
                Menu("Export") {
                    Button("Movie…") {}
                    Button("Audio Only…") {}
                    Divider()
                    Button("Copy Link") {}
                }
                Spacer()
            }
            HStack(spacing: 16) {
                Toggle("HDR", isOn: $settings.hdr)
                Toggle("Stereo", isOn: $settings.stereo)
                Toggle("Locked", isOn: .constant(true)).disabled(true)
            }
            .toggleStyle(.checkbox)
            HStack(spacing: 8) {
                Button("Delete", role: .destructive) {}
                Button("Disabled") {}.disabled(true)
                Button("Share") {}.buttonStyle(.borderedProminent).tint(.pink)
                Link("Docs", destination: URL(string: "https://example.com")!)
            }
            HStack(spacing: 8) {
                TextField("Search", text: $search)
                SecureField("Password", text: $password)
            }
            HStack(spacing: 10) {
                Button("Small") {}
                Picker("Mode", selection: $settings.mode) {
                    Text("One").tag(1)
                    Text("Two").tag(2)
                    Text("Three").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                ProgressView()
                Spacer()
            }
            .controlSize(.small)
        }
    }
}

struct GalleryView: View {
    @Bindable var settings: Settings
    @State private var showSheet = false
    @State private var showAlert = false
    @State private var newTag = ""

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $settings.name, prompt: Text("App name"))
                    Picker("Frame rate", selection: $settings.fps) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented)
                    Picker("Quality", selection: $settings.quality) {
                        ForEach(Quality.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Notifications", isOn: $settings.notifications)
                    LabeledContent("Volume") {
                        Slider(value: $settings.volume, in: 0...1).frame(width: 160)
                    }
                } header: {
                    Text("General")
                } footer: {
                    Text("Hello, \(settings.name) — \(settings.fps) fps, \(settings.quality.rawValue) quality, volume \(Int(settings.volume * 100))%.")
                }

                Section {
                    Stepper("Retries: \(settings.retries)", value: $settings.retries, in: 0...10)
                    ColorPicker("Highlight", selection: $settings.highlight)
                    Toggle("Launch at login", isOn: .constant(false))
                        .disabled(true)
                } header: {
                    Text("Advanced")
                }

                Section {
                    LabeledContent("Counter") { Counter() }
                    LabeledContent("Platform", value: platformName)
                    HStack {
                        Button("Show Sheet") { showSheet = true }
                        Button("Alert…") { showAlert = true }
                        Spacer()
                        Button("Done") {}
                            .keyboardShortcut(.defaultAction)
                    }
                } header: {
                    Text("Actions")
                }
            }
            .formStyle(.grouped)
            .frame(width: 420)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text("Shapes").font(.headline)
                HStack(spacing: 10) {
                    Swatch(colors: [.orange, .pink])
                    Swatch(colors: [.blue, .purple])
                    Swatch(colors: [.green, .teal])
                    Circle().fill(.orange).frame(width: 28, height: 28)
                    Capsule().fill(.blue.opacity(0.8)).frame(width: 48, height: 22)
                }
                Text("Tags").font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(settings.tags, id: \.self) { tag in
                        HStack {
                            Label(tag, systemImage: "tag")
                            Spacer()
                            Button {
                                settings.tags.removeAll { $0 == tag }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                    }
                    HStack {
                        TextField("New tag", text: $newTag)
                            .onSubmit(addTag)
                        Button("Add", action: addTag).disabled(newTag.isEmpty)
                    }
                }
                Text("Controls").font(.headline)
                ControlsShowcase(settings: settings)
                ProgressView(value: settings.volume)
                Text("Runway renders this SwiftUI code with native widgets: GTK 4 on Linux, Win32 on Windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(width: 360)
        }
        .sheet(isPresented: $showSheet) { SheetView() }
        .alert("Runway", isPresented: $showAlert) {
            Button("Cancel", role: .cancel) {}
            Button("OK") {}
        } message: {
            Text("Alerts become modal windows.")
        }
    }

    private func addTag() {
        guard !newTag.isEmpty else { return }
        settings.tags.append(newTag)
        newTag = ""
    }

    private var platformName: String {
        #if os(Linux)
        "Linux"
        #elseif os(Windows)
        "Windows"
        #else
        "macOS"
        #endif
    }
}

struct SheetView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A sheet").font(.title2)
            Text("Sheets are modal windows here.").foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}

@main
struct RunwayGallery: App {
    @State private var settings = Settings()
    var body: some Scene {
        WindowGroup("Runway Gallery") {
            GalleryView(settings: settings)
                .onAppear { LoopCheck.runIfRequested() }
        }
        .windowResizability(.contentSize)
    }
}
