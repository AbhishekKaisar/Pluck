import AppKit
import SwiftUI
import DownloaderCore

@main
struct MacDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("MacDownloader", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.manager)
                .frame(minWidth: 640, minHeight: 360)
        }
        .defaultSize(width: 860, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(model)
                .environmentObject(model.manager)
        } label: {
            MenuBarLabel(manager: model.manager)
        }
        .menuBarExtraStyle(.window)
    }
}

/// App-wide state: the manager, the local API server and its token.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let manager = DownloadManager()
    let token = Persistence.token()
    @Published var port: UInt16?
    @Published var serverError: String?
    @Published var showSettings = false
    private var server: LocalServer?

    private init() {
        startServer()
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

    func stopServer() { server?.stop() }

    private func run(_ command: APIRouter.Command) -> HTTPResponse {
        switch command {
        case .add(let add):
            guard let url = URL(string: add.url) else { return HTTPResponse(status: 400, json: ["error": "bad url"]) }
            let id = manager.add(url: url, fileName: add.filename,
                                 headers: RequestHeaders(cookies: add.cookies, referrer: add.referrer, userAgent: add.userAgent),
                                 expectedSize: add.fileSize)
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
            default: manager.cancel(id)
            }
            return HTTPResponse(status: 200, json: ["ok": true])
        }
    }

    /// `macdownloader://add?url=...&filename=...&referrer=...`
    func handle(openURL url: URL) {
        guard url.scheme?.lowercased() == "macdownloader",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let action = (comps.host ?? comps.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard action == "add" else { return }
        let q = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let s = q["url"], let target = URL(string: s), let scheme = target.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        manager.add(url: target, fileName: q["filename"], headers: RequestHeaders(referrer: q["referrer"]))
    }
}

struct ServerState: Codable {
    var port: UInt16
    var pid: Int32
    var version: String
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = MainActor.assumeIsolated { AppModel.shared }
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        MainActor.assumeIsolated { AppModel.shared.handle(openURL: url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.manager.prepareForQuit()
            AppModel.shared.stopServer()
        }
    }
}
