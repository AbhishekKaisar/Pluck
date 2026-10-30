import Foundation
import Testing
@testable import DownloaderCore

private func record(_ name: String, _ status: DownloadStatus, size: Int64? = nil, age: TimeInterval = 0,
                    host: String = "example.com") -> DownloadRecord {
    var r = DownloadRecord(url: URL(string: "https://\(host)/files/\(name)")!, fileName: name, directory: "/tmp/md-tests",
                           headers: RequestHeaders())
    r.status = status
    r.totalSize = size
    r.createdAt = Date(timeIntervalSince1970: 1_800_000_000 - age)
    return r
}

@Suite struct CategoryTests {
    @Test func byExtension() {
        #expect(FileCategory.of(fileName: "film.MKV") == .video)
        #expect(FileCategory.of(fileName: "song.flac") == .audio)
        #expect(FileCategory.of(fileName: "linux-6.6.tar.xz") == .archives)
        #expect(FileCategory.of(fileName: "Setup.dmg") == .programs)
        #expect(FileCategory.of(fileName: "report.pdf") == .documents)
        #expect(FileCategory.of(fileName: "README") == .other)
        #expect(FileCategory.of(fileName: "data.bin") == .other)
    }

    @Test func filterRawValuesRoundTrip() {
        for f in ListFilter.statusFilters + ListFilter.categoryFilters {
            #expect(ListFilter(rawValue: f.rawValue) == f)
        }
        #expect(ListFilter(rawValue: "category.nope") == nil)
        #expect(ListFilter(rawValue: "") == nil)
    }
}

@Suite struct ListQueryTests {
    let items = [
        record("b-video.mp4", .downloading, size: 300, age: 10),
        record("a-notes.pdf", .completed, size: 50, age: 30),
        record("C-archive.zip", .paused, size: nil, age: 20),
        record("d-gone.iso", .completed, size: 900, age: 40),
        record("e-broken.dmg", .failed, size: 10, age: 5, host: "mirror.test"),
    ]

    @Test func sortOrders() {
        let names = { (s: ListSort) in ListQuery.apply(items, sort: s, filter: .all, search: "").map(\.fileName) }
        #expect(names(.newest) == ["e-broken.dmg", "b-video.mp4", "C-archive.zip", "a-notes.pdf", "d-gone.iso"])
        #expect(names(.oldest) == ["d-gone.iso", "a-notes.pdf", "C-archive.zip", "b-video.mp4", "e-broken.dmg"])
        #expect(names(.nameAscending) == ["a-notes.pdf", "b-video.mp4", "C-archive.zip", "d-gone.iso", "e-broken.dmg"])
        #expect(names(.nameDescending).first == "e-broken.dmg")
        #expect(names(.sizeLargest) == ["d-gone.iso", "b-video.mp4", "a-notes.pdf", "e-broken.dmg", "C-archive.zip"])
        #expect(names(.sizeSmallest) == ["e-broken.dmg", "a-notes.pdf", "b-video.mp4", "d-gone.iso", "C-archive.zip"])
    }

    @Test func statusSortPutsMissingBeforeCompleted() {
        let missing: Set<UUID> = [items[3].id]
        let names = ListQuery.apply(items, sort: .status, filter: .all, search: "", missing: missing).map(\.fileName)
        #expect(names == ["b-video.mp4", "C-archive.zip", "e-broken.dmg", "d-gone.iso", "a-notes.pdf"])
    }

    @Test func filters() {
        let missing: Set<UUID> = [items[3].id]
        let names = { (f: ListFilter) in ListQuery.apply(items, sort: .nameAscending, filter: f, search: "", missing: missing).map(\.fileName) }
        #expect(names(.active) == ["b-video.mp4", "C-archive.zip"])
        #expect(names(.completed) == ["a-notes.pdf"])
        #expect(names(.missing) == ["d-gone.iso"])
        #expect(names(.category(.archives)) == ["C-archive.zip", "d-gone.iso"])
        #expect(names(.category(.audio)).isEmpty)
    }

    @Test func searchCombinesWithFilterAndSort() {
        let r = ListQuery.apply(items, sort: .newest, filter: .all, search: "  MIRROR  ")
        #expect(r.map(\.fileName) == ["e-broken.dmg"])
        let both = ListQuery.apply(items, sort: .oldest, filter: .category(.archives), search: "zip")
        #expect(both.map(\.fileName) == ["C-archive.zip"])
        #expect(ListQuery.apply(items, sort: .newest, filter: .all, search: "video files").map(\.fileName) == ["b-video.mp4"])
        #expect(ListQuery.apply(items, sort: .newest, filter: .all, search: "video pdf").isEmpty)
    }

    @Test func quickSelection() {
        let missing: Set<UUID> = [items[3].id]
        #expect(items.filter { QuickSelection.completed.matches($0, missing: missing) }.map(\.fileName) == ["a-notes.pdf"])
        #expect(items.filter { QuickSelection.paused.matches($0, missing: missing) }.count == 1)
        #expect(items.filter { QuickSelection.all.matches($0, missing: missing) }.count == items.count)
    }
}

@Suite struct LinkParserTests {
    @Test func oneLinePerLineAndDuplicates() {
        let text = """
        https://example.com/a.zip
          http://example.com/b.iso\r
        https://example.com/a.zip
        ftp://example.com/c
        not a link
        """
        #expect(LinkParser.links(in: text).map(\.absoluteString) == ["https://example.com/a.zip", "http://example.com/b.iso"])
    }

    @Test func linksInsideProse() {
        let text = "Get it from <https://cdn.test/x.tar.xz>, or (https://mirror.test/x.tar.xz). \"https://q.test/y?z=1\""
        #expect(LinkParser.links(in: text).map(\.absoluteString) ==
                ["https://cdn.test/x.tar.xz", "https://mirror.test/x.tar.xz", "https://q.test/y?z=1"])
    }

    @Test func rejectsHostless() {
        #expect(LinkParser.links(in: "https:// http:/x").isEmpty)
    }
}

@Suite struct CompatibilityTests {
    @Test func oldSettingsFileLoads() throws {
        let json = #"{"connections":32,"downloadDirectory":"/Users/x/Downloads","maxConcurrent":3,"speedLimitKiB":0}"#
        let s = try JSONDecoder.iso.decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.connections == 32)
        #expect(s.speedLimitKiB == 0)
        #expect(s.speedLimitValueKiB == 1024)
        let limited = #"{"connections":8,"downloadDirectory":"/d","maxConcurrent":2,"speedLimitKiB":500}"#
        let l = try JSONDecoder.iso.decode(AppSettings.self, from: Data(limited.utf8))
        #expect(l.speedLimitOn)
        #expect(l.speedLimitValueKiB == 500)
    }

    @Test func speedLimitToggleRemembersValue() throws {
        var s = AppSettings(speedLimitKiB: 0, speedLimitValueKiB: 2048)
        s.setSpeedLimit(on: true)
        #expect(s.speedLimitKiB == 2048)
        s.setSpeedLimit(on: false)
        #expect(s.speedLimitKiB == 0)
        #expect(s.speedLimitValueKiB == 2048)
        let round = try JSONDecoder.iso.decode(AppSettings.self, from: JSONEncoder.iso.encode(s))
        #expect(round == s)
    }

    @Test func oldRecordWithoutConnectionsLoads() throws {
        let json = """
        [{"acceptsRanges":true,"createdAt":"2026-10-30T01:31:42Z","directory":"/d","fileName":"a.zip",
          "headers":{},"id":"9B2D2E43-6C1B-4C8F-9A0C-3C1C1E9B6A11","nameIsFixed":false,"probed":true,
          "segments":[{"start":0,"end":99,"received":100}],"status":"completed","totalSize":100,
          "url":"https://example.com/a.zip"}]
        """
        let list = try JSONDecoder.iso.decode([DownloadRecord].self, from: Data(json.utf8))
        #expect(list.count == 1)
        #expect(list[0].connections == nil)
    }
}

@MainActor @Suite struct ManagerTests {
    @Test func missingDetection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("md-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var here = record("here.zip", .completed, size: 1)
        here.directory = dir.path
        var gone = record("gone.zip", .completed, size: 1)
        gone.directory = dir.path
        var paused = record("paused.zip", .paused, size: 1)
        paused.directory = dir.path
        FileManager.default.createFile(atPath: here.finalPath, contents: Data([1]))
        let m = DownloadManager(inMemory: [here, gone, paused])
        #expect(m.missing == [gone.id])
        FileManager.default.createFile(atPath: gone.finalPath, contents: Data([1]))
        try FileManager.default.removeItem(atPath: here.finalPath)
        m.refreshMissing()
        #expect(m.missing == [here.id])
    }

    @Test func addLaterIsPausedWithItsOwnConnections() {
        let m = DownloadManager(inMemory: [])
        let id = m.add(url: URL(string: "https://example.com/x.iso")!, fileName: "renamed.iso", directory: "/tmp/elsewhere",
                       connections: 99, startPaused: true)
        let r = m.item(id)
        #expect(r?.status == .paused)
        #expect(r?.connections == SegmentMath.maxConnections)
        #expect(r?.fileName == "renamed.iso")
        #expect(r?.nameIsFixed == true)
        #expect(r?.directory == "/tmp/elsewhere")
    }

    @Test func downloadAgainReplacesRow() {
        let old = record("old.zip", .completed, size: 5)
        let m = DownloadManager(inMemory: [old], missing: [old.id])
        let new = m.downloadAgain(old.id)
        #expect(m.items.count == 1)
        #expect(m.items[0].id == new)
        #expect(m.items[0].status == .queued)
        #expect(m.missing.isEmpty)
    }
}
