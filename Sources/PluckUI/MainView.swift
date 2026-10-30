import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DownloaderCore

/// Which optional columns fit. Date goes first as the window narrows, then speed.
struct Columns: Equatable {
    var showSpeed: Bool
    var showDate: Bool
    var compact: Bool

    init(width: CGFloat) {
        showDate = width >= 940
        showSpeed = width >= 720
        compact = width < 900
    }

    var status: CGFloat { compact ? 168 : 196 }

    static let size: CGFloat = 76
    static let speed: CGFloat = 86
    static let date: CGFloat = 112
    static let menu: CGFloat = 26
    static let rowHeight: CGFloat = 46
}

public struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var ui: ListState

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let cols = Columns(width: geo.size.width)
            VStack(spacing: 0) {
                TopBar(columns: cols)
                Divider().opacity(0.6)
                if manager.items.isEmpty {
                    EmptyState()
                } else {
                    DownloadTable(columns: cols)
                    if ui.showDetails, ui.selection.count == 1, let id = ui.selection.first, let r = manager.item(id) {
                        Divider().opacity(0.6)
                        DetailPanel(record: r, compact: cols.compact)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                Divider().opacity(0.6)
                StatusBar()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $ui.dropTargeted, perform: handleDrop)
        .overlay {
            if ui.dropTargeted && !manager.items.isEmpty {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.06)))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $ui.addDraft) { draft in
            AddDownloadSheet(draft: draft)
                .environmentObject(manager)
                .environmentObject(ui)
        }
        .alert(confirmTitle, isPresented: confirmShown, presenting: ui.confirm) { c in
            Button(confirmButton(c), role: .destructive) { perform(c) }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text(confirmMessage(c))
        }
        .onChange(of: manager.items) { _, _ in ui.prune(manager) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            manager.refreshMissing()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            manager.refreshMissing()
        }
        .animation(.easeOut(duration: 0.15), value: ui.selection.count == 1 && ui.showDetails)
    }

    // MARK: Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let collector = TextCollector()
        let group = DispatchGroup()
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.isFileURL, Self.isSmallTextFile(url), let s = try? String(contentsOf: url, encoding: .utf8) {
                        collector.add(s)
                    }
                    group.leave()
                }
            } else if p.canLoadObject(ofClass: URL.self) {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { collector.add(url.absoluteString) }
                    group.leave()
                }
            } else if p.canLoadObject(ofClass: String.self) {
                group.enter()
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    if let s { collector.add(s) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let links = LinkParser.links(in: collector.joined)
            guard !links.isEmpty else { return }
            MainActor.assumeIsolated {
                ui.openAdd(text: links.map(\.absoluteString).joined(separator: "\n"), settings: manager.settings)
            }
        }
        return true
    }

    nonisolated private static func isSmallTextFile(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        guard (v?.fileSize ?? 0) < 5_000_000 else { return false }
        return v?.contentType?.conforms(to: .text) ?? (url.pathExtension.lowercased() == "txt")
    }

    // MARK: Confirmation

    private var confirmShown: Binding<Bool> {
        Binding(get: { ui.confirm != nil }, set: { if !$0 { ui.confirm = nil } })
    }

    private var confirmTitle: String {
        switch ui.confirm {
        case .deleteFiles(let ids): return ids.count == 1 ? "Delete this file?" : "Delete \(ids.count) files?"
        case .remove(let ids): return ids.count == 1 ? "Remove this download?" : "Remove \(ids.count) downloads?"
        case nil: return ""
        }
    }

    private func confirmButton(_ c: ListState.Confirm) -> String {
        if case .deleteFiles = c { return "Delete" }
        return "Remove"
    }

    private func confirmMessage(_ c: ListState.Confirm) -> String {
        switch c {
        case .deleteFiles: return "Finished files move to the Trash. Partial downloads are deleted."
        case .remove: return "Unfinished downloads lose the data fetched so far. Finished files stay on disk."
        }
    }

    private func perform(_ c: ListState.Confirm) {
        switch c {
        case .deleteFiles(let ids): ids.forEach(manager.deleteFiles)
        case .remove(let ids): ids.forEach(manager.remove)
        }
        ui.selection.subtract({ if case .deleteFiles(let i) = c { return i }; if case .remove(let i) = c { return i }; return [] }())
    }
}

/// Collects text from item providers on background queues.
private final class TextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String] = []
    func add(_ s: String) { lock.lock(); parts.append(s); lock.unlock() }
    var joined: String { lock.lock(); defer { lock.unlock() }; return parts.joined(separator: "\n") }
}

/// Actions on a set of rows, shared by the action bar, the keyboard and the row menus.
@MainActor
struct RowActions {
    let manager: DownloadManager
    let ui: ListState

    func records(_ ids: Set<UUID>) -> [DownloadRecord] { manager.items.filter { ids.contains($0.id) } }

    func pause(_ ids: Set<UUID>) { records(ids).filter(\.canPause).forEach { manager.pause($0.id) } }
    func resume(_ ids: Set<UUID>) { records(ids).filter(\.canResume).forEach { manager.resume($0.id) } }

    /// Space: pause if anything selected is running, otherwise resume.
    func toggle(_ ids: Set<UUID>) {
        if records(ids).contains(where: \.canPause) { pause(ids) } else { resume(ids) }
    }

    /// Asks first only when unfinished data would be lost.
    func remove(_ ids: Set<UUID>) {
        let rs = records(ids)
        guard !rs.isEmpty else { return }
        if rs.contains(where: { !$0.status.isFinished && $0.downloadedBytes > 0 }) {
            ui.confirm = .remove(rs.map(\.id))
        } else {
            rs.forEach { manager.remove($0.id) }
            ui.selection.subtract(ids)
        }
    }

    func deleteFiles(_ ids: Set<UUID>) {
        let rs = records(ids)
        if !rs.isEmpty { ui.confirm = .deleteFiles(rs.map(\.id)) }
    }

    func open(_ r: DownloadRecord) {
        guard r.status == .completed, !manager.missing.contains(r.id) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: r.finalPath))
    }

    func reveal(_ r: DownloadRecord) {
        let fm = FileManager.default
        let path = r.status == .completed ? r.finalPath : r.partPath
        if fm.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: r.directory, isDirectory: true))
        }
    }

    func again(_ r: DownloadRecord) {
        if let new = manager.downloadAgain(r.id) { ui.selection = [new] }
    }
}

// MARK: Top bar

struct TopBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var ui: ListState
    let columns: Columns
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            selectAll
            if ui.selection.isEmpty {
                sortMenu
                filterMenu
            } else {
                actionBar
            }
            Spacer(minLength: 8)
            Button {
                ui.openAdd(settings: manager.settings)
            } label: {
                Label("Add download", systemImage: "plus")
            }
            .buttonStyle(AccentButtonStyle())
            .help("Add a download (⌘N)")
            searchField
            overflowMenu
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .onChange(of: ui.searchFocusRequest) { _, _ in searchFocused = true }
    }

    private var visible: [DownloadRecord] { ui.visible(manager) }

    private var selectAll: some View {
        let ids = Set(visible.map(\.id))
        let selected = ui.selection.intersection(ids)
        let mark: CheckBox.Mark = selected.isEmpty ? .off : (selected.count == ids.count ? .on : .mixed)
        return HStack(spacing: 0) {
            CheckBox(mark: mark) {
                ui.selection = mark == .off ? ids : []
            }
            .padding(.leading, 10)
            .help(mark == .off ? "Select all" : "Select none")
            Menu {
                ForEach(QuickSelection.allCases, id: \.self) { q in
                    Button(q.title) {
                        ui.selection = Set(visible.filter { q.matches($0, missing: manager.missing) }.map(\.id))
                    }
                }
                Divider()
                Button("None") { ui.selection = [] }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 6)
            .help("Select by status")
        }
        .frame(height: 28)
        .disabled(manager.items.isEmpty)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $ui.sort) {
                ForEach(ListSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(ui.sort.title, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 6)
        .help("Sort")
    }

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $ui.filter) {
                ForEach(ListFilter.statusFilters, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("File type", selection: $ui.filter) {
                ForEach(ListFilter.categoryFilters, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(ui.filter.title, systemImage: ui.filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 6)
        .help("Filter")
    }

    private var actionBar: some View {
        let actions = RowActions(manager: manager, ui: ui)
        let rs = actions.records(ui.selection)
        return HStack(spacing: 2) {
            Text("\(rs.count) selected")
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
                .padding(.horizontal, 8)
            barButton("Resume", "play.fill", enabled: rs.contains(where: \.canResume)) { actions.resume(ui.selection) }
            barButton("Pause", "pause.fill", enabled: rs.contains(where: \.canPause)) { actions.pause(ui.selection) }
            barButton("Remove from list", "minus.circle", enabled: !rs.isEmpty) { actions.remove(ui.selection) }
            barButton("Delete files", "trash", enabled: !rs.isEmpty, destructive: true) { actions.deleteFiles(ui.selection) }
        }
    }

    private func barButton(_ title: String, _ symbol: String, enabled: Bool, destructive: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if columns.compact {
                Image(systemName: symbol)
            } else {
                Label(title, systemImage: symbol)
            }
        }
        .buttonStyle(QuietButtonStyle(prominent: destructive))
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField("Search", text: $ui.search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { ui.search = ""; searchFocused = false }
            if !ui.search.isEmpty {
                Button { ui.search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 9)
        .frame(width: columns.compact ? 150 : 210, height: 28)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(searchFocused ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1.5))
    }

    private var overflowMenu: some View {
        Menu {
            Button("Paste links from clipboard") { model.pasteLinks() }
            Button("Import links from file…") { model.importLinks() }
            Button("Export links…") { model.exportLinks() }
                .disabled(manager.items.isEmpty)
            Divider()
            Button("Pause all") { manager.pauseAll() }
            Button("Clear finished") { manager.clearFinished() }
            Divider()
            SettingsLink { Text("Settings…") }
            Button("About Pluck") {
                NSApp.orderFrontStandardAboutPanel(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Quit Pluck") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "line.3.horizontal").font(.system(size: 14, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.leading, 4)
        .help("More")
    }
}

// MARK: Empty state

struct EmptyState: View {
    @EnvironmentObject private var ui: ListState

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(ui.dropTargeted ? 0.2 : 0.1)).frame(width: 76, height: 76)
                Image(systemName: "arrow.down").font(.system(size: 30, weight: .semibold)).foregroundStyle(Color.accentColor)
            }
            Text("No downloads yet").font(.system(size: 19, weight: .semibold))
            Text("Drag a link or a .txt file of links here, or click Add download.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece.extension")
                Text("With the browser extension on, downloads from Chrome and Edge arrive here by themselves.")
            }
            .font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DropZoneShape(targeted: ui.dropTargeted))
        .padding(16)
    }
}

struct DropZoneShape: View {
    let targeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.35),
                          style: StrokeStyle(lineWidth: targeted ? 2 : 1.25, dash: [6, 5]))
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(targeted ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.015)))
    }
}

// MARK: Status bar

struct StatusBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var ui: ListState

    var body: some View {
        let s = manager.settings
        let active = manager.items.filter { $0.status.isActive }.count
        let queued = manager.items.filter { $0.status == .queued }.count
        let done = manager.items.filter { $0.status == .completed && !manager.missing.contains($0.id) }.count
        HStack(spacing: 12) {
            Button {
                manager.setSpeedLimit(on: !s.speedLimitOn)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: s.speedLimitOn ? "tortoise.fill" : "tortoise")
                    if s.speedLimitOn { Text(Format.limit(s.speedLimitKiB)).monospacedDigit() }
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(s.speedLimitOn ? Color.white : Color.secondary)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Capsule().fill(s.speedLimitOn ? Color.accentColor : Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(s.speedLimitOn ? "Speed limit on (\(Format.limit(s.speedLimitKiB))). Click to turn off."
                                 : "Limit speed to \(Format.limit(s.speedLimitValueKiB)). Change the limit in Settings.")

            HStack(spacing: 3) {
                Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
                Text(Format.speed(manager.totalSpeed)).monospacedDigit()
            }
            .foregroundStyle(manager.totalSpeed > 0 ? Color.primary : Color.secondary)
            Text("\(active) active").monospacedDigit().foregroundStyle(.secondary)
            if queued > 0 { Text("\(queued) queued").monospacedDigit().foregroundStyle(.secondary) }
            Spacer()
            Text("Done: \(done)").monospacedDigit().foregroundStyle(.secondary)
            Button {
                ui.showDetails.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(ui.showDetails ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(ui.showDetails ? "Hide details of the selected download" : "Show details of the selected download")
            Circle().fill(model.port == nil ? Color.red : Color.green).frame(width: 7, height: 7)
                .help(model.port.map { "Browser extension link listening on 127.0.0.1:\($0)" } ?? (model.serverError ?? "Browser extension link not running"))
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
