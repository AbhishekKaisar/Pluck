import AppKit
import SwiftUI
import DownloaderCore
import PluckUI

@main
struct PluckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Pluck", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.manager)
                .environmentObject(model.ui)
                .frame(minWidth: 700, minHeight: 440)
        }
        .defaultSize(width: 1040, height: 640)
        .windowToolbarStyle(.unifiedCompact)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.manager)
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(model)
                .environmentObject(model.manager)
        } label: {
            MenuBarLabel(manager: model.manager, ui: model.ui)
        }
        .menuBarExtraStyle(.window)
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Download…") {
                showWindow()
                model.ui.openAdd(settings: model.manager.settings)
            }
            .keyboardShortcut("n")
            Button("Paste Links from Clipboard") {
                showWindow()
                model.pasteLinks()
            }
            Button("Import Links from File…") {
                showWindow()
                model.importLinks()
            }
            Button("Export Links…") { model.exportLinks() }
        }
        CommandGroup(replacing: .textEditing) {
            Button("Find") {
                showWindow()
                model.ui.requestSearchFocus()
            }
            .keyboardShortcut("f")
        }
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = MainActor.assumeIsolated { AppModel.shared }
        // A test copy (own support folder) must not take over the real registration.
        if Persistence.customSupportDirectory == nil, let host = Bundle.main.path(forResource: "pluck-host", ofType: nil) {
            BrowserHost.register(hostPath: host, home: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        MainActor.assumeIsolated { AppModel.shared.handle(openURL: url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppModel.shared.ui.parkBrowserDrafts(in: AppModel.shared.manager) }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.manager.prepareForQuit()
            AppModel.shared.stopServer()
        }
    }
}
