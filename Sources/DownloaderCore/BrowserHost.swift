import Foundation

/// Registers the native messaging host that lets a Chromium browser start Pluck when the
/// extension finds it closed. The host is `Contents/Resources/pluck-host` inside the app.
public enum BrowserHost {
    public static let name = "io.github.abhishekkaisar.pluck"
    /// The extension's ID, fixed by the `key` in extension/manifest.json.
    public static let extensionID = "oolmpkdpgffpejjjgbakkkcojbglleag"
    /// Folders under ~/Library/Application Support, one per Chromium browser.
    public static let browserFolders = [
        "Google/Chrome", "Google/Chrome Beta", "Google/Chrome Dev", "Google/Chrome Canary",
        "Microsoft Edge", "Microsoft Edge Beta", "Microsoft Edge Dev", "Microsoft Edge Canary",
        "BraveSoftware/Brave-Browser", "Chromium", "Vivaldi", "Arc/User Data",
    ]

    /// A disk image or Gatekeeper's translocated copy goes away later, so a registration that
    /// points there would replace a good one with a dead one.
    static func isTemporary(_ hostPath: String) -> Bool {
        hostPath.hasPrefix("/Volumes/") || hostPath.contains("/AppTranslocation/")
    }

    /// Writes the host manifest for each installed browser. Rewrites a file only when its content
    /// differs, so an app that was moved corrects the path at its next launch. Never throws.
    /// Returns the files written.
    @discardableResult
    public static func register(hostPath: String, home: URL) -> [URL] {
        let fm = FileManager.default
        guard !isTemporary(hostPath), fm.isExecutableFile(atPath: hostPath) else { return [] }
        let manifest: [String: Any] = [
            "name": name,
            "description": "Starts Pluck when the browser extension finds it closed",
            "path": hostPath,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return [] }
        let support = home.appendingPathComponent("Library/Application Support")
        var written: [URL] = []
        for folder in browserFolders {
            let browser = support.appendingPathComponent(folder)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: browser.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let dir = browser.appendingPathComponent("NativeMessagingHosts")
            let file = dir.appendingPathComponent("\(name).json")
            if let current = try? Data(contentsOf: file), current == data { continue }
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                written.append(file)
            } catch {}
        }
        return written
    }
}
