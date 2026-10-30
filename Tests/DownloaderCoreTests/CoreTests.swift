import Foundation
import Testing
@testable import DownloaderCore

@Suite struct SegmentPlanTests {
    @Test func evenSplitCoversWholeFile() {
        let size: Int64 = 100 * 1024 * 1024
        let segs = SegmentMath.plan(totalSize: size, connections: 8)
        #expect(segs.count == 8)
        #expect(segs.first?.start == 0)
        #expect(segs.last?.end == size - 1)
        for i in 1..<segs.count { #expect(segs[i].start == segs[i - 1].end + 1) }
        #expect(segs.reduce(0) { $0 + ($1.end - $1.start + 1) } == size)
    }

    @Test func unevenSizeGivesRemainderToLast() {
        let segs = SegmentMath.plan(totalSize: 10_000_003, connections: 4, minSegment: 1)
        #expect(segs.count == 4)
        #expect(segs.last?.end == 10_000_002)
        #expect(segs.reduce(0) { $0 + ($1.end - $1.start + 1) } == 10_000_003)
    }

    @Test func smallFileUsesFewerConnections() {
        let segs = SegmentMath.plan(totalSize: 700 * 1024, connections: 8)
        #expect(segs.count == 1)
        #expect(SegmentMath.plan(totalSize: 3 * 1024 * 1024, connections: 8).count == 6)
    }

    @Test func connectionsCappedAtSixteen() {
        #expect(SegmentMath.plan(totalSize: 1 << 32, connections: 40).count == 32)
        #expect(SegmentMath.plan(totalSize: 1 << 32, connections: 0).count == 1)
    }

    @Test func unknownSizeIsOneOpenSegment() {
        #expect(SegmentMath.plan(totalSize: nil, connections: 8) == [Segment(start: 0, end: -1)])
        #expect(SegmentMath.plan(totalSize: 0, connections: 8) == [Segment(start: 0, end: -1)])
    }
}

@Suite struct DynamicSplitTests {
    @Test func splitsLargestRemainingInHalf() {
        var segs = [
            Segment(start: 0, end: 999_999, received: 1_000_000),       // done
            Segment(start: 1_000_000, end: 9_999_999, received: 1_000_000), // 8,000,000 left
            Segment(start: 10_000_000, end: 11_999_999, received: 0),   // 2,000,000 left
        ]
        let n = SegmentMath.splitLargest(&segs, minSegment: 100_000)
        #expect(n == 3)
        #expect(segs[1].end == 5_999_999)
        #expect(segs[3] == Segment(start: 6_000_000, end: 9_999_999))
        // Halves still tile the original range with no gap or overlap.
        #expect(segs[1].remaining + segs[3].remaining == 8_000_000)
    }

    @Test func refusesToSplitTinyRemainder() {
        var segs = [Segment(start: 0, end: 999, received: 10)]
        #expect(SegmentMath.splitLargest(&segs, minSegment: 1000) == nil)
        #expect(segs.count == 1)
    }

    @Test func skipsExcludedAndOpenEnded() {
        var segs = [Segment(start: 0, end: -1), Segment(start: 0, end: 9_999_999)]
        #expect(SegmentMath.splitLargest(&segs, minSegment: 10, excluding: [1]) == nil)
    }

    @Test func repeatedSplitsKeepCoverage() {
        let size: Int64 = 50_000_000
        var segs = SegmentMath.plan(totalSize: size, connections: 2)
        segs[0].received = segs[0].end - segs[0].start + 1
        while SegmentMath.splitLargest(&segs, minSegment: 1_000_000) != nil {}
        let sorted = segs.sorted { $0.start < $1.start }
        #expect(sorted.first?.start == 0)
        #expect(sorted.last?.end == size - 1)
        for i in 1..<sorted.count { #expect(sorted[i].start == sorted[i - 1].end + 1) }
    }
}

@Suite struct RangeHeaderTests {
    @Test func freshSegment() {
        #expect(SegmentMath.rangeHeader(for: Segment(start: 100, end: 199)) == "bytes=100-199")
    }

    @Test func resumedSegmentStartsAtCurrent() {
        #expect(SegmentMath.rangeHeader(for: Segment(start: 100, end: 199, received: 50)) == "bytes=150-199")
    }

    @Test func openEnded() {
        #expect(SegmentMath.rangeHeader(for: Segment(start: 0, end: -1)) == nil)
        #expect(SegmentMath.rangeHeader(for: Segment(start: 0, end: -1, received: 500)) == "bytes=500-")
    }

    @Test func remainingAndCompletion() {
        var s = Segment(start: 0, end: 9)
        #expect(s.remaining == 10)
        s.received = 10
        #expect(s.isComplete)
        #expect(s.remaining == 0)
    }

    @Test func parsesContentRange() {
        let r = SegmentMath.parseContentRange("bytes 0-0/104857600")
        #expect(r?.start == 0 && r?.end == 0 && r?.total == 104_857_600)
        #expect(SegmentMath.parseContentRange("bytes 5-9/*")?.total == nil)
        #expect(SegmentMath.parseContentRange("bytes */100") == nil)
        #expect(SegmentMath.parseContentRange("items 0-1/2") == nil)
    }
}

@Suite struct FilenameTests {
    @Test func plainQuoted() {
        #expect(FileNaming.filename(fromContentDisposition: "attachment; filename=\"report 2026.pdf\"") == "report 2026.pdf")
    }

    @Test func unquoted() {
        #expect(FileNaming.filename(fromContentDisposition: "attachment; filename=setup.dmg") == "setup.dmg")
    }

    @Test func rfc5987WinsOverPlain() {
        let h = "attachment; filename=\"fallback.zip\"; filename*=UTF-8''%E0%A6%AC%E0%A6%BE%E0%A6%82%E0%A6%B2%E0%A6%BE.zip"
        #expect(FileNaming.filename(fromContentDisposition: h) == "বাংলা.zip")
    }

    @Test func semicolonInsideQuotes() {
        #expect(FileNaming.filename(fromContentDisposition: "attachment; filename=\"a;b.txt\"") == "a;b.txt")
    }

    @Test func pathTraversalIsNeutralised() {
        let n = FileNaming.filename(fromContentDisposition: "attachment; filename=\"../../etc/passwd\"")
        #expect(n != nil)
        #expect(!(n ?? "/").contains("/"))
    }

    @Test func fromURL() {
        #expect(FileNaming.filename(fromURL: URL(string: "https://x.org/files/My%20File.iso?sig=1")!) == "My File.iso")
        #expect(FileNaming.filename(fromURL: URL(string: "https://x.org/")!) == nil)
    }

    @Test func chooseOrder() {
        let u = URL(string: "https://x.org/dl?id=1")!
        let f = URL(string: "https://cdn.x.org/real.tar.gz")!
        #expect(FileNaming.chooseName(suggested: "mine.bin", contentDisposition: "attachment; filename=cd.bin", finalURL: f, originalURL: u) == "mine.bin")
        #expect(FileNaming.chooseName(suggested: nil, contentDisposition: "attachment; filename=cd.bin", finalURL: f, originalURL: u) == "cd.bin")
        #expect(FileNaming.chooseName(suggested: nil, contentDisposition: nil, finalURL: f, originalURL: u) == "real.tar.gz")
        #expect(FileNaming.chooseName(suggested: nil, contentDisposition: "inline", finalURL: nil, originalURL: URL(string: "https://x.org/")!, mimeType: "application/zip") == "download.zip")
    }
}

@Suite struct UniqueNameTests {
    @Test func freeNameUnchanged() {
        #expect(FileNaming.uniqueName("a.zip") { _ in false } == "a.zip")
    }

    @Test func appendsCounterBeforeExtension() {
        let taken: Set = ["a.zip", "a (1).zip"]
        #expect(FileNaming.uniqueName("a.zip") { taken.contains($0) } == "a (2).zip")
    }

    @Test func keepsCompoundExtension() {
        #expect(FileNaming.uniqueName("src.tar.gz") { $0 == "src.tar.gz" } == "src (1).tar.gz")
    }

    @Test func noExtensionAndDotfile() {
        #expect(FileNaming.uniqueName("README") { $0 == "README" } == "README (1)")
        #expect(FileNaming.uniqueName(".env") { $0 == ".env" } == ".env (1)")
    }

    @Test func onDiskIncludesPartFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("x.iso").path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("x (1).iso.part").path, contents: Data())
        #expect(FileNaming.uniqueName("x.iso", inDirectory: dir.path) == "x (2).iso")
    }
}

@Suite struct ServerTests {
    let token = String(repeating: "ab", count: 24)

    func req(_ method: String, _ path: String, headers: [String: String] = [:], body: String = "") -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8))
    }

    @Test func pingNeedsNoToken() {
        guard case .respond(let r) = APIRouter.route(req("GET", "/ping"), token: token) else { Issue.record("expected response"); return }
        #expect(r.status == 200)
    }

    @Test func addWithoutTokenIs401() {
        guard case .respond(let r) = APIRouter.route(req("POST", "/add", body: #"{"url":"https://x.org/a"}"#), token: token) else {
            Issue.record("expected 401"); return
        }
        #expect(r.status == 401)
    }

    @Test func addWithTokenParses() {
        let r = APIRouter.route(req("POST", "/add", headers: ["x-macdownloader-token": token],
                                    body: #"{"url":"https://x.org/a.zip","cookies":"s=1","fileSize":5}"#), token: token)
        guard case .run(.add(let add)) = r else { Issue.record("expected add"); return }
        #expect(add.cookies == "s=1")
        #expect(add.fileSize == 5)
    }

    @Test func webOriginRejected() {
        guard case .respond(let r) = APIRouter.route(req("POST", "/add", headers: ["origin": "https://evil.example", "x-macdownloader-token": token]), token: token) else {
            Issue.record("expected 403"); return
        }
        #expect(r.status == 403)
    }

    @Test func nonHTTPURLRejected() {
        guard case .respond(let r) = APIRouter.route(req("POST", "/add", headers: ["authorization": "Bearer \(token)"], body: #"{"url":"file:///etc/passwd"}"#), token: token) else {
            Issue.record("expected 400"); return
        }
        #expect(r.status == 400)
    }

    @Test func parsesSplitRequest() {
        let raw = "POST /add?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 4\r\n\r\nab"
        guard case .needMore = LocalServer.parse(Data(raw.utf8)) else { Issue.record("expected needMore"); return }
        guard case .complete(let r) = LocalServer.parse(Data((raw + "cd").utf8)) else { Issue.record("expected complete"); return }
        #expect(r.path == "/add")
        #expect(String(data: r.body, encoding: .utf8) == "abcd")
    }
}

@Suite struct RedirectTests {
    func req(_ s: String) -> URLRequest {
        var r = URLRequest(url: URL(string: s)!)
        r.setValue("sid=1", forHTTPHeaderField: "Cookie")
        r.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        return r
    }

    @Test func sameSiteKeepsCookies() {
        let out = RedirectPolicy.request(req("https://dl.example.com/f"), from: req("https://example.com/get"))
        #expect(out.value(forHTTPHeaderField: "Cookie") == "sid=1")
    }

    @Test func otherSiteDropsCookiesKeepsRange() {
        let out = RedirectPolicy.request(req("https://cdn.other.net/f"), from: req("https://example.com/get"))
        #expect(out.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(out.value(forHTTPHeaderField: "Range") == "bytes=0-9")
    }
}

@Suite struct LimiterTests {
    @Test func holdsBackWhenOverBudget() {
        let l = SpeedLimiter()
        l.bytesPerSecond = 1024 * 1024
        #expect(l.consume(100_000) == 0)
        let d = l.consume(1_000_000)
        #expect(d > 0.7 && d < 1.0)
    }

    @Test func unlimitedNeverWaits() {
        let l = SpeedLimiter()
        #expect(l.consume(10_000_000) == 0)
    }
}
