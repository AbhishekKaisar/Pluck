import AppKit
import SwiftUI
import DownloaderCore

/// What the main window shows: sort, filter, search, selection, the open sheet and pending confirmations.
@MainActor
public final class ListState: ObservableObject {
    public enum Confirm: Identifiable, Equatable {
        case deleteFiles([UUID])
        case remove([UUID])

        public var id: String {
            switch self {
            case .deleteFiles(let ids): return "delete" + ids.map(\.uuidString).joined()
            case .remove(let ids): return "remove" + ids.map(\.uuidString).joined()
            }
        }
    }

    @Published public var sort: ListSort { didSet { save(sort.rawValue, "list.sort") } }
    @Published public var filter: ListFilter { didSet { save(filter.rawValue, "list.filter") } }
    @Published public var showDetails: Bool { didSet { save(showDetails, "list.showDetails") } }
    @Published public var search = ""
    @Published public var selection: Set<UUID> = []
    /// The Add sheet that is open. Set it to nil to close it; the next waiting draft opens after it.
    @Published public var addDraft: AddDraft? {
        didSet { if addDraft == nil { openNextSoon() } }
    }
    /// Browser downloads waiting for the user's answer, oldest first.
    @Published public private(set) var waitingDrafts: [AddDraft] = []
    @Published public var confirm: Confirm?
    @Published public var dropTargeted = false
    /// Bumped by Cmd+F; the search field takes focus when it changes.
    @Published public var searchFocusRequest = 0
    var anchor: UUID?
    /// The rows in the order the table shows them, for Shift-click ranges. Not published:
    /// the table writes it while it draws.
    var rowOrder: [UUID] = []

    private let persists: Bool

    public init(persists: Bool = true) {
        self.persists = persists
        let d = UserDefaults.standard
        if persists { Self.carryOverLegacyDefaults(into: d) }
        sort = persists ? (d.string(forKey: "list.sort").flatMap(ListSort.init(rawValue:)) ?? .newest) : .newest
        filter = persists ? (d.string(forKey: "list.filter").flatMap(ListFilter.init(rawValue:)) ?? .all) : .all
        showDetails = persists ? (d.object(forKey: "list.showDetails") as? Bool ?? true) : true
    }

    static let defaultsKeys = ["list.sort", "list.filter", "list.showDetails"]

    /// The sort, filter and detail-panel choice lived under the old bundle id before the rename.
    private static func carryOverLegacyDefaults(into d: UserDefaults) {
        guard defaultsKeys.allSatisfy({ d.object(forKey: $0) == nil }),
              let old = UserDefaults(suiteName: "com.shadman.macdownloader") else { return }
        for key in defaultsKeys { if let v = old.object(forKey: key) { d.set(v, forKey: key) } }
    }

    private func save(_ value: Any, _ key: String) {
        if persists { UserDefaults.standard.set(value, forKey: key) }
    }

    public func visible(_ manager: DownloadManager) -> [DownloadRecord] {
        ListQuery.apply(manager.items, sort: sort, filter: filter, search: search, missing: manager.missing)
    }

    // MARK: Selection

    /// Plain click selects one row, Cmd toggles, Shift extends from the last clicked row.
    func click(_ id: UUID, in order: [UUID], modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let a = anchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: id) {
            let range = order[min(i, j)...max(i, j)]
            selection = modifiers.contains(.command) ? selection.union(range) : Set(range)
        } else if modifiers.contains(.command) {
            toggle(id)
        } else {
            selection = [id]
            anchor = id
        }
    }

    func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        anchor = id
    }

    func move(by step: Int, in order: [UUID]) {
        guard !order.isEmpty else { return }
        let current = anchor.flatMap { order.firstIndex(of: $0) }
        let next = current.map { min(order.count - 1, max(0, $0 + step)) } ?? (step > 0 ? 0 : order.count - 1)
        selection = [order[next]]
        anchor = order[next]
    }

    /// Drops selected ids that are no longer in the list.
    func prune(_ manager: DownloadManager) {
        let ids = Set(manager.items.map(\.id))
        if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
    }

    // MARK: Adding

    public func openAdd(text: String? = nil, settings: AppSettings) {
        var t = text
        if t == nil, let clip = Pasteboard.text, !LinkParser.links(in: clip).isEmpty {
            t = LinkParser.links(in: clip).map(\.absoluteString).joined(separator: "\n")
        }
        guard addDraft == nil else { return }
        addDraft = AddDraft(text: t ?? "", fromClipboard: text == nil && t != nil, settings: settings)
    }

    /// The one way a draft reaches the screen: shown at once if no sheet is open, else it waits its turn.
    public func present(_ draft: AddDraft) {
        if addDraft == nil && waitingDrafts.isEmpty { addDraft = draft } else { waitingDrafts.append(draft) }
    }

    /// Waits for the closing sheet to finish leaving, or SwiftUI drops the new one.
    private func openNextSoon() {
        guard !waitingDrafts.isEmpty else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, self.addDraft == nil, !self.waitingDrafts.isEmpty else { return }
            self.addDraft = self.waitingDrafts.removeFirst()
        }
    }

    public func requestSearchFocus() { searchFocusRequest += 1 }
}

/// The Add download sheet's state. One link is probed for its name, size and resume support.
@MainActor
public final class AddDraft: ObservableObject, Identifiable {
    public enum Probe: Equatable {
        case idle, probing, done(ProbeResult), failed(String)
    }

    public let id = UUID()
    @Published public var text: String { didSet { if text != oldValue { scheduleProbe() } } }
    @Published public var fileName = ""
    @Published public var directory: String
    @Published public var connections: Int
    @Published public var probe: Probe = .idle
    public let fromClipboard: Bool
    /// Cookies, referrer and user agent from the browser; sent only to the host they came from.
    let headers: RequestHeaders
    let headersHost: String?
    /// The size the browser reported, used until or unless the probe knows better.
    let browserSize: Int64?
    var nameEdited = false
    private var task: Task<Void, Never>?
    private let liveProbe: Bool

    public init(text: String, fromClipboard: Bool, settings: AppSettings, probe: Probe? = nil,
                headers: RequestHeaders = RequestHeaders(), fileName browserName: String? = nil, browserSize: Int64? = nil) {
        self.text = text
        self.fromClipboard = fromClipboard
        self.headers = headers
        self.headersHost = LinkParser.links(in: text).first?.host?.lowercased()
        self.browserSize = (browserSize ?? 0) > 0 ? browserSize : nil
        if let n = browserName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            fileName = FileNaming.sanitise(n)
            nameEdited = true
        }
        self.directory = settings.downloadDirectory
        self.connections = settings.connections
        self.liveProbe = probe == nil
        if let probe {
            self.probe = probe
            if case .done(let r) = probe, !nameEdited { fileName = r.fileName }
        } else {
            scheduleProbe(delay: 0)
        }
    }

    public var links: [URL] { LinkParser.links(in: text) }

    private func scheduleProbe(delay: UInt64 = 450_000_000) {
        guard liveProbe else { return }
        task?.cancel()
        let links = self.links
        guard links.count == 1, let url = links.first else {
            probe = .idle
            return
        }
        probe = .probing
        task = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled else { return }
            let result = await Prober.probe(url, headers: self?.headers(for: url) ?? RequestHeaders())
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let r):
                self.probe = .done(r)
                if !self.nameEdited { self.fileName = r.fileName }
            case .failure(let f):
                self.probe = .failed(f.message)
            }
        }
    }

    /// The browser's headers, only for the host they were captured for.
    func headers(for url: URL) -> RequestHeaders {
        url.host?.lowercased() == headersHost ? headers : RequestHeaders()
    }

    var probed: ProbeResult? {
        if case .done(let r) = probe { return r }
        return nil
    }

    /// Adds every link; returns how many were added.
    @discardableResult
    func commit(to manager: DownloadManager, later: Bool) -> Int {
        task?.cancel()
        let links = self.links
        let single = links.count == 1
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        for url in links {
            manager.add(url: url,
                        fileName: single && nameEdited && !name.isEmpty ? name : nil,
                        headers: headers(for: url),
                        expectedSize: single ? (browserSize ?? probed?.totalSize) : nil,
                        directory: directory,
                        connections: connections == manager.settings.connections ? nil : connections,
                        startPaused: later)
        }
        return links.count
    }
}
