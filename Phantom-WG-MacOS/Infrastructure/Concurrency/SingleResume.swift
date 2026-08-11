import Synchronization

/// Guards a continuation that several finishers may reach — an XPC
/// error handler racing its reply block, or a producer racing a
/// deadline. The first finish wins, the rest are dropped; resuming a
/// `CheckedContinuation` twice traps, so the one-shot flag lives
/// inside a `Mutex` and the type is `Sendable` by compiler proof
/// rather than by annotation. Shared by the vault client's transport
/// races, the tunnels manager's `bounded` deadline, and the DEBUG
/// harness — one implementation, no drifting mirrors.
final class SingleResume<T: Sendable>: Sendable {
    private let continuation: CheckedContinuation<T, Never>
    private let done = Mutex(false)

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    /// `true` when this call is the one that resumed — lets a
    /// timeout branch tell "I won" from "I was already beaten".
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
