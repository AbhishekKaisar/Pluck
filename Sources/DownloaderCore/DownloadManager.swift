import Foundation
import Combine
import Security

/// Owns the download list, the queue, settings and persistence. Main thread only.
@MainActor
public final class DownloadManager: ObservableObject {
    @Published public private(set) var items: [DownloadRecord] = []
    @Published public private(set) var speeds: [UUID: Double] = [:]
    @Published public private(set) var totalSpeed: Double = 0
    /// Connections open right now, per running download.
    @Published public private(set) var activeConnections: [UUID: Int] = [:]
    /// Completed downloads whose file is no longer on disk. Derived, never saved.
    @Published public private(set) var missing: Set<UUID> = []
    @Published public var settings: AppSettings {
        didSet {
            let c = settings.clamped
            if c != settings { settings = c; return }
            guard persists else { return }
            SpeedLimiter.shared.bytesPerSecond = Int64(settings.speedLimitKiB) * 1024
            Persistence.save(settings, to: Persistence.settingsURL)
            schedule()
        }
    }

    /// False for the in-memory manager used by snapshots and tests: no disk, no network.
    public let persists: Bool

    private var engines: [UUID: DownloadEngine] = [:]
    private var meters: [UUID: SpeedMeter] = [:]
    private var timer: Timer?
    private var lastListSave = Date.distantPast
    private var listDirty = false

    public init() {
        persists = true
        settings = Persistence.load(AppSettings.self, from: Persistence.settingsURL)?.clamped ?? AppSettings()
        SpeedLimiter.shared.bytesPerSecond = Int64(settings.speedLimitKiB) * 1024
        var loaded = Persistence.load([DownloadRecord].self, from: Persistence.downloadsURL) ?? []
        for i in loaded.indices where loaded[i].status.isActive {
            // The app quit mid-transfer: carry on where it stopped.
            loaded[i].status = .queued
        }
        items = loaded
        refreshMissing()
        schedule()
    }

    /// A list that lives only in memory and never starts a transfer. For snapshots and tests.
    public init(inMemory items: [DownloadRecord], settings: AppSettings = AppSettings(),
                speeds: [UUID: Double] = [:], connections: [UUID: Int] = [:], missing: Set<UUID>? = nil) {
        persists = false
        self.settings = settings
        self.items = items
        let ids = Set(items.map(\.id))
        self.speeds = speeds.filter { ids.contains($0.key) }
        self.totalSpeed = self.speeds.values.reduce(0, +)
        self.activeConnections = connections.filter { ids.contains($0.key) }
        if let missing { self.missing = missing } else { refreshMissing() }
    }

    // MARK: Commands

    @discardableResult
    public func add(url: URL, fileName: String? = nil, headers: RequestHeaders = RequestHeaders(), expectedSize: Int64? = nil,
                    directory: String? = nil, connections: Int? = nil, startPaused: Bool = false) -> UUID {
        var record = DownloadRecord(url: url, fileName: fileName, directory: directory ?? settings.downloadDirectory,
                                    headers: headers, expectedSize: expectedSize)
        record.connections = connections.map { min(SegmentMath.maxConnections, max(1, $0)) }
        if startPaused { record.status = .paused }
        items.insert(record, at: 0)
        markDirty(force: true)
        schedule()
        return record.id
    }

    public func pause(_ id: UUID) {
        if let e = engines.removeValue(forKey: id) {
            e.pause()
            update(e.snapshot())
        } else {
            mutate(id) { if $0.status == .queued || $0.status == .failed { $0.status = .paused } }
        }
        meters[id] = nil
        if speeds[id] != nil { speeds[id] = nil }
        markDirty(force: true)
        schedule()
    }

    public func resume(_ id: UUID) {
        mutate(id) {
            if $0.status == .paused || $0.status == .failed {
                $0.status = .queued
                $0.errorMessage = nil
            }
        }
        markDirty(force: true)
        schedule()
    }

    public func cancel(_ id: UUID) {
        if let e = engines.removeValue(forKey: id) {
            e.cancel()
            update(e.snapshot())
        } else if let r = items.first(where: { $0.id == id }), r.status != .completed {
            try? FileManager.default.removeItem(atPath: r.partPath)
            try? FileManager.default.removeItem(atPath: r.statePath)
            mutate(id) { $0.status = .cancelled }
        }
        meters[id] = nil
        if speeds[id] != nil { speeds[id] = nil }
        markDirty(force: true)
        schedule()
    }

    /// Removes from the list. Unfinished files are deleted.
    public func remove(_ id: UUID) {
        if let r = items.first(where: { $0.id == id }), r.status != .completed { cancel(id) }
        items.removeAll { $0.id == id }
        if missing.contains(id) { missing.remove(id) }
        markDirty(force: true)
    }

    /// Removes from the list and deletes the file: a finished file goes to the Trash, partial data is deleted.
    public func deleteFiles(_ id: UUID) {
        guard let r = item(id) else { return }
        if r.status == .completed {
            if FileManager.default.fileExists(atPath: r.finalPath) {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: r.finalPath), resultingItemURL: nil)
            }
            items.removeAll { $0.id == id }
            missing.remove(id)
            markDirty(force: true)
        } else {
            remove(id)
        }
    }

    /// Starts the same link again as a new download and drops the old row.
    @discardableResult
    public func downloadAgain(_ id: UUID) -> UUID? {
        guard let r = item(id) else { return nil }
        let new = add(url: r.url, fileName: r.nameIsFixed ? r.fileName : nil, headers: r.headers, directory: r.directory,
                      connections: r.connections)
        if r.status == .completed || r.status == .cancelled {
            items.removeAll { $0.id == id }
            missing.remove(id)
        } else {
            remove(id)
        }
        markDirty(force: true)
        return new
    }

    /// Re-checks which completed files are gone from disk. Call on launch and when the window comes to the front.
    public func refreshMissing() {
        let gone = Self.missingIDs(in: items) { FileManager.default.fileExists(atPath: $0) }
        if gone != missing { missing = gone }
    }

    nonisolated public static func missingIDs(in items: [DownloadRecord], exists: (String) -> Bool) -> Set<UUID> {
        Set(items.filter { $0.status == .completed && !exists($0.finalPath) }.map(\.id))
    }

    public func setSpeedLimit(on: Bool) { settings.setSpeedLimit(on: on) }

    public func clearFinished() {
        items.removeAll { $0.status == .completed || $0.status == .cancelled }
        markDirty(force: true)
    }

    public func pauseAll() { for id in engines.keys { pause(id) } }

    /// Call from applicationWillTerminate: writes every state file and the list.
    public func prepareForQuit() {
        for (id, e) in engines {
            e.pause()
            var r = e.snapshot()
            // Resume automatically next launch.
            if r.status == .paused { r.status = .queued }
            update(r)
            engines[id] = nil
        }
        Persistence.save(items, to: Persistence.downloadsURL)
    }

    public func item(_ id: UUID) -> DownloadRecord? { items.first { $0.id == id } }

    public func eta(for r: DownloadRecord) -> TimeInterval? {
        guard let total = r.totalSize, let s = speeds[r.id], s > 1 else { return nil }
        return Double(max(0, total - r.downloadedBytes)) / s
    }

    // MARK: Scheduling

    private func schedule() {
        guard persists else { return }
        let running = engines.count
        var slots = settings.maxConcurrent - running
        guard slots > 0 else { return }
        // Oldest first.
        for r in items.reversed() where slots > 0 && r.status == .queued && engines[r.id] == nil {
            let e = DownloadEngine(record: r, connections: r.connections ?? settings.connections)
            engines[r.id] = e
            meters[r.id] = SpeedMeter()
            e.start()
            slots -= 1
        }
        startTicking()
    }

    /// The progress timer runs only while a transfer is running; an idle app does no periodic work.
    private func startTicking() {
        guard timer == nil, !engines.isEmpty else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .default)
        timer = t
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    /// Publishes only values that changed, so an unchanged tick redraws nothing.
    private func tick() {
        var total: Double = 0
        var finished: [UUID] = []
        var conns: [UUID: Int] = [:]
        var newSpeeds: [UUID: Double] = [:]
        for (id, e) in engines {
            conns[id] = e.activeConnections
            let r = e.snapshot()
            update(r)
            meters[id, default: SpeedMeter()].add(bytes: r.downloadedBytes)
            if !r.status.isActive && r.status != .queued {
                finished.append(id)
                continue
            }
            let s = meters[id]?.speed ?? 0
            newSpeeds[id] = s
            total += s
        }
        for id in finished {
            engines[id] = nil
            meters[id] = nil
            conns[id] = nil
            markDirty(force: true)
        }
        if newSpeeds != speeds { speeds = newSpeeds }
        if total != totalSpeed { totalSpeed = total }
        if conns != activeConnections { activeConnections = conns }
        if !finished.isEmpty { refreshMissing() }
        if !engines.isEmpty { listDirty = true }
        if !finished.isEmpty { schedule() }
        if listDirty && Date().timeIntervalSince(lastListSave) > 3 { saveList() }
        if engines.isEmpty { stopTicking() }
    }

    private func update(_ r: DownloadRecord) {
        guard let i = items.firstIndex(where: { $0.id == r.id }), items[i] != r else { return }
        items[i] = r
    }

    private func mutate(_ id: UUID, _ f: (inout DownloadRecord) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        f(&items[i])
    }

    private func markDirty(force: Bool) {
        listDirty = true
        if force { saveList() }
    }

    private func saveList() {
        guard persists else { listDirty = false; return }
        Persistence.save(items, to: Persistence.downloadsURL)
        lastListSave = Date()
        listDirty = false
    }
}

public enum Persistence {
    /// `PLUCK_SUPPORT_DIR` (or the older `MACDOWNLOADER_SUPPORT_DIR`) points a test run at its own
    /// list, settings and token.
    public static var customSupportDirectory: String? {
        let env = ProcessInfo.processInfo.environment
        return [env["PLUCK_SUPPORT_DIR"], env["MACDOWNLOADER_SUPPORT_DIR"]].compactMap({ $0 }).first(where: { !$0.isEmpty })
    }

    /// `customSupportDirectory`, or else `~/Library/Application Support/Pluck`.
    public static var supportDirectory: URL {
        let dir: URL
        if let custom = customSupportDirectory {
            dir = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dir = base.appendingPathComponent(folderName, isDirectory: true)
            migrateLegacyFolder(in: base)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static let folderName = "Pluck"
    /// The folder name the app used before it was called Pluck.
    public static let legacyFolderName = "MacDownloader"

    public enum Migration: Equatable, Sendable {
        case copied, alreadyMigrated, nothingToMigrate, failed
    }

    /// Copies `<base>/MacDownloader` to `<base>/Pluck` once, so settings, token and list carry over
    /// the rename. The old folder is left in place. Copies into a temporary name first and renames
    /// it, so a crash halfway never leaves a half-filled Pluck folder that would block a retry.
    @discardableResult
    public static func migrateLegacyFolder(in base: URL, fileManager fm: FileManager = .default) -> Migration {
        let target = base.appendingPathComponent(folderName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyFolderName, isDirectory: true)
        if fm.fileExists(atPath: target.path) { return .alreadyMigrated }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: legacy.path, isDirectory: &isDir), isDir.boolValue else { return .nothingToMigrate }
        let staging = base.appendingPathComponent(".\(folderName)-migrating-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.copyItem(at: legacy, to: staging)
            try fm.moveItem(at: staging, to: target)
            return .copied
        } catch {
            try? fm.removeItem(at: staging)
            return fm.fileExists(atPath: target.path) ? .alreadyMigrated : .failed
        }
    }

    public static var downloadsURL: URL { supportDirectory.appendingPathComponent("downloads.json") }
    public static var settingsURL: URL { supportDirectory.appendingPathComponent("settings.json") }
    public static var serverStateURL: URL { supportDirectory.appendingPathComponent("server.json") }
    public static var tokenURL: URL { supportDirectory.appendingPathComponent("token") }

    public static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder.iso.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso.decode(type, from: data)
    }

    /// The API token, created on first launch with owner-only permissions.
    public static func token() -> String {
        if let s = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), s.count >= 32 {
            return s
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        let ok = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        if !ok { for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) } }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        FileManager.default.createFile(atPath: tokenURL.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        return token
    }
}
