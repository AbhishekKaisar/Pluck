import Foundation
import Testing
@testable import DownloaderCore

/// The support folder moved from MacDownloader to Pluck with the rename.
@Suite struct MigrationTests {
    func scratch() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test func copiesOldFolderOnce() throws {
        let fm = FileManager.default
        let base = try scratch()
        defer { try? fm.removeItem(at: base) }
        let old = base.appendingPathComponent("MacDownloader")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data(#"{"connections":32}"#.utf8).write(to: old.appendingPathComponent("settings.json"))
        fm.createFile(atPath: old.appendingPathComponent("token").path, contents: Data("abc".utf8),
                      attributes: [.posixPermissions: 0o600])

        #expect(Persistence.migrateLegacyFolder(in: base) == .copied)
        let new = base.appendingPathComponent("Pluck")
        #expect(try String(contentsOf: new.appendingPathComponent("settings.json"), encoding: .utf8) == #"{"connections":32}"#)
        let perms = try fm.attributesOfItem(atPath: new.appendingPathComponent("token").path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        #expect(fm.fileExists(atPath: old.path), "the old folder stays")
        // No staging folder left behind.
        #expect(try fm.contentsOfDirectory(atPath: base.path).sorted() == ["MacDownloader", "Pluck"])

        // A second launch leaves the new folder alone, even after the old one changed.
        try Data("{}".utf8).write(to: old.appendingPathComponent("settings.json"))
        #expect(Persistence.migrateLegacyFolder(in: base) == .alreadyMigrated)
        #expect(try String(contentsOf: new.appendingPathComponent("settings.json"), encoding: .utf8) == #"{"connections":32}"#)
    }

    @Test func freshInstallHasNothingToMigrate() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(Persistence.migrateLegacyFolder(in: base) == .nothingToMigrate)
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Pluck").path))
    }

    @Test func existingPluckFolderWins() throws {
        let fm = FileManager.default
        let base = try scratch()
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base.appendingPathComponent("MacDownloader"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("Pluck"), withIntermediateDirectories: true)
        #expect(Persistence.migrateLegacyFolder(in: base) == .alreadyMigrated)
        #expect(try fm.contentsOfDirectory(atPath: base.appendingPathComponent("Pluck").path).isEmpty)
    }
}
