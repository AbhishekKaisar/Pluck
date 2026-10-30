import Foundation

/// What a quick `Range: bytes=0-0` request says about a link, for the Add download sheet.
public struct ProbeResult: Equatable, Sendable {
    public var fileName: String
    public var totalSize: Int64?
    public var acceptsRanges: Bool

    public init(fileName: String, totalSize: Int64?, acceptsRanges: Bool) {
        self.fileName = fileName
        self.totalSize = totalSize
        self.acceptsRanges = acceptsRanges
    }
}

public enum Prober {
    public enum Failure: Error, Equatable, Sendable {
        case unreachable(String)
        case http(Int)

        public var message: String {
            switch self {
            case .unreachable(let m): return "Could not reach the server: \(m)"
            case .http(let code): return "Server answered HTTP \(code)"
            }
        }
    }

    /// Reads only the response headers, then cancels. Uses the same rules as the engine's probe.
    public static func probe(_ url: URL, headers: RequestHeaders = RequestHeaders()) async -> Result<ProbeResult, Failure> {
        var req = URLRequest(url: url, timeoutInterval: 20)
        headers.apply(to: &req)
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let result: Result<HTTPURLResponse, Error> = await withCheckedContinuation { cont in
            let delegate = ProbeDelegate { cont.resume(returning: $0) }
            let session = URLSession(configuration: DownloadEngine.makeConfiguration(), delegate: delegate, delegateQueue: nil)
            session.dataTask(with: req).resume()
        }
        switch result {
        case .failure(let error):
            return .failure(.unreachable(error.localizedDescription))
        case .success(let http):
            if http.statusCode >= 400 { return .failure(.http(http.statusCode)) }
            return .success(interpret(http, originalURL: url))
        }
    }

    static func interpret(_ http: HTTPURLResponse, originalURL: URL) -> ProbeResult {
        var size: Int64?
        var ranges = false
        if http.statusCode == 206, let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let parsed = SegmentMath.parseContentRange(cr) {
            size = parsed.total
            ranges = parsed.total != nil
        } else if http.expectedContentLength > 0 {
            size = http.expectedContentLength
        }
        let name = FileNaming.chooseName(suggested: nil, contentDisposition: http.value(forHTTPHeaderField: "Content-Disposition"),
                                         finalURL: http.url, originalURL: originalURL, mimeType: http.mimeType)
        return ProbeResult(fileName: name, totalSize: size, acceptsRanges: ranges)
    }
}
