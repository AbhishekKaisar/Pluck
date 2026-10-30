import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DownloaderCore

/// The command line tools ship SwiftUI without its macro plugin, so the `@State` macro cannot expand.
/// This alias reaches the underlying property wrapper directly.
public typealias ViewState<Value> = SwiftUICore.State<Value>

public enum Format {
    public static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: n)
    }

    public static func speed(_ bps: Double) -> String { "\(bytes(Int64(bps)))/s" }

    public static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    public static func limit(_ kib: Int) -> String { "\(bytes(Int64(kib) * 1024))/s" }

    /// "14:02" today, "Yesterday", else "12 Oct" (with the year when it is not this year).
    static func added(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        if cal.isDate(date, inSameDayAs: now) {
            f.dateFormat = "HH:mm"
            return "Today " + f.string(from: date)
        }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) {
            f.dateFormat = "HH:mm"
            return "Yesterday " + f.string(from: date)
        }
        f.dateFormat = cal.component(.year, from: date) == cal.component(.year, from: now) ? "d MMM" : "d MMM yyyy"
        return f.string(from: date)
    }
}

/// File icons from the system, cached by extension. A finished file on disk gets its own icon,
/// cached by path. Rendering never touches the disk: `missing` (refreshed on launch, focus and
/// completion) says whether the file is there, and the disk is checked only on a cache miss.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for r: DownloadRecord, missing: Bool) -> NSImage {
        let fileKey = "file:" + r.finalPath
        if r.status == .completed, !missing {
            if let i = cache[fileKey] { return i }
            if FileManager.default.fileExists(atPath: r.finalPath) {
                let i = NSWorkspace.shared.icon(forFile: r.finalPath)
                cache[fileKey] = i
                return i
            }
        } else if missing, cache[fileKey] != nil {
            // The file went away; a file that comes back gets a fresh icon.
            cache[fileKey] = nil
        }
        let ext = (r.fileName as NSString).pathExtension.lowercased()
        if let i = cache[ext] { return i }
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        let i = NSWorkspace.shared.icon(for: type)
        cache[ext] = i
        return i
    }
}

enum Pasteboard {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static var text: String? { NSPasteboard.general.string(forType: .string) }
}

/// A small square checkbox drawn in SwiftUI so it can show a mixed state.
struct CheckBox: View {
    enum Mark { case off, on, mixed }
    let mark: Mark
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(mark == .off ? Color(nsColor: .controlBackgroundColor) : Color.accentColor)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(mark == .off ? Color.secondary.opacity(0.55) : Color.accentColor, lineWidth: 1)
                if mark != .off {
                    Image(systemName: mark == .on ? "checkmark" : "minus")
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 14, height: 14)
            .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mark == .on ? "Selected" : "Not selected")
    }
}

/// Quiet toolbar button: no border, a soft fill on hover and press.
struct QuietButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, prominent: prominent)
    }

    private struct QuietButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isEnabled) private var enabled
        @ViewState private var hover = false

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(prominent ? Color.red : Color.primary)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hover ? 0.07 : 0.0)))
                )
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

/// The one accent button: filled blue in every window state (the system greys prominent buttons in inactive windows).
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentBody(configuration: configuration)
    }

    private struct AccentBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(configuration.isPressed ? 0.15 : 0)))
                )
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Rectangle())
        }
    }
}

extension DownloadRecord {
    var canPause: Bool { status.isActive || status == .queued }
    var canResume: Bool { status == .paused || status == .failed }
}
