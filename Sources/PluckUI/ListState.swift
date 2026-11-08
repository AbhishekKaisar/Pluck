import AppKit
import Combine
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
        didSet { if addDraft == nil && oldValue != nil { sheetLeaving() } }
    }
    /// Browser downloads waiting for the user's answer, oldest first.
    @Published public private(set) var waitingDrafts: [AddDraft] = []
    /// Fires when a draft needs the user, even if it only joined the queue. A subject, so the
    /// always-alive menu bar label can listen without redrawing on every search keystroke.
    public let needsAttention = PassthroughSubject<Void, Never>()
    @Published public var confirm: Confirm?
    @Published public var dropTargeted = false
    /// Bumped by Cmd+F; the search field takes focus when it changes.
    @Published public var searchFocusRequest = 0
    var anchor: UUID?
    /// The rows in the order the table shows them, for Shift-click ranges. Not published:
    /// the table writes it while it draws.
    var rowOrder: [UUID] = []

    private let persists: Bool
    /// Running while a closed sheet finishes leaving.
    private var leaving: Task<Void, Never>?

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
        // Cmd+N has nothing to keep while a sheet is open. Links from a paste, drop or file do, so they wait.
        guard addDraft == nil || text?.isEmpty == false else { return }
        present(AddDraft(text: t ?? "", fromClipboard: text == nil && t != nil, settings: settings))
    }

    /// The one way a draft reaches the screen: shown at once if no sheet is open or leaving, else it waits its turn.
    public func present(_ draft: AddDraft) {
        if addDraft == nil && leaving == nil && waitingDrafts.isEmpty { addDraft = draft } else { waitingDrafts.append(draft) }
        needsAttention.send()
    }

    /// Gives the closing sheet time to leave before the next one opens, whichever arrives meanwhile.
    private func sheetLeaving() {
        leaving = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self else { return }
            self.leaving = nil
            guard self.addDraft == nil, !self.waitingDrafts.isEmpty else { return }
            self.addDraft = self.waitingDrafts.removeFirst()
            self.needsAttention.send()
        }
    }

    /// The browser's copy of these is already gone, so on quit they become paused rows instead of vanishing.
    public func parkBrowserDrafts(in manager: DownloadManager) {
        for draft in [addDraft].compactMap({ $0 }) + waitingDrafts where draft.isFromBrowser {
            draft.commit(to: manager, later: true)
        }
        waitingDrafts = []
    }

    public func requestSearchFocus() { searchFocusRequest += 1 }
}

/// The Add download sheet's state. One link is probed for its name, size and resume support.
@MainActor
public final class AddDraft: ObservableObject, Identifiable {
    private(set) var committed = false
    public enum Probe: Equatable {
        case idle, probing, done(ProbeResult), failed(String)
    }

    public let id = UUID()
    @Published public var text: String { didSet { if text != oldValue { linkChanged() } } }
    @Published public var fileName = ""
    @Published public var directory: String
    @Published public var connections: Int
    @Published public var probe: Probe = .idle
    public let fromClipboard: Bool
    /// The exact link from outside the app. LinkParser reads pasted text and would cut this one at an apostrophe.
    private let caught: URL?
    /// Cookies, referrer and user agent from the browser; sent only to the origin they came from.
    let headers: RequestHeaders
    let browserName: String?
    /// The size the browser reported, used until or unless the probe knows better.
    let browserSize: Int64?
    var nameEdited = false
    private var task: Task<Void, Never>?
    private let liveProbe: Bool
    private(set) var probeStarted = false

    public convenience init(text: String, fromClipboard: Bool, settings: AppSettings, probe: Probe? = nil) {
        self.init(text: text, fromClipboard: fromClipboard, caught: nil, settings: settings, probe: probe,
                  headers: RequestHeaders(), browserName: nil, browserSize: nil)
    }

    /// A download from the browser or a `pluck://` link, with what is known about it.
    public convenience init(caught url: URL, settings: AppSettings, probe: Probe? = nil, headers: RequestHeaders = RequestHeaders(),
                            fileName: String? = nil, browserSize: Int64? = nil) {
        self.init(text: url.absoluteString, fromClipboard: false, caught: url, settings: settings, probe: probe,
                  headers: headers, browserName: fileName, browserSize: browserSize)
    }

    private init(text: String, fromClipboard: Bool, caught: URL?, settings: AppSettings, probe: Probe?,
                 headers: RequestHeaders, browserName: String?, browserSize: Int64?) {
        self.text = text
        self.fromClipboard = fromClipboard
        self.caught = caught
        self.headers = headers
        self.browserSize = (browserSize ?? 0) > 0 ? browserSize : nil
        let name = browserName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.browserName = name.isEmpty ? nil : FileNaming.sanitise(name)
        fileName = self.browserName ?? ""
        nameEdited = self.browserName != nil
        self.directory = settings.downloadDirectory
        self.connections = settings.connections
        self.liveProbe = probe == nil
        if let probe {
            self.probe = probe
            if case .done(let r) = probe, !nameEdited { fileName = r.fileName }
        } else if links.count == 1 {
            self.probe = .probing
        }
    }

    /// Called when the sheet appears, not when the draft queues: a burst of downloads should not send
    /// a cookie-bearing request each for sheets not seen yet, and the settings may change meanwhile.
    func begin(settings: AppSettings) {
        guard liveProbe, !probeStarted else { return }
        probeStarted = true
        directory = settings.downloadDirectory
        connections = settings.connections
        scheduleProbe(delay: 0)
    }

    var isFromBrowser: Bool { caught != nil }

    /// Whether the sheet still holds the caught link, so the browser's name and size still describe it.
    private var holdsCaughtLink: Bool {
        caught?.absoluteString == text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var links: [URL] {
        if holdsCaughtLink, let caught { return [caught] }
        return LinkParser.links(in: text)
    }

    /// The size to show and to save with the download.
    var size: Int64? { probed?.totalSize ?? caughtSize }
    /// The browser's size, for as long as it describes the link in the sheet.
    var caughtSize: Int64? { holdsCaughtLink ? browserSize : nil }

    /// A different link is a different file, so a name the browser gave for the old one goes. One the user typed stays.
    private func linkChanged() {
        if !holdsCaughtLink, nameEdited, fileName == browserName {
            nameEdited = false
            fileName = ""
        }
        scheduleProbe()
    }

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

    /// The browser's headers, only for the origin they were captured for: a Secure cookie must not go out over http.
    func headers(for url: URL) -> RequestHeaders {
        guard let caught, url.host?.lowercased() == caught.host?.lowercased(),
              url.scheme?.lowercased() == caught.scheme?.lowercased(), url.port == caught.port else { return RequestHeaders() }
        return headers
    }

    var probed: ProbeResult? {
        if case .done(let r) = probe { return r }
        return nil
    }

    /// Adds every link; returns how many were added.
    @discardableResult
    func commit(to manager: DownloadManager, later: Bool) -> Int {
        // A second call for the same draft (a double submit path) must not add the links again.
        guard !committed else { return 0 }
        committed = true
        task?.cancel()
        let links = self.links
        let single = links.count == 1
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        for url in links {
            manager.add(url: url,
                        fileName: single && nameEdited && !name.isEmpty ? name : nil,
                        headers: headers(for: url),
                        expectedSize: single ? size : nil,
                        directory: directory,
                        connections: connections == manager.settings.connections ? nil : connections,
                        startPaused: later)
        }
        return links.count
    }
}
