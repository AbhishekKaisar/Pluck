import Combine
import Foundation
import Testing
@testable import DownloaderCore
@testable import PluckUI

@Suite struct AskSettingsTests {
    @Test func oldSettingsFileDecodesToFalse() throws {
        let json = #"{"downloadDirectory":"/tmp/x","connections":8,"maxConcurrent":2,"speedLimitKiB":0}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.askWhereToSave == false)
        #expect(s.downloadDirectory == "/tmp/x")
        #expect(s.connections == 8)
    }

    @Test func trueSurvivesARoundTrip() throws {
        var s = AppSettings(downloadDirectory: "/tmp/x")
        s.askWhereToSave = true
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.askWhereToSave == true)
        #expect(back == s)
    }
}

@MainActor
private func draft(_ url: String, settings: AppSettings = AppSettings(downloadDirectory: "/tmp/ask-default"),
                   headers: RequestHeaders = RequestHeaders(), name: String? = nil, size: Int64? = nil) -> AddDraft {
    AddDraft(caught: URL(string: url)!, settings: settings, probe: .idle, headers: headers, fileName: name, browserSize: size)
}


@MainActor @Suite struct AskDraftTests {
    @Test func commitKeepsHeadersNameSizeAndFolder() {
        let manager = DownloadManager(inMemory: [], settings: AppSettings(downloadDirectory: "/tmp/ask-default", connections: 16))
        let h = RequestHeaders(cookies: "session=abc", referrer: "https://example.com/page", userAgent: "TestAgent/1")
        let d = draft("https://example.com/files/data.bin", headers: h, name: "Report 2026.pdf", size: 4096)
        d.directory = "/tmp/ask-chosen"
        #expect(d.commit(to: manager, later: true) == 1)
        let r = manager.items[0]
        #expect(r.headers == h)
        #expect(r.fileName == "Report 2026.pdf")
        #expect(r.nameIsFixed == true)
        #expect(r.totalSize == 4096)
        #expect(r.directory == "/tmp/ask-chosen")
        #expect(r.status == .paused)
    }

    @Test func headersGoOnlyToTheirOwnHost() {
        let manager = DownloadManager(inMemory: [], settings: AppSettings())
        let h = RequestHeaders(cookies: "session=abc")
        let d = draft("https://example.com/a.bin", headers: h)
        d.text = "https://example.com/a.bin\nhttps://other.org/b.bin"
        #expect(d.commit(to: manager, later: true) == 2)
        let byHost = Dictionary(uniqueKeysWithValues: manager.items.map { ($0.url.host!, $0.headers) })
        #expect(byHost["example.com"]?.cookies == "session=abc")
        #expect(byHost["other.org"]?.cookies == nil)
    }

    @Test func browserNameIsNotReplacedByTheProbe() {
        let d = draft("https://example.com/a", name: "chosen.zip")
        #expect(d.fileName == "chosen.zip")
        #expect(d.nameEdited == true)
        let plain = draft("https://example.com/a")
        #expect(plain.nameEdited == false)
    }

    @Test func theBrowsersExactLinkIsDownloaded() {
        // Characters LinkParser treats as text around a link are valid in a real URL.
        for url in ["https://example.com/files/Bob's%20Report.pdf",
                    "https://s3.example.com/k?response-content-disposition=filename*=UTF-8\'\'r.pdf&X-Amz-Signature=abc",
                    "https://example.com/wiki/File_(1)",
                    "https://example.com/report."] {
            let manager = DownloadManager(inMemory: [], settings: AppSettings())
            let d = draft(url)
            #expect(d.links.map(\.absoluteString) == [url])
            d.commit(to: manager, later: true)
            #expect(manager.items.map(\.url.absoluteString) == [url])
        }
    }

    @Test func aNewLinkDropsTheBrowsersNameAndSize() {
        let manager = DownloadManager(inMemory: [], settings: AppSettings())
        let d = draft("https://example.com/report.pdf", name: "report.pdf", size: 4096)
        d.text = "https://cdn.example.com/video.mp4"
        #expect(d.fileName == "")
        #expect(d.nameEdited == false)
        #expect(d.caughtSize == nil)
        d.commit(to: manager, later: true)
        #expect(manager.items[0].fileName == "video.mp4")
        #expect(manager.items[0].nameIsFixed == false)
        #expect(manager.items[0].totalSize == nil)
    }

    @Test func aTypedNameSurvivesANewLink() {
        let d = draft("https://example.com/report.pdf", name: "report.pdf")
        d.fileName = "mine.pdf"
        d.text = "https://cdn.example.com/video.mp4"
        #expect(d.fileName == "mine.pdf")
        #expect(d.nameEdited == true)
    }

    @Test func theProbeSizeWinsAndIsWhatTheRecordKeeps() {
        let settings = AppSettings(downloadDirectory: "/tmp/ask-default")
        let result = ProbeResult(fileName: "a.bin", totalSize: 8192, acceptsRanges: true)
        let manager = DownloadManager(inMemory: [], settings: settings)
        let d = AddDraft(caught: URL(string: "https://example.com/a.bin")!, settings: settings, probe: .done(result), browserSize: 4096)
        #expect(d.size == 8192)
        d.commit(to: manager, later: true)
        #expect(manager.items[0].totalSize == 8192)
        let unknown = ProbeResult(fileName: "a.bin", totalSize: nil, acceptsRanges: false)
        let e = AddDraft(caught: URL(string: "https://example.com/a.bin")!, settings: settings, probe: .done(unknown), browserSize: 4096)
        #expect(e.size == 4096)
    }

    @Test func cookiesDoNotFollowAnEditToAnotherSchemeOrPort() throws {
        let d = draft("https://example.com/a.bin", headers: RequestHeaders(cookies: "session=abc"))
        #expect(d.headers(for: try #require(URL(string: "https://EXAMPLE.com/b.bin"))).cookies == "session=abc")
        #expect(d.headers(for: try #require(URL(string: "http://example.com/a.bin"))).cookies == nil)
        #expect(d.headers(for: try #require(URL(string: "https://example.com:8443/a.bin"))).cookies == nil)
    }

    @Test func aManualDraftSendsNoBrowserHeaders() throws {
        let d = AddDraft(text: "https://example.com/a.bin", fromClipboard: false, settings: AppSettings(), probe: .idle)
        #expect(d.headers(for: try #require(URL(string: "https://example.com/a.bin"))) == RequestHeaders())
        #expect(d.isFromBrowser == false)
    }

    @Test func aWaitingDraftTakesTheSettingsOfTheMomentItIsShown() {
        let d = AddDraft(text: "not a link yet", fromClipboard: false, settings: AppSettings(downloadDirectory: "/tmp/ask-default"))
        var changed = AppSettings(downloadDirectory: "/tmp/ask-changed")
        changed.connections = 4
        d.begin(settings: changed)
        #expect(d.directory == "/tmp/ask-changed")
        #expect(d.connections == 4)
        // Once shown the sheet is the user's: a later appearance changes nothing.
        d.directory = "/tmp/ask-chosen"
        d.begin(settings: AppSettings(downloadDirectory: "/tmp/ask-other"))
        #expect(d.directory == "/tmp/ask-chosen")
    }
}

@MainActor @Suite struct AskQueueTests {
    @Test func firstShowsAtOnceAndLaterOnesWaitInOrder() {
        let ui = ListState(persists: false)
        let a = draft("https://example.com/a"), b = draft("https://example.com/b"), c = draft("https://example.com/c")
        ui.present(a)
        ui.present(b)
        ui.present(c)
        #expect(ui.addDraft === a)
        #expect(ui.waitingDrafts.map(\.text) == ["https://example.com/b", "https://example.com/c"])
    }

    @Test func closingOpensTheNextOneInOrder() async throws {
        let ui = ListState(persists: false)
        let a = draft("https://example.com/a"), b = draft("https://example.com/b"), c = draft("https://example.com/c")
        ui.present(a)
        ui.present(b)
        ui.present(c)
        ui.addDraft = nil
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(ui.addDraft === b)
        #expect(ui.waitingDrafts.map(\.text) == ["https://example.com/c"])
        ui.addDraft = nil
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(ui.addDraft === c)
        #expect(ui.waitingDrafts.isEmpty)
        ui.addDraft = nil
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(ui.addDraft == nil)
    }

    @Test func linksAddedByHandWaitBehindAnOpenSheet() {
        let ui = ListState(persists: false)
        let a = draft("https://example.com/a")
        ui.present(a)
        ui.openAdd(text: "https://example.com/manual", settings: AppSettings())
        #expect(ui.addDraft === a)
        #expect(ui.waitingDrafts.map(\.text) == ["https://example.com/manual"])
    }

    @Test func cmdNDoesNothingWhileASheetIsOpen() {
        let ui = ListState(persists: false)
        let a = draft("https://example.com/a")
        ui.present(a)
        ui.openAdd(settings: AppSettings())
        #expect(ui.addDraft === a)
        #expect(ui.waitingDrafts.isEmpty)
    }

    @Test func aDraftArrivingWhileASheetLeavesWaitsForIt() async throws {
        let ui = ListState(persists: false)
        let a = draft("https://example.com/a"), b = draft("https://example.com/b")
        ui.present(a)
        ui.addDraft = nil
        ui.present(b)
        #expect(ui.addDraft == nil)
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(ui.addDraft === b)
        #expect(ui.waitingDrafts.isEmpty)
    }

    @Test func aManualAddDuringTheGapDoesNotJumpTheQueue() async throws {
        let ui = ListState(persists: false)
        let a = draft("https://example.com/a"), b = draft("https://example.com/b")
        ui.present(a)
        ui.present(b)
        ui.addDraft = nil
        ui.openAdd(text: "https://example.com/manual", settings: AppSettings())
        #expect(ui.addDraft == nil)
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(ui.addDraft === b)
        #expect(ui.waitingDrafts.map(\.text) == ["https://example.com/manual"])
    }

    @Test func everyArrivalAsksForAttention() {
        let ui = ListState(persists: false)
        var count = 0
        let sub = ui.needsAttention.sink { count += 1 }
        ui.present(draft("https://example.com/a"))
        ui.present(draft("https://example.com/b"))
        #expect(count == 2)
        sub.cancel()
    }

    @Test func draftsWaitingInTheQueueDoNotProbe() {
        let ui = ListState(persists: false)
        let a = draft("https://example.com/a"), b = AddDraft(caught: URL(string: "https://example.com/b")!, settings: AppSettings())
        ui.present(a)
        ui.present(b)
        #expect(b.probeStarted == false)
    }

    @Test func quittingKeepsBrowserDraftsAsPausedRows() {
        let manager = DownloadManager(inMemory: [], settings: AppSettings(downloadDirectory: "/tmp/ask-default"))
        let ui = ListState(persists: false)
        ui.present(draft("https://example.com/open.bin", headers: RequestHeaders(cookies: "a=b"), name: "open.bin"))
        ui.present(draft("https://example.com/waiting.bin"))
        ui.parkBrowserDrafts(in: manager)
        #expect(Set(manager.items.map(\.url.lastPathComponent)) == ["open.bin", "waiting.bin"])
        #expect(manager.items.allSatisfy { $0.status == .paused })
        #expect(manager.items.first { $0.fileName == "open.bin" }?.headers.cookies == "a=b")
    }

    @Test func quittingLeavesAManualDraftAlone() {
        let manager = DownloadManager(inMemory: [], settings: AppSettings())
        let ui = ListState(persists: false)
        ui.present(AddDraft(text: "https://example.com/typed.bin", fromClipboard: false, settings: AppSettings(), probe: .idle))
        ui.parkBrowserDrafts(in: manager)
        #expect(manager.items.isEmpty)
    }
}

@MainActor @Suite struct AskRoutingTests {
    private func model(ask: Bool) -> AppModel {
        AppModel(preview: DownloadManager(inMemory: [], settings: AppSettings(downloadDirectory: "/tmp/ask-default", askWhereToSave: ask)),
                 ui: ListState(persists: false))
    }
    private func request(ask: Bool?) -> AddRequest {
        AddRequest(url: "https://example.com/f.bin", filename: "f.bin", referrer: nil, cookies: "a=b", userAgent: nil, fileSize: 10, ask: ask)
    }
    private func json(_ r: HTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:]
    }

    @Test func settingOffAddsAtOnce() {
        let m = model(ask: false)
        let reply = json(m.run(.add(request(ask: true))))
        #expect(reply["ok"] as? Bool == true)
        #expect(reply["id"] as? String != nil)
        #expect(m.manager.items.count == 1)
        #expect(m.ui.addDraft == nil)
    }

    @Test func settingOnAsksAndAddsNothingYet() {
        let m = model(ask: true)
        let reply = json(m.run(.add(request(ask: true))))
        #expect(reply["ok"] as? Bool == true)
        #expect(reply["id"] == nil)
        #expect(m.manager.items.isEmpty)
        #expect(m.ui.addDraft?.text == "https://example.com/f.bin")
        #expect(m.ui.addDraft?.fileName == "f.bin")
        #expect(m.ui.addDraft?.browserSize == 10)
        #expect(m.ui.addDraft?.headers.cookies == "a=b")
    }

    @Test func scriptsWithoutTheSignalAreNeverAsked() {
        let m = model(ask: true)
        _ = m.run(.add(request(ask: nil)))
        #expect(m.manager.items.count == 1)
        #expect(m.ui.addDraft == nil)
    }
}

@Suite struct SubmitKeyTests {
    @Test func returnAndEnterKeyDownCommit() {
        #expect(SubmitKey.isReturn(type: .keyDown, keyCode: 36) == true)
        #expect(SubmitKey.isReturn(type: .keyDown, keyCode: 76) == true)
    }

    @Test func everythingElseDoesNot() {
        #expect(SubmitKey.isReturn(type: nil, keyCode: nil) == false)
        #expect(SubmitKey.isReturn(type: .leftMouseUp, keyCode: nil) == false)
        #expect(SubmitKey.isReturn(type: .keyDown, keyCode: 0) == false)
        #expect(SubmitKey.isReturn(type: .keyUp, keyCode: 36) == false)
    }
}

@MainActor
@Suite struct CommitOnceTests {
    @Test func secondCommitOfTheSameDraftAddsNothing() {
        let manager = DownloadManager(inMemory: [], settings: AppSettings(downloadDirectory: "/tmp/ask-default"))
        let d = draft("https://example.com/once.bin")
        #expect(d.commit(to: manager, later: false) == 1)
        #expect(d.commit(to: manager, later: false) == 0)
        #expect(d.commit(to: manager, later: true) == 0)
        #expect(manager.items.count == 1)
    }
}
