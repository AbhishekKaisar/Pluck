import AppKit
import SwiftUI
import DownloaderCore

struct DetailPanel: View {
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var ui: ListState
    let record: DownloadRecord
    let compact: Bool
    @ViewState private var copied = false

    var body: some View {
        let r = record
        let missing = manager.missing.contains(r.id)
        let actions = RowActions(manager: manager, ui: ui)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: FileIcons.icon(for: r, missing: missing))
                    .resizable().interpolation(.high).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.fileName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text(summary(missing: missing))
                        .font(.system(size: 12))
                        .foregroundStyle(r.status == .failed ? Color.red : Color.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    ui.showDetails = false
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Hide details")
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    key("Link")
                    HStack(spacing: 8) {
                        Text(r.url.absoluteString)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy") {
                            Pasteboard.copy(r.url.absoluteString)
                            copied = true
                        }
                        .controlSize(.small)
                    }
                }
                GridRow {
                    key("Saved to")
                    HStack(spacing: 8) {
                        Text((missing ? r.finalPath : savedPath) as String)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            .strikethrough(missing, color: .secondary)
                        Button("Reveal in Finder") { actions.reveal(r) }
                            .controlSize(.small)
                    }
                }
                GridRow {
                    key("Connections")
                    Text(connectionsText).monospacedDigit()
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.primary)

            if r.totalSize != nil, !r.segments.isEmpty, !missing {
                VStack(alignment: .leading, spacing: 5) {
                    SegmentMap(record: r)
                        .frame(height: 16)
                    HStack {
                        Text(segmentCaption)
                        Spacer()
                        if let p = r.progress { Text("\(Int((p * 100).rounded(.down)))%").monospacedDigit() }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .onChange(of: record.id) { _, _ in copied = false }
    }

    private var savedPath: String {
        record.status == .completed ? record.finalPath : record.partPath
    }

    private func key(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func summary(missing: Bool) -> String {
        let r = record
        let size = r.totalSize.map(Format.bytes)
        if missing { return "Finished, but the file is no longer on disk" }
        switch r.status {
        case .downloading:
            var parts = [size.map { "\(Format.bytes(r.downloadedBytes)) of \($0)" } ?? "\(Format.bytes(r.downloadedBytes)) so far"]
            parts.append(Format.speed(manager.speeds[r.id] ?? 0))
            if let eta = manager.eta(for: r) { parts.append("\(Format.duration(eta)) left") }
            return parts.joined(separator: "  ·  ")
        case .paused:
            return "Paused at " + (size.map { "\(Format.bytes(r.downloadedBytes)) of \($0)" } ?? Format.bytes(r.downloadedBytes))
        case .queued: return "Waiting for a free slot" + (size.map { "  ·  \($0)" } ?? "")
        case .probing: return "Connecting to \(r.url.host ?? "the server")"
        case .failed: return r.errorMessage ?? "Failed"
        case .completed:
            let when = r.completedAt.map { "  ·  finished " + Format.added($0) } ?? ""
            return (size ?? Format.bytes(r.downloadedBytes)) + when
        case .cancelled: return "Cancelled"
        }
    }

    private var connectionsText: String {
        let r = record
        let planned = r.connections ?? manager.settings.connections
        let resume = r.probed ? (r.acceptsRanges ? "resumable" : "no resume support, one connection") : "not checked yet"
        if r.status.isActive {
            let n = manager.activeConnections[r.id] ?? 0
            return "\(n) of \(r.acceptsRanges ? planned : 1) in use  ·  \(resume)"
        }
        if r.status == .completed {
            return r.segments.count > 1 ? "Fetched in \(r.segments.count) parts  ·  \(resume)" : "Fetched in one stream"
        }
        return "\(r.acceptsRanges || !r.probed ? planned : 1) planned  ·  \(resume)"
    }

    private var segmentCaption: String {
        let r = record
        let done = r.segments.filter(\.isComplete).count
        if r.status == .completed { return "All \(r.segments.count) parts done" }
        let busy = r.status.isActive ? (manager.activeConnections[r.id] ?? 0) : 0
        var s = "\(r.segments.count) parts, \(done) done"
        if busy > 0 { s += ", \(busy) downloading now" }
        return s
    }
}

/// IDM-style map: the file as one bar, each part drawn where it sits, filling in as its connection writes.
struct SegmentMap: View {
    let record: DownloadRecord

    var body: some View {
        let total = Double(max(1, record.totalSize ?? 1))
        let finished = record.status == .completed
        let active = record.status.isActive
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.primary.opacity(0.07))
                if finished && record.segments.isEmpty {
                    Rectangle().fill(Color.accentColor.opacity(0.55))
                }
                ForEach(Array(record.segments.enumerated()), id: \.offset) { _, s in
                    let end = s.isOpenEnded ? total - 1 : Double(s.end)
                    let x = CGFloat(Double(s.start) / total) * w
                    let full = CGFloat((end - Double(s.start) + 1) / total) * w
                    let filled = CGFloat(Double(min(s.received, Int64(end) - s.start + 1)) / total) * w
                    let fill: Color = finished ? Color.accentColor.opacity(0.55)
                        : (s.isComplete ? Color.accentColor.opacity(0.75) : (active ? Color.accentColor : Color.secondary.opacity(0.6)))
                    Rectangle().fill(fill)
                        .frame(width: max(0, min(full, filled)), height: h)
                        .offset(x: x)
                    if active && !s.isComplete && filled > 0 && filled < full {
                        // The write head of a live connection.
                        Rectangle().fill(Color.white.opacity(0.9))
                            .frame(width: 1.5, height: h)
                            .offset(x: x + filled - 1.5)
                    }
                    if s.start > 0 {
                        Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                            .frame(width: 1, height: h)
                            .offset(x: x)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityLabel("Segment map")
    }
}
