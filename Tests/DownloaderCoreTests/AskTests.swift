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
    AddDraft(text: url, fromClipboard: false, settings: settings, probe: .idle, headers: headers, fileName: name, browserSize: size)
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

    @Test func manualAddDoesNotReplaceAnOpenSheet() {
        let ui = ListState(persists: false)
        let a = draft("https://example.com/a")
        ui.present(a)
        ui.openAdd(text: "https://example.com/manual", settings: AppSettings())
        #expect(ui.addDraft === a)
        #expect(ui.waitingDrafts.isEmpty)
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
