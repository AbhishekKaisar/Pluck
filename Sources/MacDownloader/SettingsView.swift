import AppKit
import SwiftUI
import DownloaderCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @ViewState private var limitOn = false
    @ViewState private var limitText = ""
    @ViewState private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.title2.weight(.semibold))

            Form {
                Section("Downloads") {
                    LabeledContent("Folder") {
                        HStack {
                            Text(manager.settings.downloadDirectory).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                    Stepper(value: $manager.settings.connections, in: 1...SegmentMath.maxConnections) {
                        LabeledContent("Connections per download", value: "\(manager.settings.connections)")
                    }
                    Stepper(value: $manager.settings.maxConcurrent, in: 1...10) {
                        LabeledContent("Downloads at once", value: "\(manager.settings.maxConcurrent)")
                    }
                    Toggle("Limit total speed", isOn: $limitOn)
                        .onChange(of: limitOn) { _, on in applyLimit(on: on) }
                    if limitOn {
                        LabeledContent("KiB per second") {
                            TextField("", text: $limitText)
                                .frame(width: 100)
                                .multilineTextAlignment(.trailing)
                                .onSubmit { applyLimit(on: true) }
                        }
                    }
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
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.token, forType: .string)
                                copied = true
                            }
                        }
                    }
                    Text("Paste the token into the extension's popup in Chrome or Edge.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") {
                    applyLimit(on: limitOn)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            limitOn = manager.settings.speedLimitKiB > 0
            limitText = manager.settings.speedLimitKiB > 0 ? "\(manager.settings.speedLimitKiB)" : "1024"
        }
    }

    private func applyLimit(on: Bool) {
        if on {
            let v = Int(limitText.trimmingCharacters(in: .whitespaces)) ?? 0
            manager.settings.speedLimitKiB = max(1, v)
            limitText = "\(manager.settings.speedLimitKiB)"
        } else {
            manager.settings.speedLimitKiB = 0
        }
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
