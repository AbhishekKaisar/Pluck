import AppKit
import SwiftUI
import DownloaderCore

/// App-wide state: the manager, the window's list state, the local API server and its token.
@MainActor
public final class AppModel: ObservableObject {
    public static let shared = AppModel()

    public let manager: DownloadManager
    public let ui: ListState
    public let token: String
    @Published public var port: UInt16?
    @Published public var serverError: String?
    private var server: LocalServer?

    private init() {
        manager = DownloadManager()
        ui = ListState()
        token = Persistence.token()
        startServer()
    }

    /// For snapshots: no server, no disk.
    public init(preview manager: DownloadManager, ui: ListState, port: UInt16? = 6801) {
        self.manager = manager
        self.ui = ui
        self.token = "0123456789abcdef0123456789abcdef0123456789abcdef"
        self.port = port
    }

    private func startServer() {
        let token = self.token
        let server = LocalServer { request, respond in
            switch APIRouter.route(request, token: token) {
            case .respond(let response):
                respond(response)
            case .run(let command):
                Task { @MainActor in respond(AppModel.shared.run(command)) }
            }
        }
        server.onReady = { port in
            Task { @MainActor in
                AppModel.shared.port = port
                AppModel.shared.serverError = nil
                Persistence.save(ServerState(port: port, pid: ProcessInfo.processInfo.processIdentifier, version: AppInfo.version),
                                 to: Persistence.serverStateURL)
            }
        }
        server.onFailure = { message in
            Task { @MainActor in AppModel.shared.serverError = message }
        }
        self.server = server
        server.start()
    }

    public func stopServer() { server?.stop() }

    func run(_ command: APIRouter.Command) -> HTTPResponse {
        switch command {
        case .add(let add):
            guard let url = URL(string: add.url) else { return HTTPResponse(status: 400, json: ["error": "bad url"]) }
            let headers = RequestHeaders(cookies: add.cookies, referrer: add.referrer, userAgent: add.userAgent)
            // The reply must not wait for the user: the extension cancels the browser's copy on it.
            // No record exists yet, so there is no id; nothing reads it.
            if add.ask == true, ask(url: url, fileName: add.filename, headers: headers, size: add.fileSize) {
                return HTTPResponse(status: 200, json: ["ok": true, "asking": true])
            }
            let id = manager.add(url: url, fileName: add.filename, headers: headers, expectedSize: add.fileSize)
            return HTTPResponse(status: 200, json: ["ok": true, "id": id.uuidString])
        case .list:
            let list: [[String: Any]] = manager.items.map { r in
                [
                    "id": r.id.uuidString, "url": r.url.absoluteString, "fileName": r.fileName, "directory": r.directory,
                    "status": r.status.rawValue, "downloaded": r.downloadedBytes, "size": r.totalSize ?? -1,
                    "speed": manager.speeds[r.id] ?? 0, "error": r.errorMessage ?? "", "segments": r.segments.count,
                ]
            }
            return HTTPResponse(status: 200, json: ["items": list])
        case .control(let id, let action):
            guard manager.item(id) != nil else { return HTTPResponse(status: 404, json: ["error": "no such download"]) }
            switch action {
            case "pause": manager.pause(id)
            case "resume": manager.resume(id)
            case "remove":
                // Leaves a finished file on disk; unfinished partial data is deleted.
                manager.remove(id)
            default: manager.cancel(id)
            }
            return HTTPResponse(status: 200, json: ["ok": true])
        }
    }

    /// `pluck://add?url=...&filename=...&referrer=...` (the old `macdownloader://` still works).
    public func handle(openURL url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "pluck" || scheme == "macdownloader",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let action = (comps.host ?? comps.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard action == "add" else { return }
        let q = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let s = q["url"], let target = URL(string: s), let scheme = target.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        let headers = RequestHeaders(referrer: q["referrer"])
        if !ask(url: target, fileName: q["filename"], headers: headers, size: nil) {
            manager.add(url: target, fileName: q["filename"], headers: headers)
        }
    }

    /// Queues the Add sheet for a download from outside the app when the user asked to choose each folder.
    private func ask(url: URL, fileName: String?, headers: RequestHeaders, size: Int64?) -> Bool {
        guard manager.settings.askWhereToSave else { return false }
        ui.present(AddDraft(text: url.absoluteString, fromClipboard: false, settings: manager.settings,
                            headers: headers, fileName: fileName, browserSize: size))
        return true
    }

    // MARK: Menu actions shared by the window and the app menu

    public func pasteLinks() {
        let text = Pasteboard.text ?? ""
        ui.openAdd(text: LinkParser.links(in: text).map(\.absoluteString).joined(separator: "\n"), settings: manager.settings)
    }

    public func importLinks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let links = LinkParser.links(in: text)
        ui.openAdd(text: links.map(\.absoluteString).joined(separator: "\n"), settings: manager.settings)
    }

    public func exportLinks() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Pluck links.txt"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = manager.items.reversed().map(\.url.absoluteString).joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct ServerState: Codable {
    var port: UInt16
    var pid: Int32
    var version: String
}
