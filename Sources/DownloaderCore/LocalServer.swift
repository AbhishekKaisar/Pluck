import Foundation
import Network

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]   // lower-cased names
    public var body: Data
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var contentType = "application/json"

    public init(status: Int, json: Any) {
        self.status = status
        self.body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    var serialised: Data {
        let reason: String = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                              405: "Method Not Allowed", 413: "Payload Too Large", 503: "Service Unavailable"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// Minimal HTTP/1.1 server bound to 127.0.0.1. One request per connection.
public final class LocalServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest, @escaping @Sendable (HTTPResponse) -> Void) -> Void

    public static let defaultPort: UInt16 = 6801
    public static let portRange: ClosedRange<UInt16> = 6801...6820
    static let maxRequestBytes = 1 << 20

    private let queue = DispatchQueue(label: "macdownloader.server")
    private let handler: Handler
    private var listener: NWListener?
    public private(set) var port: UInt16?
    public var onReady: (@Sendable (UInt16) -> Void)?
    public var onFailure: (@Sendable (String) -> Void)?

    public init(handler: @escaping Handler) { self.handler = handler }

    public func start(preferredPort: UInt16 = LocalServer.defaultPort) {
        queue.async { self.tryListen(on: preferredPort) }
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
        }
    }

    private func tryListen(on port: UInt16) {
        guard LocalServer.portRange.contains(port) else {
            onFailure?("No free port in \(LocalServer.portRange)")
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        params.acceptLocalOnly = true
        let l: NWListener
        do {
            l = try NWListener(using: params)
        } catch {
            tryListen(on: port + 1)
            return
        }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = port
                self.onReady?(port)
            case .failed:
                l?.cancel()
                if self.listener === l { self.listener = nil }
                self.port = nil
                self.tryListen(on: port + 1)
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener = l
        l.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
        // Drop slow or idle clients.
        queue.asyncAfter(deadline: .now() + 15) { [weak connection] in connection?.cancel() }
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || a == .loopback
        case .name(let n, _): return n == "localhost" || n == "127.0.0.1" || n == "::1"
        @unknown default: return false
        }
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > Self.maxRequestBytes {
                self.send(c, HTTPResponse(status: 413, json: ["error": "too large"]))
                return
            }
            switch Self.parse(buf) {
            case .complete(let req):
                self.handler(req) { resp in self.queue.async { self.send(c, resp) } }
            case .invalid:
                self.send(c, HTTPResponse(status: 400, json: ["error": "bad request"]))
            case .needMore:
                if isComplete || error != nil { c.cancel() } else { self.receive(c, buffer: buf) }
            }
        }
    }

    private func send(_ c: NWConnection, _ r: HTTPResponse) {
        c.send(content: r.serialised, completion: .contentProcessed { _ in c.cancel() })
    }

    enum ParseResult { case needMore, invalid, complete(HTTPRequest) }

    static func parse(_ data: Data) -> ParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 16384 ? .invalid : .needMore
        }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxRequestBytes else { return .invalid }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return .needMore }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))
        var path = String(first[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        return .complete(HTTPRequest(method: String(first[0]).uppercased(), path: path, headers: headers, body: body))
    }
}

/// The JSON API the browser extension talks to.
public struct AddRequest: Codable, Sendable {
    public var url: String
    public var filename: String?
    public var referrer: String?
    public var cookies: String?
    public var userAgent: String?
    public var fileSize: Int64?
}

public enum APIRouter {
    public enum Command: Sendable {
        case add(AddRequest)
        case list
        case control(id: UUID, action: String)
    }

    /// Validates the request and returns either an immediate response or a command for the app to run.
    public enum Routed: Sendable {
        case respond(HTTPResponse)
        case run(Command)
    }

    public static func route(_ req: HTTPRequest, token: String) -> Routed {
        // Web pages must never drive the app; only our extension (or curl, with no Origin) may.
        if let origin = req.headers["origin"], !origin.isEmpty,
           !(origin.hasPrefix("chrome-extension://") || origin.hasPrefix("moz-extension://") || origin.hasPrefix("safari-web-extension://")) {
            return .respond(HTTPResponse(status: 403, json: ["error": "origin not allowed"]))
        }
        if req.path == "/ping" {
            return .respond(HTTPResponse(status: 200, json: ["app": "MacDownloader", "version": AppInfo.version]))
        }
        guard authorised(req, token: token) else {
            return .respond(HTTPResponse(status: 401, json: ["error": "missing or wrong token"]))
        }
        switch (req.method, req.path) {
        case ("POST", "/add"):
            guard let add = try? JSONDecoder().decode(AddRequest.self, from: req.body),
                  let url = URL(string: add.url), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host != nil else {
                return .respond(HTTPResponse(status: 400, json: ["error": "need a JSON body with an http(s) url"]))
            }
            return .run(.add(add))
        case ("GET", "/list"):
            return .run(.list)
        case ("POST", "/control"):
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let idString = obj["id"] as? String, let id = UUID(uuidString: idString),
                  let action = obj["action"] as? String, ["pause", "resume", "cancel"].contains(action) else {
                return .respond(HTTPResponse(status: 400, json: ["error": "need {id, action: pause|resume|cancel}"]))
            }
            return .run(.control(id: id, action: action))
        default:
            return .respond(HTTPResponse(status: 404, json: ["error": "not found"]))
        }
    }

    static func authorised(_ req: HTTPRequest, token: String) -> Bool {
        var supplied = req.headers["x-macdownloader-token"] ?? ""
        if supplied.isEmpty, let auth = req.headers["authorization"], auth.lowercased().hasPrefix("bearer ") {
            supplied = String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return constantTimeEquals(supplied, token)
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !y.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
