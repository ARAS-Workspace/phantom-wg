import Synchronization

final class SingleResume<T: Sendable>: Sendable {
    private let continuation: CheckedContinuation<T, Never>
    private let done = Mutex(false)

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
