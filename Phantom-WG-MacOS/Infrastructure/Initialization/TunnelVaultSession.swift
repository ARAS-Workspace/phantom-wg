import Foundation
import AppKit
import Observation
import os.log

@Observable
@MainActor
final class TunnelVaultSession {

    enum State: Equatable {
        case connecting
        case ready
        case silent
        case doorFailed
    }

    private(set) var state: State

    @ObservationIgnored private let vault: TunnelVaultClient
    @ObservationIgnored private var foregroundToken: AnyObject?
    @ObservationIgnored private var isProbing = false

    @ObservationIgnored private let log = OSLog(
        subsystem: "com.remrearas.Phantom-WG-MacOS",
        category: "vault-session"
    )

    init(vault: TunnelVaultClient, state: State = .connecting) {
        self.vault = vault
        self.state = state
        startObservingForeground()
    }

    deinit {
        if let token = foregroundToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func establish() async {
        guard !isProbing else { return }
        isProbing = true
        defer { isProbing = false }

        state = .connecting

        for attempt in 1...Self.attempts {
            switch await vault.ping() {
            case .ready(let payloads, _):
                os_log("session ready — %{public}d payload(s) in custody",
                       log: log, type: .default, payloads)
                state = .ready
                return
            case .doorFailed:
                os_log("session refused — the extension answered but the vault door FAILED",
                       log: log, type: .error)
                state = .doorFailed
                return
            case .unreachable where attempt < Self.attempts:
                try? await Task.sleep(for: .milliseconds(600 * attempt))
            case .unreachable:
                os_log("session silent — no answer after %{public}d attempt(s)",
                       log: log, type: .error, Self.attempts)
                state = .silent
            }
        }
    }

    func checkAgain() {
        Task { await establish() }
    }

    func invalidate() {
        state = .connecting
    }

    private static let attempts = 3

    private func startObservingForeground() {
        foregroundToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .silent || self.state == .doorFailed else { return }
                await self.establish()
            }
        }
    }
}
