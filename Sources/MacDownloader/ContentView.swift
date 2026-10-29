import AppKit
import SwiftUI
import DownloaderCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var manager: DownloadManager
    @ViewState private var newURL = ""
    @ViewState private var addError: String?

    var body: some View {
        VStack(spacing: 0) {
            addBar
            Divider()
            if manager.items.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(manager.items) { item in
                        DownloadRow(item: item, speed: manager.speeds[item.id] ?? 0, eta: manager.eta(for: item))
                            .listRowSeparator(.visible)
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView().environmentObject(model).environmentObject(manager)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { manager.pauseAll() } label: { Label("Pause all", systemImage: "pause.circle") }
                    .help("Pause all")
                Button { manager.clearFinished() } label: { Label("Clear finished", systemImage: "checkmark.circle.badge.xmark") }
                    .help("Remove finished and cancelled items from the list")
                Button { model.showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    .help("Settings")
            }
        }
    }

    private var addBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").foregroundStyle(.secondary)
            TextField("Paste a download link", text: $newURL)
                .textFieldStyle(.plain)
                .onSubmit(add)
            if let addError {
                Text(addError).font(.caption).foregroundStyle(.red)
            }
            Button("Paste") {
                if let s = NSPasteboard.general.string(forType: .string) { newURL = s.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            Button("Add", action: add)
                .keyboardShortcut(.defaultAction)
                .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("No downloads yet").font(.headline)
            Text("Paste a link above, or download from Chrome or Edge with the extension on.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            let active = manager.items.filter { $0.status.isActive }.count
            let queued = manager.items.filter { $0.status == .queued }.count
            Text("\(active) active, \(queued) queued").foregroundStyle(.secondary)
            Spacer()
            if manager.settings.speedLimitKiB > 0 {
                Label("Limit \(Format.bytes(Int64(manager.settings.speedLimitKiB) * 1024))/s", systemImage: "tortoise")
                    .foregroundStyle(.secondary)
            }
            Text(Format.speed(manager.totalSpeed)).monospacedDigit()
            Circle().fill(model.port == nil ? Color.red : Color.green).frame(width: 7, height: 7)
                .help(model.port.map { "Browser catch listening on 127.0.0.1:\($0)" } ?? (model.serverError ?? "Browser catch not running"))
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func add() {
        let lines = newURL.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var added = 0
        for line in lines {
            if let u = URL(string: line), let s = u.scheme?.lowercased(), s == "http" || s == "https", u.host != nil {
                manager.add(url: u)
                added += 1
            }
        }
        if added == 0 {
            addError = "Not an http or https link"
        } else {
            addError = nil
            newURL = ""
        }
    }
}

struct DownloadRow: View {
    @EnvironmentObject private var manager: DownloadManager
    let item: DownloadRecord
    let speed: Double
    let eta: TimeInterval?

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: (item.fileName as NSString).pathExtension) ?? .data))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.fileName).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    statusBadge
                }
                if item.status != .completed && item.status != .cancelled {
                    if let p = item.progress {
                        ProgressView(value: p).progressViewStyle(.linear).tint(item.status == .failed ? .red : .accentColor)
                    } else if item.status.isActive {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            buttons
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
            }
            Button("Remove from list") { manager.remove(item.id) }
        }
    }

    private var detail: String {
        let size = item.totalSize.map(Format.bytes) ?? "unknown size"
        switch item.status {
        case .completed:
            return size
        case .downloading:
            var parts = ["\(Format.bytes(item.downloadedBytes)) of \(size)", "\(Format.speed(speed))"]
            if let eta { parts.append("\(Format.duration(eta)) left") }
            parts.append("\(item.segments.filter { !$0.isComplete }.count) conn")
            return parts.joined(separator: "  ·  ")
        case .failed:
            return item.errorMessage ?? "Failed"
        case .paused, .queued:
            return item.downloadedBytes > 0 ? "\(Format.bytes(item.downloadedBytes)) of \(size)" : (item.totalSize == nil ? item.url.host ?? "" : size)
        case .probing:
            return item.url.host ?? ""
        case .cancelled:
            return "Cancelled"
        }
    }

    private var statusBadge: some View {
        let (text, colour): (String, Color) = switch item.status {
        case .queued: ("Queued", .secondary)
        case .probing: ("Connecting", .secondary)
        case .downloading: (item.progress.map { "\(Int($0 * 100))%" } ?? "Downloading", .accentColor)
        case .paused: ("Paused", .orange)
        case .completed: ("Done", .green)
        case .failed: ("Failed", .red)
        case .cancelled: ("Cancelled", .secondary)
        }
        return Text(text).font(.caption.weight(.semibold)).foregroundStyle(colour).monospacedDigit()
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 4) {
            switch item.status {
            case .downloading, .probing, .queued:
                iconButton("pause.fill", "Pause") { manager.pause(item.id) }
                iconButton("xmark", "Cancel") { manager.cancel(item.id) }
            case .paused, .failed:
                iconButton(item.status == .failed ? "arrow.clockwise" : "play.fill", item.status == .failed ? "Retry" : "Resume") { manager.resume(item.id) }
                iconButton("xmark", "Cancel") { manager.cancel(item.id) }
            case .completed:
                iconButton("arrow.up.forward.app", "Open") { NSWorkspace.shared.open(URL(fileURLWithPath: item.finalPath)) }
                iconButton("magnifyingglass", "Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.finalPath)]) }
                iconButton("trash", "Remove from list") { manager.remove(item.id) }
            case .cancelled:
                iconButton("arrow.clockwise", "Download again") {
                    manager.add(url: item.url, fileName: item.nameIsFixed ? item.fileName : nil, headers: item.headers)
                    manager.remove(item.id)
                }
                iconButton("trash", "Remove from list") { manager.remove(item.id) }
            }
            if item.status != .completed && item.status != .cancelled {
                iconButton("magnifyingglass", "Reveal in Finder") {
                    let p = FileManager.default.fileExists(atPath: item.partPath) ? item.partPath : item.directory
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                }
            }
        }
        .buttonStyle(.borderless)
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 22)
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var manager: DownloadManager

    var body: some View {
        if manager.totalSpeed > 0 {
            Text("↓ \(Format.speed(manager.totalSpeed))").monospacedDigit()
        } else {
            Image(systemName: "arrow.down.circle")
        }
    }
}

struct MenuBarPanel: View {
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MacDownloader").font(.headline)
                Spacer()
                Text(Format.speed(manager.totalSpeed)).monospacedDigit().foregroundStyle(.secondary)
            }
            let active = manager.items.filter { $0.status.isActive || $0.status == .queued || $0.status == .paused }
            if active.isEmpty {
                Text("Nothing downloading").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(active.prefix(6)) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.fileName).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(item.status == .downloading ? Format.speed(manager.speeds[item.id] ?? 0) : item.status.rawValue.capitalized)
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.caption)
                        ProgressView(value: item.progress ?? 0)
                    }
                }
            }
            Divider()
            HStack {
                Button("Open MacDownloader") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func speed(_ bps: Double) -> String { "\(bytes(Int64(bps)))/s" }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

/// The command line tools ship SwiftUI without its macro plugin, so the `@State` macro cannot expand.
/// This alias reaches the underlying property wrapper directly.
typealias ViewState<Value> = SwiftUICore.State<Value>
