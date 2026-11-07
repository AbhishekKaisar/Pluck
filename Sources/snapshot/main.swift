// Renders the real Pluck views with sample data into PNGs, offscreen.
// Usage: snapshot [output directory]   (default build/snapshots)
import AppKit
import SwiftUI
import DownloaderCore
import PluckUI

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/snapshots"
let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
// A made-up home folder: nothing here touches the real disk, and missing files are passed in.
let sampleDir = "/Users/sam/Downloads"

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let now = Date()
let MB: Int64 = 1 << 20

func rec(_ name: String, _ url: String, _ status: DownloadStatus, size: Int64?, minutesAgo: Double,
         segments: [Segment] = [], ranges: Bool = true, error: String? = nil) -> DownloadRecord {
    var r = DownloadRecord(url: URL(string: url)!, fileName: name, directory: sampleDir, headers: RequestHeaders())
    r.status = status
    r.totalSize = size
    r.acceptsRanges = ranges
    r.probed = status != .queued
    r.segments = segments
    r.errorMessage = error
    r.createdAt = now.addingTimeInterval(-minutesAgo * 60)
    if status == .completed { r.completedAt = r.createdAt.addingTimeInterval(90) }
    return r
}

/// Segments like the engine leaves them mid-download: an even plan plus two dynamic splits.
func liveSegments(size: Int64, parts: Int, fractions: [Double]) -> [Segment] {
    var segs = SegmentMath.plan(totalSize: size, connections: parts)
    for i in segs.indices {
        let len = segs[i].end - segs[i].start + 1
        segs[i].received = Int64(Double(len) * fractions[i % fractions.count])
    }
    _ = SegmentMath.splitLargest(&segs)
    _ = SegmentMath.splitLargest(&segs)
    if let last = segs.indices.last { segs[last].received = segs[last].remaining / 5 }
    return segs
}

let isoSize: Int64 = 5_920 * MB
let iso = rec("ubuntu-24.04.1-desktop-amd64.iso", "https://releases.ubuntu.com/24.04.1/ubuntu-24.04.1-desktop-amd64.iso",
              .downloading, size: isoSize, minutesAgo: 3,
              segments: liveSegments(size: isoSize, parts: 16, fractions: [1, 0.92, 0.55, 1, 0.38, 0.71, 0.2, 1, 0.64, 0.47, 0.83, 0.12, 0.58, 1, 0.33, 0.05]))
let toolsSize: Int64 = 812 * MB
let tools = rec("Command Line Tools for Xcode 26.dmg", "https://downloads.example.com/developer/clt-26.dmg",
                .downloading, size: toolsSize, minutesAgo: 1,
                segments: liveSegments(size: toolsSize, parts: 8, fractions: [0.18, 0.11, 0.09, 0.15, 0.07, 0.12, 0.1, 0.06]))
let pausedSize: Int64 = 2_300 * MB
var paused = rec("Wedding film 2026, final edit with colour grade and stereo mix (4K master).mov",
                 "https://media.example.org/share/wedding-final-4k.mov", .paused, size: pausedSize, minutesAgo: 50,
                 segments: SegmentMath.plan(totalSize: pausedSize, connections: 16).enumerated().map { i, s in
                     var s = s; s.received = (s.end - s.start + 1) * Int64([42, 40, 45, 39][i % 4]) / 100; return s })
paused.connections = 16
let queued = rec("lecture-07-distributed-systems.mp4", "https://cdn.example.edu/courses/cs451/lecture-07.mp4",
                 .queued, size: 1_240 * MB, minutesAgo: 0.5)
let failed = rec("student-records-export.csv", "https://portal.example.com/export/records.csv", .failed, size: nil,
                 minutesAgo: 140, ranges: false, error: "Server answered HTTP 403")
let report = rec("Annual Report 2025.pdf", "https://files.example.com/reports/annual-2025.pdf", .completed,
                 size: 18 * MB, minutesAgo: 60 * 26,
                 segments: SegmentMath.plan(totalSize: 18 * MB, connections: 16).map { var s = $0; s.received = s.end - s.start + 1; return s })
let photos = rec("photos-october.zip", "https://files.example.com/albums/photos-october.zip", .completed, size: 640 * MB,
                 minutesAgo: 60 * 30,
                 segments: SegmentMath.plan(totalSize: 640 * MB, connections: 16).map { var s = $0; s.received = s.end - s.start + 1; return s })
let gone = rec("podcast-episode-112.mp3", "https://audio.example.net/feeds/ep112.mp3", .completed, size: 74 * MB,
               minutesAgo: 60 * 24 * 9)
let song = rec("linux-6.6.tar.xz", "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.tar.xz", .completed,
               size: 136 * MB, minutesAgo: 60 * 24 * 40)


let items = [queued, tools, iso, paused, failed, report, photos, gone, song]
let speeds: [UUID: Double] = [iso.id: 18.4e6, tools.id: 6.1e6]
let conns: [UUID: Int] = [iso.id: 14, tools.id: 8]
let settings = AppSettings(downloadDirectory: sampleDir, connections: 16, maxConcurrent: 3,
                           speedLimitKiB: 0, speedLimitValueKiB: 2048)

@MainActor
func model(items: [DownloadRecord], settings: AppSettings = settings, selection: Set<UUID> = [],
           search: String = "") -> AppModel {
    let manager = DownloadManager(inMemory: items, settings: settings, speeds: speeds, connections: conns,
                                  missing: Set(items.filter { $0.id == gone.id }.map(\.id)))
    let ui = ListState(persists: false)
    ui.selection = selection
    ui.search = search
    return AppModel(preview: manager, ui: ui)
}

@MainActor
func render<V: View>(_ view: V, model m: AppModel?, size: CGSize, dark: Bool, name: String) {
    let root = AnyView(Group {
        if let m {
            view.environmentObject(m).environmentObject(m.manager).environmentObject(m.ui)
        } else {
            view
        }
    }.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
    let host = NSHostingView(rootView: root)
    let rect = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    host.frame = rect
    for _ in 0..<4 {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    let path = (outDir as NSString).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print(path)
}

MainActor.assumeIsolated {
    let big = CGSize(width: 1100, height: 700), small = CGSize(width: 760, height: 520)
    for dark in [false, true] {
        for (size, tag) in [(big, "1100x700"), (small, "760x520")] {
            render(ContentView(), model: model(items: items), size: size, dark: dark, name: "list-\(tag)")
            render(ContentView(), model: model(items: items, selection: [iso.id]), size: size, dark: dark, name: "detail-\(tag)")
            render(ContentView(), model: model(items: items, selection: [iso.id, paused.id, report.id]), size: size, dark: dark,
                   name: "multiselect-\(tag)")
            render(ContentView(), model: model(items: []), size: size, dark: dark, name: "empty-\(tag)")
        }
        // Speed limit on, a completed row selected, a search applied.
        var limited = settings
        limited.setSpeedLimit(on: true)
        render(ContentView(), model: model(items: items, settings: limited, selection: [gone.id]), size: big, dark: dark,
               name: "missing-detail-limit-1100x700")
        render(ContentView(), model: model(items: items, search: "zip"), size: small, dark: dark, name: "search-760x520")

        let probed = AddDraft(text: "https://releases.ubuntu.com/24.04.1/ubuntu-24.04.1-desktop-amd64.iso", fromClipboard: true,
                              settings: settings,
                              probe: .done(ProbeResult(fileName: "ubuntu-24.04.1-desktop-amd64.iso", totalSize: isoSize, acceptsRanges: true)))
        let m = model(items: items)
        render(AddDownloadSheet(draft: probed), model: m, size: CGSize(width: 520, height: 330), dark: dark, name: "add-sheet-probed")
        let many = AddDraft(text: "https://cdn.example.edu/a.mp4\nhttps://cdn.example.edu/b.mp4\nhttps://cdn.example.edu/c.pdf",
                            fromClipboard: false, settings: settings, probe: .idle)
        render(AddDownloadSheet(draft: many), model: m, size: CGSize(width: 520, height: 290), dark: dark, name: "add-sheet-many")
        // A browser download waiting for an answer, then the same with a second one behind it.
        let browser = AddDraft(text: "https://downloads.example.com/reports/annual-2025.pdf", fromClipboard: false,
                               settings: settings, probe: .done(ProbeResult(fileName: "annual-2025.pdf", totalSize: 18 * MB, acceptsRanges: true)),
                               headers: RequestHeaders(cookies: "session=sample"), fileName: "Annual Report 2025.pdf", browserSize: 18 * MB)
        let single = model(items: items)
        single.ui.present(browser)
        render(AddDownloadSheet(draft: browser), model: single, size: CGSize(width: 520, height: 330), dark: dark, name: "add-sheet-browser")
        let second = AddDraft(text: "https://cdn.example.edu/courses/cs451/lecture-08.mp4", fromClipboard: false, settings: settings, probe: .idle,
                              fileName: "lecture-08.mp4", browserSize: 1_180 * MB)
        let waiting = model(items: items)
        waiting.ui.present(browser)
        waiting.ui.present(second)
        render(AddDownloadSheet(draft: browser), model: waiting, size: CGSize(width: 520, height: 330), dark: dark, name: "add-sheet-browser-waiting")
        var asking = settings
        asking.askWhereToSave = true
        render(SettingsView().frame(maxHeight: .infinity, alignment: .top).background(Color(nsColor: .windowBackgroundColor)),
               model: model(items: items, settings: asking), size: CGSize(width: 500, height: 540), dark: dark, name: "settings-ask-on")
        render(SettingsView().frame(maxHeight: .infinity, alignment: .top).background(Color(nsColor: .windowBackgroundColor)),
               model: m, size: CGSize(width: 500, height: 540), dark: dark, name: "settings")
    }
}
