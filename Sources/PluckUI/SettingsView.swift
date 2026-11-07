import AppKit
import SwiftUI
import DownloaderCore

/// The Settings window (Cmd+,). Changes apply at once.
public struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var manager: DownloadManager
    @ViewState private var limitText = ""
    @ViewState private var copied = false

    public init() {}

    public var body: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Default folder") {
                    HStack {
                        Text(manager.settings.downloadDirectory).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Toggle("Ask where to save each download", isOn: $manager.settings.askWhereToSave)
                Stepper(value: $manager.settings.connections, in: 1...SegmentMath.maxConnections) {
                    LabeledContent("Connections per download", value: "\(manager.settings.connections)")
                }
                Stepper(value: $manager.settings.maxConcurrent, in: 1...10) {
                    LabeledContent("Downloads at once", value: "\(manager.settings.maxConcurrent)")
                }
            }

            Section {
                Toggle("Limit total speed", isOn: Binding(
                    get: { manager.settings.speedLimitOn },
                    set: { on in applyValue(); manager.setSpeedLimit(on: on) }))
                LabeledContent("Limit (KiB per second)") {
                    TextField("", text: $limitText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(applyValue)
                }
            } header: {
                Text("Speed")
            } footer: {
                Text("The tortoise button in the status bar turns the limit on and off.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Browser extension") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(model.port == nil ? Color.red : Color.green).frame(width: 8, height: 8)
                        Text(model.port.map { "Listening on 127.0.0.1:\($0)" } ?? (model.serverError ?? "Not running"))
                    }
                }
                LabeledContent("Token") {
                    HStack {
                        Text(model.token).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                        Button(copied ? "Copied" : "Copy") {
                            Pasteboard.copy(model.token)
                            copied = true
                        }
                    }
                }
                Text("Paste the token into the extension's popup in Chrome or Edge.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { limitText = "\(manager.settings.speedLimitValueKiB)" }
        .onDisappear(perform: applyValue)
        .onChange(of: limitText) { _, _ in applyValue() }
    }

    private func applyValue() {
        guard let v = Int(limitText.trimmingCharacters(in: .whitespaces)), v > 0 else { return }
        guard v != manager.settings.speedLimitValueKiB else { return }
        manager.settings.speedLimitValueKiB = v
        if manager.settings.speedLimitOn { manager.settings.speedLimitKiB = v }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: manager.settings.downloadDirectory)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            manager.settings.downloadDirectory = url.path
        }
    }
}
