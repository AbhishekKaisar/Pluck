import Foundation

public enum DownloadStatus: String, Codable, Sendable {
    case queued, probing, downloading, paused, completed, failed, cancelled

    public var isActive: Bool { self == .probing || self == .downloading }
    public var isFinished: Bool { self == .completed || self == .cancelled }
}

/// Headers the browser extension hands over so logged-in downloads work.
public struct RequestHeaders: Codable, Equatable, Sendable {
    public var cookies: String?
    public var referrer: String?
    public var userAgent: String?

    public init(cookies: String? = nil, referrer: String? = nil, userAgent: String? = nil) {
        self.cookies = cookies
        self.referrer = referrer
        self.userAgent = userAgent
    }

    public static let defaultUserAgent = "Pluck/\(AppInfo.version)"

    public func apply(to request: inout URLRequest) {
        request.setValue(userAgent?.nilIfBlank ?? Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        if let r = referrer?.nilIfBlank { request.setValue(r, forHTTPHeaderField: "Referer") }
        if let c = cookies?.nilIfBlank {
            request.httpShouldHandleCookies = false
            request.setValue(c, forHTTPHeaderField: "Cookie")
        }
        // Ask for the raw bytes; compressed transfer would break byte offsets.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    }
}

public struct DownloadRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var url: URL
    public var fileName: String
    public var directory: String
    public var totalSize: Int64?
    public var acceptsRanges: Bool
    public var probed: Bool
    public var status: DownloadStatus
    public var segments: [Segment]
    public var headers: RequestHeaders
    public var errorMessage: String?
    public var createdAt: Date
    public var completedAt: Date?
    /// Name came from the user or the browser; do not replace it with the server's.
    public var nameIsFixed: Bool
    /// Connections chosen for this download in the Add sheet; nil uses the setting.
    public var connections: Int?

    public init(url: URL, fileName: String?, directory: String, headers: RequestHeaders, expectedSize: Int64? = nil) {
        self.id = UUID()
        self.url = url
        self.fileName = fileName.map(FileNaming.sanitise)?.nilIfBlank ?? FileNaming.filename(fromURL: url) ?? "download"
        self.nameIsFixed = fileName?.nilIfBlank != nil
        self.directory = directory
        self.totalSize = (expectedSize ?? 0) > 0 ? expectedSize : nil
        self.acceptsRanges = false
        self.probed = false
        self.status = .queued
        self.segments = []
        self.headers = headers
        self.createdAt = Date()
    }

    public var downloadedBytes: Int64 {
        if status == .completed { return totalSize ?? SegmentMath.downloaded(segments) }
        return SegmentMath.downloaded(segments)
    }

    public var progress: Double? {
        guard let t = totalSize, t > 0 else { return nil }
        return min(1, Double(downloadedBytes) / Double(t))
    }

    public var finalPath: String { (directory as NSString).appendingPathComponent(fileName) }
    public var partPath: String { finalPath + ".part" }
    public var statePath: String { finalPath + ".part.json" }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var downloadDirectory: String
    public var connections: Int
    public var maxConcurrent: Int
    /// The limit in force, in KiB per second; 0 means no limit.
    public var speedLimitKiB: Int
    /// The limit the speed-limit toggle applies, remembered while the limit is off.
    public var speedLimitValueKiB: Int
    /// Show the Add sheet for each browser download, so the folder can be changed before it starts.
    public var askWhereToSave: Bool

    public init(downloadDirectory: String = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads"),
                connections: Int = 16, maxConcurrent: Int = 3, speedLimitKiB: Int = 0, speedLimitValueKiB: Int? = nil,
                askWhereToSave: Bool = false) {
        self.downloadDirectory = downloadDirectory
        self.connections = connections
        self.maxConcurrent = maxConcurrent
        self.speedLimitKiB = speedLimitKiB
        self.speedLimitValueKiB = speedLimitValueKiB ?? (speedLimitKiB > 0 ? speedLimitKiB : 1024)
        self.askWhereToSave = askWhereToSave
    }

    private enum CodingKeys: String, CodingKey {
        case downloadDirectory, connections, maxConcurrent, speedLimitKiB, speedLimitValueKiB, askWhereToSave
    }

    /// Settings files written before the speed-limit toggle have no `speedLimitValueKiB`, and files before the ask-where-to-save option have no `askWhereToSave`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        self.init(downloadDirectory: try c.decodeIfPresent(String.self, forKey: .downloadDirectory) ?? d.downloadDirectory,
                  connections: try c.decodeIfPresent(Int.self, forKey: .connections) ?? d.connections,
                  maxConcurrent: try c.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? d.maxConcurrent,
                  speedLimitKiB: try c.decodeIfPresent(Int.self, forKey: .speedLimitKiB) ?? 0,
                  speedLimitValueKiB: try c.decodeIfPresent(Int.self, forKey: .speedLimitValueKiB),
                  askWhereToSave: try c.decodeIfPresent(Bool.self, forKey: .askWhereToSave) ?? false)
    }

    public var speedLimitOn: Bool { speedLimitKiB > 0 }

    /// Turns the limit on at `speedLimitValueKiB`, or off.
    public mutating func setSpeedLimit(on: Bool) {
        speedLimitKiB = on ? max(1, speedLimitValueKiB) : 0
    }

    public var clamped: AppSettings {
        var s = self
        s.connections = min(SegmentMath.maxConnections, max(1, connections))
        s.maxConcurrent = min(10, max(1, maxConcurrent))
        s.speedLimitKiB = max(0, speedLimitKiB)
        s.speedLimitValueKiB = max(1, speedLimitValueKiB)
        return s
    }
}

public enum AppInfo {
    public static let version = "1.0.0"
    public static let bundleID = "io.github.abhishekkaisar.pluck"
}

extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : self
    }
}
