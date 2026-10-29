import Foundation

/// Global token bucket shared by every download. 0 bytes per second means unlimited.
public final class SpeedLimiter: @unchecked Sendable {
    public static let shared = SpeedLimiter()

    private let lock = NSLock()
    private var rate: Double = 0
    private var tokens: Double = 0
    private var last = Date()

    public init() {}

    public var bytesPerSecond: Int64 {
        get { lock.withLock { Int64(rate) } }
        set {
            lock.withLock {
                rate = Double(max(0, newValue))
                tokens = rate / 4
                last = Date()
            }
        }
    }

    /// Seconds until the bucket is back to zero (0 when there is budget or no limit).
    public func waitTime() -> TimeInterval {
        lock.withLock {
            guard rate > 0 else { return 0 }
            let projected = min(rate / 4, tokens + Date().timeIntervalSince(last) * rate)
            return projected < 0 ? -projected / rate : 0
        }
    }

    /// Records `bytes` received and returns how long the caller should hold off (0 when under budget).
    public func consume(_ bytes: Int) -> TimeInterval {
        lock.withLock {
            guard rate > 0 else { return 0 }
            let now = Date()
            tokens = min(rate / 4, tokens + now.timeIntervalSince(last) * rate)
            last = now
            tokens -= Double(bytes)
            return tokens < 0 ? -tokens / rate : 0
        }
    }
}

/// Bytes-over-time window for live speed.
public struct SpeedMeter: Sendable {
    private var samples: [(Date, Int64)] = []
    public let window: TimeInterval

    public init(window: TimeInterval = 4) { self.window = window }

    public mutating func add(bytes: Int64, at time: Date = Date()) {
        samples.append((time, bytes))
        while let first = samples.first, time.timeIntervalSince(first.0) > window, samples.count > 2 {
            samples.removeFirst()
        }
    }

    public mutating func reset() { samples.removeAll() }

    /// Bytes per second across the window.
    public var speed: Double {
        guard let a = samples.first, let b = samples.last else { return 0 }
        let dt = b.0.timeIntervalSince(a.0)
        guard dt > 0.2 else { return 0 }
        return max(0, Double(b.1 - a.1) / dt)
    }
}
