import Foundation

/// A byte range of the target file, fetched by one connection.
/// `end` is inclusive; `end == -1` means "until the server closes" (unknown size).
public struct Segment: Codable, Equatable, Sendable {
    public var start: Int64
    public var end: Int64
    public var received: Int64

    public init(start: Int64, end: Int64, received: Int64 = 0) {
        self.start = start
        self.end = end
        self.received = received
    }

    /// Next byte offset to write.
    public var current: Int64 { start + received }

    public var isOpenEnded: Bool { end < 0 }

    /// Bytes still to fetch. Open-ended segments report `Int64.max`.
    public var remaining: Int64 { isOpenEnded ? Int64.max : max(0, end - current + 1) }

    public var isComplete: Bool { !isOpenEnded && current > end }
}

public enum SegmentMath {
    /// Smallest piece worth its own connection.
    public static let defaultMinSegment: Int64 = 512 * 1024

    /// Most connections one download may open.
    public static let maxConnections = 32

    /// Splits a file of `totalSize` bytes into up to `connections` contiguous segments.
    /// Returns a single open-ended segment when the size is unknown.
    public static func plan(totalSize: Int64?, connections: Int, minSegment: Int64 = defaultMinSegment) -> [Segment] {
        guard let size = totalSize, size > 0 else { return [Segment(start: 0, end: -1)] }
        let byMin = max(1, size / max(1, minSegment))
        let count = Int64(max(1, min(connections, maxConnections, Int(min(byMin, Int64(maxConnections))))))
        let base = size / count
        var segments: [Segment] = []
        var start: Int64 = 0
        for i in 0..<count {
            let end = (i == count - 1) ? size - 1 : start + base - 1
            segments.append(Segment(start: start, end: end))
            start = end + 1
        }
        return segments
    }

    /// The `Range` header value for the rest of a segment, or nil when no header is needed
    /// (a fresh open-ended segment starting at 0).
    public static func rangeHeader(for segment: Segment) -> String? {
        if segment.isOpenEnded {
            return segment.current == 0 ? nil : "bytes=\(segment.current)-"
        }
        return "bytes=\(segment.current)-\(segment.end)"
    }

    /// Dynamic splitting, as IDM does: cut the incomplete segment with the most bytes left in half.
    /// The original keeps the first half (its running request is clamped to the new end);
    /// the second half is appended as a new segment. Returns the index of the new segment,
    /// or nil when nothing is large enough to be worth splitting.
    @discardableResult
    public static func splitLargest(_ segments: inout [Segment], minSegment: Int64 = defaultMinSegment, excluding: Set<Int> = []) -> Int? {
        var best: Int?
        var bestRemaining: Int64 = 0
        for (i, s) in segments.enumerated() where !s.isOpenEnded && !s.isComplete && !excluding.contains(i) {
            if s.remaining > bestRemaining {
                best = i
                bestRemaining = s.remaining
            }
        }
        guard let index = best, bestRemaining >= 2 * minSegment else { return nil }
        let old = segments[index]
        let newStart = old.current + bestRemaining / 2
        segments[index].end = newStart - 1
        segments.append(Segment(start: newStart, end: old.end))
        return segments.count - 1
    }

    /// Parses `Content-Range: bytes 0-0/12345`. Total is nil for `*`.
    public static func parseContentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64?)? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes") else { return nil }
        let rest = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let range = parts[0].split(separator: "-", maxSplits: 1).map { String($0) }
        guard range.count == 2, let s = Int64(range[0]), let e = Int64(range[1]), e >= s else { return nil }
        let total = parts[1] == "*" ? nil : Int64(parts[1])
        return (s, e, total)
    }

    /// Bytes already on disk across all segments.
    public static func downloaded(_ segments: [Segment]) -> Int64 {
        segments.reduce(0) { $0 + $1.received }
    }
}
