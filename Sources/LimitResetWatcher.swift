import Foundation

/// One usage window being watched, e.g. "Claude 5h" for one account.
struct WatchedLimit: Equatable {
    let key: String
    let title: String
    let remaining: Int
}

/// Detects a limit that was nearly used up and has since refilled, so the app can celebrate it.
/// Behaviour follows TokenTracker's "after you were near it" rule: the lowest remaining value seen since
/// the last reset must be at or below `nearThreshold`, and the window must have refilled by `refillJump`.
struct LimitResetWatcher {
    static let nearThreshold = 20
    static let refillJump = 50

    private var lowest: [String: Int] = [:]

    mutating func observe(_ limits: [WatchedLimit]) -> [WatchedLimit] {
        var resets: [WatchedLimit] = []
        for limit in limits {
            let remaining = max(0, min(100, limit.remaining))
            guard let low = lowest[limit.key] else {
                lowest[limit.key] = remaining
                continue
            }
            if low <= Self.nearThreshold, remaining - low >= Self.refillJump {
                resets.append(limit)
                lowest[limit.key] = remaining
            } else {
                lowest[limit.key] = min(low, remaining)
            }
        }
        return resets
    }
}
