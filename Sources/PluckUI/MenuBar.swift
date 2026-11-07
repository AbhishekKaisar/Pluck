import AppKit
import SwiftUI
import DownloaderCore

public struct MenuBarLabel: View {
    @ObservedObject var manager: DownloadManager
    @ObservedObject var ui: ListState
    @Environment(\.openWindow) private var openWindow

    public init(manager: DownloadManager, ui: ListState) {
        self.manager = manager
        self.ui = ui
    }

    // This view lives as long as the app does, so it can bring up the window for a sheet that needs an answer.
    public var body: some View {
        Group {
            if manager.totalSpeed > 0 {
                Text("↓ \(Format.speed(manager.totalSpeed))").monospacedDigit()
            } else {
                Image(systemName: "arrow.down.circle")
            }
        }
        .onChange(of: ui.addDraft?.id) { _, id in
            guard id != nil else { return }
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

public struct MenuBarPanel: View {
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pluck").font(.headline)
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
                        SlimBar(value: item.progress ?? 0, tint: item.status == .downloading ? .accentColor : .secondary)
                    }
                }
            }
            Divider()
            HStack {
                Button("Open Pluck") {
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
