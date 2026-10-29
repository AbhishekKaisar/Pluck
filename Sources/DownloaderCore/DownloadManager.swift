import Foundation
import Combine
import Security

/// Owns the download list, the queue, settings and persistence. Main thread only.
@MainActor
public final class DownloadManager: ObservableObject {
    @Published public private(set) var items: [DownloadRecord] = []
    @Published public private(set) var speeds: [UUID: Double] = [:]
    @Published public private(set) var totalSpeed: Double = 0
    @Published public var settings: AppSettings {
        didSet {
            let c = settings.clamped
            if c != settings { settings = c; return }
            SpeedLimiter.shared.bytesPerSecond = Int64(settings.speedLimitKiB) * 1024
            Persistence.save(settings, to: Persistence.settingsURL)
            schedule()
        }
    }

    private var engines: [UUID: DownloadEngine] = [:]
    private var meters: [UUID: SpeedMeter] = [:]
    private var timer: Timer?
    private var lastListSave = Date.distantPast
    private var listDirty = false

    public init() {
        settings = Persistence.load(AppSettings.self, from: Persistence.settingsURL)?.clamped ?? AppSettings()
        SpeedLimiter.shared.bytesPerSecond = Int64(settings.speedLimitKiB) * 1024
        var loaded = Persistence.load([DownloadRecord].self, from: Persistence.downloadsURL) ?? []
        for i in loaded.indices where loaded[i].status.isActive {
            // The app quit mid-transfer: carry on where it stopped.
            loaded[i].status = .queued
        }
        items = loaded
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        schedule()
    }

    // MARK: Commands

    @discardableResult
    public func add(url: URL, fileName: String? = nil, headers: RequestHeaders = RequestHeaders(), expectedSize: Int64? = nil, directory: String? = nil) -> UUID {
        let record = DownloadRecord(url: url, fileName: fileName, directory: directory ?? settings.downloadDirectory,
                                    headers: headers, expectedSize: expectedSize)
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
        speeds[id] = nil
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
        speeds[id] = nil
        markDirty(force: true)
        schedule()
    }

    /// Removes from the list. Unfinished files are deleted.
    public func remove(_ id: UUID) {
        if let r = items.first(where: { $0.id == id }), r.status != .completed { cancel(id) }
        items.removeAll { $0.id == id }
        markDirty(force: true)
    }

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
        let running = engines.count
        var slots = settings.maxConcurrent - running
        guard slots > 0 else { return }
        // Oldest first.
        for r in items.reversed() where slots > 0 && r.status == .queued && engines[r.id] == nil {
            let e = DownloadEngine(record: r, connections: settings.connections)
            engines[r.id] = e
            meters[r.id] = SpeedMeter()
            e.start()
            slots -= 1
        }
    }

    private func tick() {
        var total: Double = 0
        var finished: [UUID] = []
        for (id, e) in engines {
            let r = e.snapshot()
            update(r)
            meters[id, default: SpeedMeter()].add(bytes: r.downloadedBytes)
            let s = meters[id]?.speed ?? 0
            speeds[id] = s
            total += s
            if !r.status.isActive && r.status != .queued {
                finished.append(id)
            }
        }
        for id in finished {
            engines[id] = nil
            meters[id] = nil
            speeds[id] = nil
            markDirty(force: true)
        }
        totalSpeed = total
        if !engines.isEmpty { listDirty = true }
        if !finished.isEmpty { schedule() }
        if listDirty && Date().timeIntervalSince(lastListSave) > 3 { saveList() }
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
        Persistence.save(items, to: Persistence.downloadsURL)
        lastListSave = Date()
        listDirty = false
    }
}

public enum Persistence {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MacDownloader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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
