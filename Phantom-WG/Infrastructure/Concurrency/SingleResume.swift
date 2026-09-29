import os

/// A continuation that can be resumed exactly once, whoever gets there
/// first. It exists for the one shape this app cannot express safely
/// otherwise: a reply and a deadline racing for the same continuation,
/// where resuming twice is a crash and resuming never is a hang.
///
/// The losing racer is not cancelled and not waited on — it simply
/// finds the slot taken and its value is dropped, so a late answer
/// never feeds a decision that was already made without it.
///
/// The macOS twin of this type is built on `Synchronization.Mutex`;
/// that is iOS 18, and this target deploys to iOS 17, so the same
/// once-only guarantee is taken from `OSAllocatedUnfairLock` instead.
final class SingleResume<T: Sendable>: Sendable {
    private let continuation: CheckedContinuation<T, Never>
    private let done = OSAllocatedUnfairLock(initialState: false)

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func finish(_ value: T) -> Bool {
        let first = done.withLock { done -> Bool in
            guard !done else { return false }
            done = true
            return true
        }
        if first { continuation.resume(returning: value) }
        return first
    }
}
