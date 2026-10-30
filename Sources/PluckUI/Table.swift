import AppKit
import SwiftUI
import DownloaderCore

struct DownloadTable: View {
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var ui: ListState
    let columns: Columns
    @FocusState private var focused: Bool

    var body: some View {
        let rows = ui.visible(manager)
        let order = rows.map(\.id)
        let actions = RowActions(manager: manager, ui: ui)
        let _ = ui.rowOrder = order
        VStack(spacing: 0) {
            HeaderRow(columns: columns)
            GeometryReader { geo in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { r in
                            DownloadRow(manager: manager, ui: ui, record: r, columns: columns,
                                        selected: ui.selection.contains(r.id), missing: manager.missing.contains(r.id),
                                        speed: manager.speeds[r.id] ?? 0, eta: manager.eta(for: r)) {
                                // Reads the order when clicked: an unchanged row keeps its first closure.
                                focused = true
                                ui.click(r.id, in: ui.rowOrder, modifiers: NSEvent.modifierFlags)
                                if (NSApp.currentEvent?.clickCount ?? 1) >= 2, let now = manager.item(r.id) { actions.open(now) }
                            }
                            .equatable()
                        }
                        if rows.isEmpty { noMatches }
                        let used = CGFloat(rows.count) * Columns.rowHeight + (rows.isEmpty ? 90 : 0)
                        DropZoneShape(targeted: ui.dropTargeted)
                            .overlay {
                                Label("Drag and drop a link here", systemImage: "link")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(ui.dropTargeted ? Color.accentColor : Color.secondary)
                            }
                            .frame(height: max(64, geo.size.height - used - 24))
                            .padding(.top, 8)
                            .padding(.bottom, 12)
                            .padding(.horizontal, 6)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            actions.toggle(ui.selection)
            return ui.selection.isEmpty ? .ignored : .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward], phases: .down) { press in
            guard !ui.selection.isEmpty else { return .ignored }
            if press.modifiers.contains(.command) { actions.deleteFiles(ui.selection) } else { actions.remove(ui.selection) }
            return .handled
        }
        .onKeyPress(.return) {
            guard ui.selection.count == 1, let r = manager.item(ui.selection.first!) else { return .ignored }
            actions.open(r)
            return .handled
        }
        .onMoveCommand { dir in
            if dir == .up { ui.move(by: -1, in: order) }
            if dir == .down { ui.move(by: 1, in: order) }
        }
        .onExitCommand { ui.selection = [] }
        .onPasteCommand(of: [.url, .plainText]) { _ in
            let links = LinkParser.links(in: Pasteboard.text ?? "")
            if !links.isEmpty {
                ui.openAdd(text: links.map(\.absoluteString).joined(separator: "\n"), settings: manager.settings)
            }
        }
    }

    private var noMatches: some View {
        VStack(spacing: 6) {
            Text("No downloads match").font(.system(size: 13, weight: .semibold))
            Button("Show all") {
                ui.search = ""
                ui.filter = .all
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 90)
    }
}

struct HeaderRow: View {
    @EnvironmentObject private var ui: ListState
    let columns: Columns

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 14)
            Color.clear.frame(width: 24)
            header("Name", sorts: [.nameAscending, .nameDescending]).frame(maxWidth: .infinity, alignment: .leading)
            header("Size", sorts: [.sizeLargest, .sizeSmallest]).frame(width: Columns.size, alignment: .trailing)
            header("Status", sorts: [.status]).frame(width: columns.status, alignment: .leading).padding(.leading, 14)
            if columns.showSpeed { Text("Speed").frame(width: Columns.speed, alignment: .trailing) }
            if columns.showDate { header("Added", sorts: [.newest, .oldest]).frame(width: Columns.date, alignment: .trailing) }
            Color.clear.frame(width: Columns.menu)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 28)
        .background(Color.primary.opacity(0.035))
    }

    /// Clicking a header sorts by it; a second click flips the order.
    private func header(_ title: String, sorts: [ListSort]) -> some View {
        Button {
            if let i = sorts.firstIndex(of: ui.sort) { ui.sort = sorts[(i + 1) % sorts.count] } else { ui.sort = sorts[0] }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if let i = sorts.firstIndex(of: ui.sort) {
                    Image(systemName: sorts.count == 1 ? "chevron.down" : (i == 0 ? "chevron.down" : "chevron.up"))
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(sorts.contains(ui.sort) ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One row. It does not observe the manager: the table passes in the values it shows, and
/// `==` lets SwiftUI skip rows whose values did not change, so a progress tick redraws only
/// the rows that are downloading.
struct DownloadRow: View, Equatable {
    let manager: DownloadManager
    let ui: ListState
    let record: DownloadRecord
    let columns: Columns
    let selected: Bool
    let missing: Bool
    let speed: Double
    let eta: TimeInterval?
    let onClick: () -> Void
    @ViewState private var hover = false

    nonisolated static func == (a: DownloadRow, b: DownloadRow) -> Bool {
        a.record == b.record && a.columns == b.columns && a.selected == b.selected && a.missing == b.missing
            && a.speed == b.speed && a.eta == b.eta
    }

    var body: some View {
        let r = record
        HStack(spacing: 10) {
            CheckBox(mark: selected ? .on : .off) { ui.toggle(r.id) }
            Image(nsImage: FileIcons.icon(for: r, missing: missing))
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
                .opacity(missing || r.status == .cancelled ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(missing || r.status == .cancelled ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(r.url.host ?? r.url.absoluteString)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(r.fileName)
            Text(r.totalSize.map(Format.bytes) ?? "Unknown")
                .font(.system(size: 12))
                .foregroundStyle(r.totalSize == nil ? Color.secondary.opacity(0.7) : Color.secondary)
                .monospacedDigit()
                .frame(width: Columns.size, alignment: .trailing)
            StatusCell(record: r, missing: missing, speed: speed, eta: eta, showSpeed: !columns.showSpeed)
                .frame(width: columns.status, alignment: .leading)
                .padding(.leading, 14)
            if columns.showSpeed {
                Group {
                    if r.status == .downloading {
                        Text(Format.speed(speed)).foregroundStyle(.primary)
                    } else {
                        Text("–").foregroundStyle(.quaternary)
                    }
                }
                .font(.system(size: 12))
                .monospacedDigit()
                .frame(width: Columns.speed, alignment: .trailing)
            }
            if columns.showDate {
                Text(Format.added(r.createdAt))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: Columns.date, alignment: .trailing)
            }
            Menu {
                RowMenuItems(manager: manager, ui: ui, record: r, missing: missing)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: Columns.menu)
            .opacity(hover || selected ? 1 : 0.55)
            .help("Actions")
        }
        .padding(.horizontal, 10)
        .frame(height: Columns.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.14) : (hover ? Color.primary.opacity(0.04) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
        .onHover { hover = $0 }
        .contextMenu { RowMenuItems(manager: manager, ui: ui, record: r, missing: missing) }
    }
}

struct StatusCell: View {
    let record: DownloadRecord
    let missing: Bool
    let speed: Double
    let eta: TimeInterval?
    /// True when the speed column is hidden, so the speed shows here.
    let showSpeed: Bool

    var body: some View {
        let r = record
        Group {
            if missing {
                label("File missing", "questionmark.folder", .orange)
                    .help("The file is no longer at \(r.finalPath)")
            } else {
                switch r.status {
                case .downloading:
                    progress(tint: .accentColor, line: downloadingLine)
                case .paused:
                    if let p = r.progress, p > 0 {
                        progress(tint: Color.secondary.opacity(0.7), line: Text("Paused  ·  \(percent(p))"))
                    } else {
                        label("Paused", "pause.circle", .secondary)
                    }
                case .queued:
                    label("Queued", "clock", .secondary)
                case .probing:
                    label("Connecting…", "antenna.radiowaves.left.and.right", .secondary)
                case .failed:
                    label("Failed", "exclamationmark.triangle.fill", .red)
                        .help(r.errorMessage ?? "Failed")
                case .completed:
                    label("Completed", "checkmark.circle", .secondary)
                case .cancelled:
                    label("Cancelled", "xmark.circle", Color.secondary.opacity(0.7))
                }
            }
        }
    }

    private func percent(_ p: Double) -> String { "\(Int((p * 100).rounded(.down)))%" }

    private var downloadingLine: Text {
        var parts: [String] = []
        if let p = record.progress { parts.append(percent(p)) } else { parts.append(Format.bytes(record.downloadedBytes)) }
        if let eta { parts.append("\(Format.duration(eta)) left") }
        if showSpeed { parts.append(Format.speed(speed)) }
        return Text(parts.joined(separator: "  ·  "))
    }

    private func progress(tint: Color, line: Text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SlimBar(value: record.progress, tint: tint)
            line.font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
    }

    private func label(_ text: String, _ symbol: String, _ colour: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11.5))
            Text(text).font(.system(size: 12, weight: colour == .red ? .semibold : .regular))
        }
        .foregroundStyle(colour)
    }
}

/// A 4 pt progress bar. Nil value shows a soft full track (unknown size).
struct SlimBar: View {
    let value: Double?
    let tint: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule().fill(tint.opacity(value == nil ? 0.35 : 1))
                    .frame(width: max(4, g.size.width * CGFloat(value ?? 1)))
            }
        }
        .frame(height: 4)
    }
}

/// A row's menu. Like the row, it takes its values rather than observing the manager.
struct RowMenuItems: View {
    let manager: DownloadManager
    let ui: ListState
    let record: DownloadRecord
    let missing: Bool

    var body: some View {
        let r = record
        let a = RowActions(manager: manager, ui: ui)
        if r.canPause {
            Button("Pause") { manager.pause(r.id) }
        } else if r.canResume {
            Button(r.status == .failed ? "Retry" : "Resume") { manager.resume(r.id) }
        }
        if r.status == .completed && !missing {
            Button("Open") { a.open(r) }
        }
        Button("Reveal in Finder") { a.reveal(r) }
        Button("Copy link") { Pasteboard.copy(r.url.absoluteString) }
        Button("Download again") { a.again(r) }
        Divider()
        Button("Remove from list") { a.remove([r.id]) }
        if !missing && r.status != .cancelled {
            Button("Delete file…") { a.deleteFiles([r.id]) }
        }
    }
}
