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
        let dir = base.appendingPathComponent("\(folder)/Contents/Resources")
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
        try install(home, "Arc/User Data")

        let written = BrowserHost.register(hostPath: host, home: home)
        #expect(written.count == 3)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: manifestFile(home, "Google/Chrome").path))
        #expect(fm.fileExists(atPath: manifestFile(home, "Microsoft Edge").path))
        #expect(fm.fileExists(atPath: manifestFile(home, "Arc/User Data").path))
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
        #expect((json["path"] as? String)?.contains("My Apps/Pluck.app/Contents/Resources/pluck-host") == true)
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

    @Test func keepsRegistrationWhenRunFromATemporaryCopy() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let installed = try makeHost(in: home, folder: "Applications/Pluck.app")
        let translocated = try makeHost(in: home, folder: "AppTranslocation/1234/d/Pluck.app")
        try install(home, "Google/Chrome")

        BrowserHost.register(hostPath: installed, home: home)
        #expect(BrowserHost.register(hostPath: translocated, home: home).isEmpty)
        let data = try Data(contentsOf: manifestFile(home, "Google/Chrome"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["path"] as? String == installed)

        #expect(BrowserHost.isTemporary("/Volumes/Pluck 1.0.0/Pluck.app/Contents/Resources/pluck-host"))
        #expect(!BrowserHost.isTemporary("/Applications/Pluck.app/Contents/Resources/pluck-host"))
    }

    /// Runs Resources/pluck-host with `open` replaced by a stub, so no app is ever started.
    func runHost(openExitCode: Int) throws -> (status: Int32, output: Data) {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = dir.appendingPathComponent("open")
        try Data("#!/bin/sh\nexit \(openExitCode)\n".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = root.appendingPathComponent("Resources/pluck-host")
        process.environment = ["PATH": "\(dir.path):/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    @Test func hostAnswersWhenTheAppOpens() throws {
        let result = try runHost(openExitCode: 0)
        #expect(result.status == 0)
        #expect(result.output == Data([11, 0, 0, 0]) + Data(#"{"ok":true}"#.utf8))
    }

    @Test func hostFailsWhenTheAppCannotOpen() throws {
        let result = try runHost(openExitCode: 1)
        #expect(result.status != 0)
        #expect(result.output.isEmpty, "no reply, so sendNativeMessage rejects at once")
    }

    @Test func skipsWhenHostIsMissing() throws {
        let home = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try install(home, "Google/Chrome")
        #expect(BrowserHost.register(hostPath: home.appendingPathComponent("nope/pluck-host").path, home: home).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: manifestFile(home, "Google/Chrome").path))
    }
}
