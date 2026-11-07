import Foundation
import Testing
@testable import DownloaderCore

@Suite struct BrowserHostTests {
    func scratch() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func makeHost(in base: URL, folder: String = "Pluck.app") throws -> String {
        let dir = base.appendingPathComponent("\(folder)/Contents/MacOS")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let host = dir.appendingPathComponent("pluck-host")
        try Data("#!/bin/sh\n".utf8).write(to: host)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path)
        return host.path
    }

    func manifestFile(_ home: URL, _ browser: String) -> URL {
        home.appendingPathComponent("Library/Application Support/\(browser)/NativeMessagingHosts/io.github.abhishekkaisar.pluck.json")
    }

    func install(_ home: URL, _ browser: String) throws {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Application Support/\(browser)"), withIntermediateDirectories: true)
    }

    @Test func writesForInstalledBrowserOnly() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let host = try makeHost(in: home)
        try install(home, "Google/Chrome")
        try install(home, "Microsoft Edge")

        let written = BrowserHost.register(hostPath: host, home: home)
        #expect(written.count == 2)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: manifestFile(home, "Google/Chrome").path))
        #expect(fm.fileExists(atPath: manifestFile(home, "Microsoft Edge").path))
        #expect(!fm.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Vivaldi").path), "absent browser is not created")
        #expect(!fm.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Chromium").path))
    }

    @Test func manifestContent() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let host = try makeHost(in: home, folder: "My Apps/Pluck.app")
        try install(home, "Google/Chrome")
        BrowserHost.register(hostPath: host, home: home)

        let data = try Data(contentsOf: manifestFile(home, "Google/Chrome"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["name"] as? String == "io.github.abhishekkaisar.pluck")
        #expect(json["type"] as? String == "stdio")
        #expect(json["path"] as? String == host)
        #expect((json["path"] as? String)?.contains("My Apps/Pluck.app/Contents/MacOS/pluck-host") == true)
        #expect(json["allowed_origins"] as? [String] == ["chrome-extension://oolmpkdpgffpejjjgbakkkcojbglleag/"])
    }

    @Test func idempotentAndRewritesWhenMoved() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = try makeHost(in: home, folder: "A/Pluck.app")
        let second = try makeHost(in: home, folder: "B/Pluck.app")
        try install(home, "BraveSoftware/Brave-Browser")

        #expect(BrowserHost.register(hostPath: first, home: home).count == 1)
        #expect(BrowserHost.register(hostPath: first, home: home).isEmpty, "unchanged: nothing rewritten")
        #expect(BrowserHost.register(hostPath: second, home: home).count == 1)
        let data = try Data(contentsOf: manifestFile(home, "BraveSoftware/Brave-Browser"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["path"] as? String == second)
    }

    @Test func skipsWhenHostIsMissing() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try install(home, "Google/Chrome")
        #expect(BrowserHost.register(hostPath: home.appendingPathComponent("nope/pluck-host").path, home: home).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: manifestFile(home, "Google/Chrome").path))
    }
}
