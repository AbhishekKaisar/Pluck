import Foundation

public enum FileNaming {
    /// Extracts a filename from a `Content-Disposition` header.
    /// Prefers RFC 5987 `filename*=UTF-8''...` over plain `filename=`.
    public static func filename(fromContentDisposition header: String) -> String? {
        var plain: String?
        var extended: String?
        for rawPart in splitParameters(header) {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key == "filename*" {
                // charset'lang'percent-encoded
                let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if pieces.count == 3 {
                    let charset = pieces[0].lowercased()
                    let encoded = String(pieces[2]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if charset == "utf-8" || charset.isEmpty {
                        extended = encoded.removingPercentEncoding
                    } else if charset == "iso-8859-1" {
                        extended = percentDecodeLatin1(encoded)
                    }
                }
            } else if key == "filename" {
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                    value = value.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                }
                // Some servers percent-encode the plain form too.
                if value.contains("%"), let decoded = value.removingPercentEncoding { value = decoded }
                plain = value
            }
        }
        let chosen = extended ?? plain
        guard let name = chosen.map(sanitise), !name.isEmpty else { return nil }
        return name
    }

    /// Last path component of a URL, percent-decoded, or nil when it is empty or a bare "/".
    public static func filename(fromURL url: URL) -> String? {
        let last = url.lastPathComponent
        guard !last.isEmpty, last != "/" else { return nil }
        let name = sanitise(last.removingPercentEncoding ?? last)
        return name.isEmpty ? nil : name
    }

    /// Chooses the best name: explicit suggestion, then Content-Disposition, then the final URL, then the original URL.
    public static func chooseName(suggested: String?, contentDisposition: String?, finalURL: URL?, originalURL: URL, mimeType: String? = nil) -> String {
        if let s = suggested.map(sanitise), !s.isEmpty { return s }
        if let cd = contentDisposition, let n = filename(fromContentDisposition: cd) { return n }
        if let f = finalURL, let n = filename(fromURL: f) { return withExtension(n, mimeType: mimeType) }
        if let n = filename(fromURL: originalURL) { return withExtension(n, mimeType: mimeType) }
        return withExtension("download", mimeType: mimeType)
    }

    /// Removes path separators and control characters, trims dots and spaces, caps the length.
    public static func sanitise(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .").union(.whitespacesAndNewlines))
        if s.utf8.count > 240 {
            let ext = (s as NSString).pathExtension
            var stem = (s as NSString).deletingPathExtension
            while stem.utf8.count + ext.utf8.count > 238 { stem.removeLast() }
            s = ext.isEmpty ? stem : stem + "." + ext
        }
        return s
    }

    /// Returns `name` if free, else "stem (1).ext", "stem (2).ext" and so on.
    /// `exists` is injectable for tests. A `.tar.gz` style double extension is kept together.
    public static func uniqueName(_ name: String, exists: (String) -> Bool) -> String {
        if !exists(name) { return name }
        let (stem, ext) = splitExtension(name)
        var n = 1
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// A free name in `directory`, treating our own in-progress `.part` files as taken too.
    public static func uniqueName(_ name: String, inDirectory directory: String, reserved: Set<String> = []) -> String {
        let fm = FileManager.default
        return uniqueName(name) { candidate in
            reserved.contains(candidate)
                || fm.fileExists(atPath: (directory as NSString).appendingPathComponent(candidate))
                || fm.fileExists(atPath: (directory as NSString).appendingPathComponent(candidate + ".part"))
        }
    }

    static func splitExtension(_ name: String) -> (String, String) {
        let lower = name.lowercased()
        for compound in ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"] where lower.hasSuffix("." + compound) {
            let stem = String(name.dropLast(compound.count + 1))
            if !stem.isEmpty { return (stem, String(name.suffix(compound.count))) }
        }
        let ext = (name as NSString).pathExtension
        if ext.isEmpty || ext == name.dropFirst() { return (name, "") }
        return ((name as NSString).deletingPathExtension, ext)
    }

    static func withExtension(_ name: String, mimeType: String?) -> String {
        guard (name as NSString).pathExtension.isEmpty, let mime = mimeType?.lowercased() else { return name }
        let map: [String: String] = [
            "application/zip": "zip", "application/pdf": "pdf", "application/x-apple-diskimage": "dmg",
            "video/mp4": "mp4", "audio/mpeg": "mp3", "application/x-tar": "tar", "application/gzip": "gz",
        ]
        if let ext = map[mime] { return name + "." + ext }
        return name
    }

    /// Splits on `;` outside quotes.
    private static func splitParameters(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in s {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && inQuotes { current.append(ch); escaped = true; continue }
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";" && !inQuotes { parts.append(current); current = ""; continue }
            current.append(ch)
        }
        parts.append(current)
        return parts
    }

    private static func percentDecodeLatin1(_ s: String) -> String? {
        var bytes: [UInt8] = []
        var it = s.utf8.makeIterator()
        while let c = it.next() {
            if c == UInt8(ascii: "%"), let h = it.next(), let l = it.next(),
               let v = UInt8(String(bytes: [h, l], encoding: .ascii) ?? "", radix: 16) {
                bytes.append(v)
            } else {
                bytes.append(c)
            }
        }
        return String(bytes: bytes, encoding: .isoLatin1)
    }
}
