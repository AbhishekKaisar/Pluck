import Foundation

/// Runs one download: probe, segmented transfer into a preallocated `.part` file, resume state, finish.
/// All mutable state lives on `queue`; URLSession delegate callbacks are delivered on the same queue,
/// so file writes are serialised per file without extra locking.
public final class DownloadEngine: NSObject, @unchecked Sendable {
    public let id: UUID
    public static let maxRetries = 6
    /// Smallest piece the tail splitter will hand to a fresh connection.
    public static let minDynamicSplit: Int64 = 128 * 1024
    /// Restart a connection that delivered nothing for this long.
    static let stallTimeout: TimeInterval = 12
    /// In the tail (spare connections, nothing left to split), restart connections slower than this.
    static let slowTailRate: Double = 64 * 1024

    private let queue: DispatchQueue
    private let delegateQueue: OperationQueue
    private let limiter: SpeedLimiter
    private var record: DownloadRecord
    private var connections: Int

    private var workers: [Int: SegmentWorker] = [:]
    private var retries: [Int: Int] = [:]
    private var restarts: [Int: Int] = [:]
    private var pendingRetry: Set<Int> = []
    private var file: FileHandle?
    private var lastSave = Date.distantPast
    private var probeSession: URLSession?
    /// Bumped by pause and cancel so late callbacks from an old run are ignored.
    private var generation = 0

    public init(record: DownloadRecord, connections: Int, limiter: SpeedLimiter = .shared) {
        self.id = record.id
        self.record = record
        self.connections = min(SegmentMath.maxConnections, max(1, connections))
        self.limiter = limiter
        self.queue = DispatchQueue(label: "macdownloader.engine.\(record.id.uuidString)")
        let oq = OperationQueue()
        oq.maxConcurrentOperationCount = 1
        oq.underlyingQueue = queue
        self.delegateQueue = oq
        super.init()
    }

    // MARK: Public API (thread safe)

    public func snapshot() -> DownloadRecord { queue.sync { record } }

    public var activeConnections: Int { queue.sync { workers.count } }

    public func start(connections: Int? = nil) {
        queue.async {
            if let c = connections { self.connections = min(SegmentMath.maxConnections, max(1, c)) }
            self.startLocked()
        }
    }

    /// Synchronous so the state file is on disk before the app quits.
    public func pause() {
        queue.sync {
            generation += 1
            stopAll()
            probeSession?.invalidateAndCancel()
            probeSession = nil
            if record.status.isActive || record.status == .queued || record.status == .failed {
                record.status = .paused
            }
            saveState(force: true)
            closeFile()
        }
    }

    public func cancel(deleteFiles: Bool = true) {
        queue.sync {
            generation += 1
            stopAll()
            probeSession?.invalidateAndCancel()
            probeSession = nil
            closeFile()
            if record.status != .completed {
                record.status = .cancelled
                if deleteFiles {
                    try? FileManager.default.removeItem(atPath: record.partPath)
                    try? FileManager.default.removeItem(atPath: record.statePath)
                }
            }
        }
    }

    // MARK: Start and probe

    private func startLocked() {
        guard !record.status.isActive, record.status != .completed, record.status != .cancelled else { return }
        generation += 1
        retries.removeAll()
        restarts.removeAll()
        pendingRetry.removeAll()
        record.errorMessage = nil
        if record.probed {
            beginTransfer()
        } else {
            record.status = .probing
            probe()
        }
    }

    private func probe() {
        var req = URLRequest(url: record.url, timeoutInterval: 30)
        record.headers.apply(to: &req)
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let gen = generation
        let delegate = ProbeDelegate { [weak self] result in
            guard let self else { return }
            self.queue.async { self.probeFinished(result, generation: gen) }
        }
        let session = URLSession(configuration: Self.makeConfiguration(), delegate: delegate, delegateQueue: nil)
        probeSession = session
        session.dataTask(with: req).resume()
    }

    private func probeFinished(_ result: Result<HTTPURLResponse, Error>, generation gen: Int) {
        guard gen == generation, record.status == .probing else { return }
        probeSession = nil
        switch result {
        case .failure(let error):
            fail("Could not reach the server: \(error.localizedDescription)")
        case .success(let http):
            if http.statusCode >= 400 {
                fail("Server answered HTTP \(http.statusCode)")
                return
            }
            var size: Int64?
            var ranges = false
            if http.statusCode == 206, let cr = http.value(forHTTPHeaderField: "Content-Range"),
               let parsed = SegmentMath.parseContentRange(cr) {
                size = parsed.total
                ranges = parsed.total != nil
            } else if http.expectedContentLength > 0 {
                size = http.expectedContentLength
            }
            record.totalSize = size
            record.acceptsRanges = ranges
            record.probed = true
            if !record.nameIsFixed {
                record.fileName = FileNaming.chooseName(
                    suggested: nil,
                    contentDisposition: http.value(forHTTPHeaderField: "Content-Disposition"),
                    finalURL: http.url, originalURL: record.url, mimeType: http.mimeType)
            }
            record.fileName = FileNaming.uniqueName(record.fileName, inDirectory: record.directory)
            beginTransfer()
        }
    }

    // MARK: Transfer

    private func beginTransfer() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: record.directory, withIntermediateDirectories: true)
            loadStateFileIfNewer()
            let fresh = record.segments.isEmpty || !fm.fileExists(atPath: record.partPath)
            if fresh {
                record.segments = record.acceptsRanges
                    ? SegmentMath.plan(totalSize: record.totalSize, connections: connections)
                    : [Segment(start: 0, end: (record.totalSize ?? 0) - 1)]
                if record.totalSize == nil { record.segments = [Segment(start: 0, end: -1)] }
                guard fm.createFile(atPath: record.partPath, contents: nil) else {
                    fail("Cannot create \(record.partPath)")
                    return
                }
            } else if !record.acceptsRanges {
                // No ranges: a partial file cannot be continued, start over.
                record.segments = [Segment(start: 0, end: (record.totalSize ?? 0) - 1)]
                if record.totalSize == nil { record.segments = [Segment(start: 0, end: -1)] }
            }
            let handle = try FileHandle(forUpdating: URL(fileURLWithPath: record.partPath))
            if record.acceptsRanges, let size = record.totalSize {
                if try handle.seekToEnd() != UInt64(size) { try handle.truncate(atOffset: UInt64(size)) }
            } else if record.segments.first?.received == 0 {
                try handle.truncate(atOffset: 0)
            }
            file = handle
        } catch {
            fail("File error: \(error.localizedDescription)")
            return
        }
        record.status = .downloading
        saveState(force: true)
        fillWorkers()
        scheduleWatchdog()
    }

    // MARK: Watchdog

    private func scheduleWatchdog() {
        let gen = generation
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, gen == self.generation, self.record.status == .downloading else { return }
            self.watchdog()
            self.scheduleWatchdog()
        }
    }

    /// Replaces stalled connections, and in the tail replaces crawling ones: a fresh TCP connection
    /// usually beats one stuck in loss recovery, and it stops one slow link holding up the finish.
    private func watchdog() {
        let now = Date()
        let tail = busySlots < connections
        let limited = limiter.bytesPerSecond > 0
        for (i, w) in workers {
            var restart = false
            if now.timeIntervalSince(w.lastDataAt) > Self.stallTimeout {
                restart = true
            } else if now.timeIntervalSince(w.markTime) >= 6 {
                let rate = Double(w.bytes - w.markBytes) / now.timeIntervalSince(w.markTime)
                w.markBytes = w.bytes
                w.markTime = now
                if tail && !limited && rate < Self.slowTailRate && record.segments[i].remaining > Self.minDynamicSplit {
                    restart = true
                }
            }
            if limited && w.pieceEnd == nil && record.acceptsRanges && !record.segments[i].isOpenEnded {
                // The limit was switched on mid-transfer: move this connection to paced pieces.
                workers[i] = nil
                w.stop()
                startWorker(i)
                continue
            }
            if restart && (restarts[i] ?? 0) < 10 {
                restarts[i, default: 0] += 1
                workers[i] = nil
                w.stop()
                startWorker(i)
            }
        }
        fillWorkers()
    }

    private func loadStateFileIfNewer() {
        guard let data = FileManager.default.contents(atPath: record.statePath),
              let saved = try? JSONDecoder.iso.decode(DownloadRecord.self, from: data),
              saved.id == record.id,
              SegmentMath.downloaded(saved.segments) >= SegmentMath.downloaded(record.segments) else { return }
        record.segments = saved.segments
        record.totalSize = saved.totalSize
        record.acceptsRanges = saved.acceptsRanges
    }

    /// Keeps every connection busy: start idle segments, then split the largest running one.
    private func fillWorkers() {
        guard record.status == .downloading else { return }
        for i in record.segments.indices where busySlots < connections {
            if !record.segments[i].isComplete && workers[i] == nil && !pendingRetry.contains(i) {
                startWorker(i)
            }
        }
        while record.acceptsRanges && busySlots < connections {
            guard let n = SegmentMath.splitLargest(&record.segments, minSegment: Self.minDynamicSplit, excluding: pendingRetry) else { break }
            startWorker(n)
        }
        if workers.isEmpty && pendingRetry.isEmpty && allComplete { finish() }
    }

    /// Connections in use, counting segments resting between paced pieces or waiting to retry.
    private var busySlots: Int { workers.count + pendingRetry.count }

    private var allComplete: Bool { !record.segments.isEmpty && record.segments.allSatisfy(\.isComplete) }

    private func startWorker(_ i: Int, reusing existing: SegmentWorker? = nil) {
        var req = URLRequest(url: record.url, timeoutInterval: 30)
        record.headers.apply(to: &req)
        var pieceEnd: Int64?
        if record.acceptsRanges {
            let seg = record.segments[i]
            let rate = limiter.bytesPerSecond
            if rate > 0, !seg.isOpenEnded {
                // Speed limit on: fetch in paced pieces, so the network never runs ahead of the limit.
                let piece = min(4 << 20, max(64 << 10, rate / Int64(max(1, connections)) / 2))
                pieceEnd = min(seg.end, seg.current + piece - 1)
                req.setValue("bytes=\(seg.current)-\(pieceEnd!)", forHTTPHeaderField: "Range")
            } else if let r = SegmentMath.rangeHeader(for: seg) {
                req.setValue(r, forHTTPHeaderField: "Range")
            }
        } else {
            record.segments[i].received = 0
        }
        let w = existing ?? SegmentWorker(index: i, engine: self)
        w.pieceEnd = pieceEnd
        w.failure = nil
        workers[i] = w
        w.start(req, delegateQueue: delegateQueue)
    }

    fileprivate func workerResponse(_ w: SegmentWorker, _ response: URLResponse) -> Bool {
        guard workers[w.index] === w, record.status == .downloading else { return false }
        guard let http = response as? HTTPURLResponse else { return true }
        if http.statusCode >= 400 {
            w.failure = "Server answered HTTP \(http.statusCode)"
            return false
        }
        if record.acceptsRanges && http.statusCode == 200 {
            let seg = record.segments[w.index]
            if record.segments.count == 1 && seg.current == 0 { return true }
            // Server stopped honouring ranges: fall back to one plain stream.
            downgradeToSingleStream()
            return false
        }
        return true
    }

    fileprivate func workerReceived(_ w: SegmentWorker, _ data: Data) {
        guard workers[w.index] === w, record.status == .downloading, let file else { return }
        let i = w.index
        let seg = record.segments[i]
        var chunk = data
        if !seg.isOpenEnded {
            let room = seg.end - seg.current + 1
            if room <= 0 { completeWorker(w); return }
            if Int64(chunk.count) > room { chunk = chunk.prefix(Int(room)) }
        }
        do {
            try file.seek(toOffset: UInt64(seg.current))
            try file.write(contentsOf: chunk)
        } catch {
            fail("Write failed: \(error.localizedDescription)")
            return
        }
        record.segments[i].received += Int64(chunk.count)
        w.bytes += Int64(chunk.count)
        w.lastDataAt = Date()
        retries[i] = 0
        saveState(force: false)
        throttle(chunk.count)
        if record.segments[i].isComplete { completeWorker(w) }
    }

    fileprivate func workerCompleted(_ w: SegmentWorker, _ error: Error?) {
        guard workers[w.index] === w, record.status == .downloading else { return }
        let i = w.index
        workers[i] = nil
        if let failure = w.failure ?? error.map({ $0.localizedDescription }) {
            scheduleRetry(i, failure)
            return
        }
        let seg = record.segments[i]
        if seg.isOpenEnded {
            // Unknown size: the stream ending is the end of the file.
            record.totalSize = seg.received
            record.segments[i].end = seg.received - 1
            finish()
            return
        }
        if !seg.isComplete, let pieceEnd = w.pieceEnd, seg.current > pieceEnd {
            // Paced piece done: wait until the limiter has budget, then fetch the next piece
            // on the same session so the connection is reused.
            w.keepSession = true
            pendingRetry.insert(i)
            let gen = generation
            queue.asyncAfter(deadline: .now() + limiter.waitTime()) { [weak self] in
                guard let self, gen == self.generation, self.record.status == .downloading,
                      !self.record.segments[i].isComplete else {
                    w.stop()
                    self?.queue.async { self?.fillWorkersIfDownloading() }
                    return
                }
                self.pendingRetry.remove(i)
                self.startWorker(i, reusing: w)
            }
            return
        }
        if !seg.isComplete {
            scheduleRetry(i, "Connection closed early")
            return
        }
        segmentFinished()
    }

    private func fillWorkersIfDownloading() {
        if record.status == .downloading { segmentFinished() }
    }

    /// A segment reached its end while its request was still open (it was split, or the server sent extra).
    private func completeWorker(_ w: SegmentWorker) {
        workers[w.index] = nil
        w.stop()
        segmentFinished()
    }

    private func segmentFinished() {
        if allComplete && pendingRetry.isEmpty {
            finish()
        } else {
            fillWorkers()
        }
    }

    private func scheduleRetry(_ i: Int, _ message: String) {
        let n = (retries[i] ?? 0) + 1
        retries[i] = n
        guard n <= Self.maxRetries else {
            fail("\(message) (gave up after \(Self.maxRetries) retries)")
            return
        }
        pendingRetry.insert(i)
        let delay = min(30, pow(2, Double(n - 1)))
        let gen = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.generation, self.record.status == .downloading else { return }
            self.pendingRetry.remove(i)
            if self.workers[i] == nil && !self.record.segments[i].isComplete && self.workers.count < self.connections {
                self.startWorker(i)
            }
            self.fillWorkers()
        }
        fillWorkers()
    }

    private func downgradeToSingleStream() {
        stopAll()
        record.acceptsRanges = false
        record.segments = [Segment(start: 0, end: (record.totalSize ?? 0) - 1)]
        if record.totalSize == nil { record.segments = [Segment(start: 0, end: -1)] }
        try? file?.truncate(atOffset: 0)
        let gen = generation
        queue.async { [weak self] in
            guard let self, gen == self.generation else { return }
            self.fillWorkers()
        }
    }

    /// Accounts for bytes against the global limit. The pacing itself happens per piece in startWorker.
    private func throttle(_ bytes: Int) {
        _ = limiter.consume(bytes)
    }

    // MARK: Finish and failure

    private func finish() {
        stopAll()
        do {
            try file?.synchronize()
        } catch {}
        closeFile()
        let fm = FileManager.default
        let part = record.partPath
        let state = record.statePath
        if record.totalSize == nil { record.totalSize = SegmentMath.downloaded(record.segments) }
        if let attrs = try? fm.attributesOfItem(atPath: part), let size = attrs[.size] as? Int64,
           let expected = record.totalSize, size != expected {
            fail("Size mismatch: expected \(expected) bytes, got \(size)")
            return
        }
        let dir = record.directory
        let finalName = FileNaming.uniqueName(record.fileName) { fm.fileExists(atPath: (dir as NSString).appendingPathComponent($0)) }
        do {
            try fm.moveItem(atPath: part, toPath: (dir as NSString).appendingPathComponent(finalName))
        } catch {
            fail("Could not rename the finished file: \(error.localizedDescription)")
            return
        }
        record.fileName = finalName
        try? fm.removeItem(atPath: state)
        record.status = .completed
        record.completedAt = Date()
        record.errorMessage = nil
    }

    private func fail(_ message: String) {
        stopAll()
        record.status = .failed
        record.errorMessage = message
        saveState(force: true)
        closeFile()
    }

    private func stopAll() {
        for w in workers.values { w.stop() }
        workers.removeAll()
        pendingRetry.removeAll()
    }

    private func closeFile() {
        try? file?.close()
        file = nil
    }

    private func saveState(force: Bool) {
        guard record.probed, record.status != .completed, record.status != .cancelled else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastSave) >= 1 else { return }
        lastSave = now
        guard FileManager.default.fileExists(atPath: record.partPath),
              let data = try? JSONEncoder.iso.encode(record) else { return }
        try? data.write(to: URL(fileURLWithPath: record.statePath), options: .atomic)
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 7 * 24 * 3600
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpMaximumConnectionsPerHost = 2
        return c
    }
}

/// One connection. Each worker owns its own URLSession so it gets its own TCP connection;
/// a shared session would multiplex every range over a single HTTP/2 connection and lose the speed-up.
final class SegmentWorker: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let index: Int
    weak var engine: DownloadEngine?
    private(set) var session: URLSession?
    private(set) var task: URLSessionDataTask?
    var failure: String?
    /// Last byte of the current paced piece (speed limit on), else nil.
    var pieceEnd: Int64?
    /// Set by the engine when the next piece will reuse this session.
    var keepSession = false
    var bytes: Int64 = 0
    var lastDataAt = Date()
    var markBytes: Int64 = 0
    var markTime = Date()

    init(index: Int, engine: DownloadEngine) {
        self.index = index
        self.engine = engine
    }

    func start(_ request: URLRequest, delegateQueue: OperationQueue) {
        keepSession = false
        lastDataAt = Date()
        let s = session ?? URLSession(configuration: DownloadEngine.makeConfiguration(), delegate: self, delegateQueue: delegateQueue)
        session = s
        let t = s.dataTask(with: request)
        task = t
        t.resume()
    }

    func stop() {
        engine = nil
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let ok = engine?.workerResponse(self, response) ?? false
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        engine?.workerReceived(self, data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(RedirectPolicy.request(request, from: task.originalRequest))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        engine?.workerCompleted(self, error)
        if !keepSession { session.finishTasksAndInvalidate() }
    }
}

/// Reads only the response headers of a `Range: bytes=0-0` GET, then cancels.
final class ProbeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let done: (Result<HTTPURLResponse, Error>) -> Void
    private var response: HTTPURLResponse?
    private var reported = false

    init(done: @escaping (Result<HTTPURLResponse, Error>) -> Void) { self.done = done }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(RedirectPolicy.request(request, from: task.originalRequest))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.invalidateAndCancel() }
        guard !reported else { return }
        reported = true
        if let r = response {
            done(.success(r))
        } else {
            done(.failure(error ?? URLError(.badServerResponse)))
        }
    }
}

enum RedirectPolicy {
    /// Keeps the browser's cookies from leaking to a different site on redirect.
    static func request(_ new: URLRequest, from original: URLRequest?) -> URLRequest {
        guard let from = original?.url?.host?.lowercased(), let to = new.url?.host?.lowercased(),
              from != to, !to.hasSuffix("." + from), !from.hasSuffix("." + to) else { return new }
        var r = new
        r.setValue(nil, forHTTPHeaderField: "Cookie")
        return r
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
