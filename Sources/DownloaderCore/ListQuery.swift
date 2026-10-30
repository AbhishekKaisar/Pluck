import Foundation

/// Broad file kinds for the list filter, decided by extension.
public enum FileCategory: String, CaseIterable, Codable, Sendable {
    case video, audio, documents, images, archives, programs, other

    public var title: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        case .documents: return "Documents"
        case .images: return "Images"
        case .archives: return "Archives"
        case .programs: return "Apps and installers"
        case .other: return "Other"
        }
    }

    private static let table: [FileCategory: Set<String>] = [
        .video: ["mp4", "m4v", "mkv", "mov", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "ts", "3gp"],
        .audio: ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "aiff", "wma", "alac"],
        .documents: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "csv", "epub", "pages", "numbers", "key", "odt", "md"],
        .images: ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "tif", "bmp", "svg", "raw"],
        .archives: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "iso"],
        .programs: ["dmg", "pkg", "app", "exe", "msi", "deb", "rpm", "apk", "appimage", "ipa"],
    ]

    public static func of(fileName: String) -> FileCategory {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        for (category, exts) in table where exts.contains(ext) { return category }
        return .other
    }
}

/// The filter dropdown: status groups, then file categories.
public enum ListFilter: Hashable, Sendable, RawRepresentable {
    case all, active, completed, missing
    case category(FileCategory)

    public init?(rawValue: String) {
        switch rawValue {
        case "all": self = .all
        case "active": self = .active
        case "completed": self = .completed
        case "missing": self = .missing
        default:
            guard rawValue.hasPrefix("category."),
                  let c = FileCategory(rawValue: String(rawValue.dropFirst("category.".count))) else { return nil }
            self = .category(c)
        }
    }

    public var rawValue: String {
        switch self {
        case .all: return "all"
        case .active: return "active"
        case .completed: return "completed"
        case .missing: return "missing"
        case .category(let c): return "category." + c.rawValue
        }
    }

    public var title: String {
        switch self {
        case .all: return "All files"
        case .active: return "Active"
        case .completed: return "Completed"
        case .missing: return "Missing files"
        case .category(let c): return c.title
        }
    }

    public static var statusFilters: [ListFilter] { [.all, .active, .completed, .missing] }
    public static var categoryFilters: [ListFilter] { FileCategory.allCases.map { .category($0) } }
}

public enum ListSort: String, CaseIterable, Sendable {
    case newest, oldest, nameAscending, nameDescending, sizeLargest, sizeSmallest, status

    public var title: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .nameAscending: return "Name A to Z"
        case .nameDescending: return "Name Z to A"
        case .sizeLargest: return "Largest first"
        case .sizeSmallest: return "Smallest first"
        case .status: return "Status"
        }
    }
}

/// The select-all dropdown: which rows a quick selection picks.
public enum QuickSelection: String, CaseIterable, Sendable {
    case all, downloading, completed, paused

    public var title: String {
        switch self {
        case .all: return "All"
        case .downloading: return "Downloading"
        case .completed: return "Completed"
        case .paused: return "Paused"
        }
    }

    public func matches(_ r: DownloadRecord, missing: Set<UUID>) -> Bool {
        switch self {
        case .all: return true
        case .downloading: return r.status.isActive || r.status == .queued
        case .completed: return r.status == .completed && !missing.contains(r.id)
        case .paused: return r.status == .paused
        }
    }
}

/// Sort, filter and search applied together. Pure, so it is tested without the UI.
public enum ListQuery {
    public static func apply(_ items: [DownloadRecord], sort: ListSort, filter: ListFilter, search: String,
                             missing: Set<UUID> = []) -> [DownloadRecord] {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let kept = items.filter { r in
            matches(r, filter: filter, missing: missing) && words.allSatisfy { w in
                r.fileName.lowercased().contains(w) || r.url.absoluteString.lowercased().contains(w)
            }
        }
        return kept.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            switch sort {
            case .newest:
                if x.createdAt != y.createdAt { return x.createdAt > y.createdAt }
            case .oldest:
                if x.createdAt != y.createdAt { return x.createdAt < y.createdAt }
            case .nameAscending, .nameDescending:
                let c = x.fileName.localizedStandardCompare(y.fileName)
                if c != .orderedSame { return sort == .nameAscending ? c == .orderedAscending : c == .orderedDescending }
            case .sizeLargest, .sizeSmallest:
                // Unknown sizes go last either way.
                let sx = x.totalSize ?? -1, sy = y.totalSize ?? -1
                if sx != sy {
                    if sx < 0 || sy < 0 { return sy < 0 }
                    return sort == .sizeLargest ? sx > sy : sx < sy
                }
            case .status:
                let rx = statusRank(x, missing), ry = statusRank(y, missing)
                if rx != ry { return rx < ry }
                if x.createdAt != y.createdAt { return x.createdAt > y.createdAt }
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    public static func matches(_ r: DownloadRecord, filter: ListFilter, missing: Set<UUID>) -> Bool {
        switch filter {
        case .all: return true
        case .active: return r.status.isActive || r.status == .queued || r.status == .paused
        case .completed: return r.status == .completed && !missing.contains(r.id)
        case .missing: return missing.contains(r.id)
        case .category(let c): return FileCategory.of(fileName: r.fileName) == c
        }
    }

    /// Working first, then waiting, then problems, then done.
    static func statusRank(_ r: DownloadRecord, _ missing: Set<UUID>) -> Int {
        if missing.contains(r.id) { return 5 }
        switch r.status {
        case .downloading: return 0
        case .probing: return 1
        case .queued: return 2
        case .paused: return 3
        case .failed: return 4
        case .completed: return 6
        case .cancelled: return 7
        }
    }
}

/// Finds http and https links in pasted or dropped text, one per line or mixed with other words.
public enum LinkParser {
    public static func links(in text: String) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'<>`"))
        for raw in text.components(separatedBy: separators) {
            var token = raw
            guard let start = token.range(of: "http", options: .caseInsensitive) else { continue }
            token = String(token[start.lowerBound...])
            while let last = token.last, ",.;:!?)]}".contains(last) { token.removeLast() }
            guard let url = URL(string: token), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { continue }
            if seen.insert(url.absoluteString).inserted { out.append(url) }
        }
        return out
    }
}
