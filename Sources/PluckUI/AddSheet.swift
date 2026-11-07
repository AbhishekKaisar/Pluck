import AppKit
import SwiftUI
import DownloaderCore

public struct AddDownloadSheet: View {
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var ui: ListState
    @ObservedObject var draft: AddDraft
    @FocusState private var linksFocused: Bool

    public init(draft: AddDraft) { self.draft = draft }

    public var body: some View {
        let links = draft.links
        VStack(alignment: .leading, spacing: 16) {
            Text("Add download").font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                TextField("Paste one or more links, one per line", text: $draft.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($linksFocused)
                    .onSubmit { commit(later: false) }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(linksFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.12), lineWidth: linksFocused ? 1.5 : 1))
                HStack(spacing: 4) {
                    if draft.fromClipboard {
                        Image(systemName: "doc.on.clipboard")
                        Text("Filled in from the clipboard")
                    } else if links.count > 1 {
                        Text("\(links.count) links")
                    } else if !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && links.isEmpty {
                        Image(systemName: "exclamationmark.circle")
                        Text("No http or https link found")
                    } else {
                        Text(" ")
                    }
                    if !ui.waitingDrafts.isEmpty {
                        Spacer()
                        Text("\(ui.waitingDrafts.count) more waiting")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            if links.count == 1 { fileCard }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Save to").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    HStack(spacing: 8) {
                        Image(nsImage: FileManager.default.fileExists(atPath: draft.directory) ? NSWorkspace.shared.icon(forFile: draft.directory) : NSWorkspace.shared.icon(for: .folder))
                            .resizable().frame(width: 16, height: 16)
                        Text(displayPath(draft.directory)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button("Change…", action: chooseFolder).controlSize(.small)
                    }
                }
                GridRow {
                    Text("Connections").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Stepper(value: $draft.connections, in: 1...SegmentMath.maxConnections) {
                            Text("\(draft.connections)").monospacedDigit().frame(minWidth: 20, alignment: .leading)
                        }
                        .fixedSize()
                        if let p = draft.probed, !p.acceptsRanges {
                            Text("This server sends the file in one stream.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .font(.system(size: 12.5))

            HStack(spacing: 8) {
                Button("Cancel") { ui.addDraft = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Download later") { commit(later: true) }
                    .disabled(links.isEmpty)
                    .help("Add to the list paused")
                Button("Download") { commit(later: false) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(links.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { if draft.text.isEmpty { linksFocused = true } }
    }

    @ViewBuilder private var fileCard: some View {
        HStack(alignment: .center, spacing: 12) {
            let name = draft.fileName.isEmpty ? (draft.links.first?.lastPathComponent ?? "download") : draft.fileName
            Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: (name as NSString).pathExtension) ?? .data))
                .resizable().interpolation(.high).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 5) {
                TextField("File name", text: Binding(get: { draft.fileName }, set: {
                    draft.fileName = $0
                    draft.nameEdited = true
                }))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .disabled(draft.probe == .probing && draft.fileName.isEmpty)
                probeLine.font(.system(size: 11.5))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    @ViewBuilder private var probeLine: some View {
        switch draft.probe {
        case .idle:
            Text(" ")
        case .probing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(draft.browserSize.map { "\(Format.bytes($0)), checking the link…" } ?? "Checking the link…")
                    .foregroundStyle(.secondary)
            }
        case .done(let r):
            HStack(spacing: 10) {
                Text(r.totalSize.map(Format.bytes) ?? "Size unknown").foregroundStyle(.secondary).monospacedDigit()
                if r.acceptsRanges {
                    Label("Resumable, splits across connections", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("No resume, one connection", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
            }
            .labelStyle(TightLabel())
        case .failed(let message):
            if let size = draft.browserSize { Text(Format.bytes(size)).foregroundStyle(.secondary).monospacedDigit() }
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .labelStyle(TightLabel())
                .lineLimit(2)
        }
    }

    private func displayPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    private func commit(later: Bool) {
        guard !draft.links.isEmpty else { return }
        draft.commit(to: manager, later: later)
        ui.addDraft = nil
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: draft.directory)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { draft.directory = url.path }
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}
