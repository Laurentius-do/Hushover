import Foundation

/// Exponential backoff for retrying a failed operation: 5 s, 10 s, 20 s … at most 5 min.
struct Backoff: Equatable {
    static let initialDelay: TimeInterval = 5
    static let maximumDelay: TimeInterval = 300

    private(set) var failures = 0
    private(set) var retryAt: TimeInterval = 0

    mutating func recordFailure(at now: TimeInterval) {
        failures += 1
        let delay = Self.initialDelay * pow(2, Double(failures - 1))
        retryAt = now + min(delay, Self.maximumDelay)
    }

    func canRetry(at now: TimeInterval) -> Bool {
        now >= retryAt
    }
}
