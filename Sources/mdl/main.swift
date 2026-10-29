import Foundation
import DownloaderCore

// mdl: command-line front end to the MacDownloader engine.
// usage: mdl [-c connections] [-o directory] [-n filename] URL
// Ctrl-C pauses and saves resume state; run the same command again to resume.

var connections = 8
var directory = FileManager.default.currentDirectoryPath
var name: String?
var urlString: String?
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "-c": connections = Int(args.isEmpty ? "8" : args.removeFirst()) ?? 8
    case "-o": directory = args.isEmpty ? directory : args.removeFirst()
    case "-n": name = args.isEmpty ? nil : args.removeFirst()
    case "-h", "--help":
        print("usage: mdl [-c connections] [-o directory] [-n filename] URL")
        exit(0)
    default: urlString = a
    }
}
guard let s = urlString, let url = URL(string: s) else {
    FileHandle.standardError.write(Data("usage: mdl [-c connections] [-o directory] [-n filename] URL\n".utf8))
    exit(2)
}

// Resume if a matching state file is already there.
var record = DownloadRecord(url: url, fileName: name, directory: directory, headers: RequestHeaders())
if let candidates = try? FileManager.default.contentsOfDirectory(atPath: directory) {
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    for f in candidates where f.hasSuffix(".part.json") {
        let path = (directory as NSString).appendingPathComponent(f)
        if let data = FileManager.default.contents(atPath: path),
           let saved = try? dec.decode(DownloadRecord.self, from: data), saved.url == url {
            record = saved
            record.status = .paused
            print("Resuming \(saved.fileName) from \(saved.downloadedBytes) bytes")
            break
        }
    }
}

let engine = DownloadEngine(record: record, connections: connections)
let started = Date()
let startBytes = record.downloadedBytes
engine.start()

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    engine.pause()
    let r = engine.snapshot()
    print("\nPaused at \(r.downloadedBytes) bytes; state saved to \(r.statePath)")
    exit(130)
}
sigint.resume()

var meter = SpeedMeter()
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
timer.setEventHandler {
    let r = engine.snapshot()
    meter.add(bytes: r.downloadedBytes)
    switch r.status {
    case .completed:
        let secs = Date().timeIntervalSince(started)
        let bytes = Double((r.totalSize ?? 0) - startBytes)
        print(String(format: "\nDone: %@ (%lld bytes) in %.2f s, %.2f MB/s, connections %d",
                     r.finalPath, r.totalSize ?? 0, secs, bytes / secs / 1_000_000, connections))
        exit(0)
    case .failed, .cancelled:
        print("\nFailed: \(r.errorMessage ?? r.status.rawValue)")
        exit(1)
    default:
        let pct = r.progress.map { String(format: "%5.1f%%", $0 * 100) } ?? "  ?  "
        let line = String(format: "\r%@ %@  %.2f MB/s  conns %d  ", r.fileName, pct, meter.speed / 1_000_000, engine.activeConnections)
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}
timer.resume()
dispatchMain()
