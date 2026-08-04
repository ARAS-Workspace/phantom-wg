import Foundation
import AppKit
import Observation
import os.log

/// Second lock in the app's readiness chain, after the extension
/// gate: **PhantomTunnel** and **TunnelVault** exist together or not
/// at all. A tunnel cannot start without its payload, so a vault that
/// cannot be reached makes the NetworkExtension list mere residue —
/// this session refuses to present residue as a working app. The
/// probe's XPC connection is also what makes launchd wake the
/// extension, so holding the lock keeps PhantomTunnel alive alongside
/// the app.
///
/// The lock is authoritative at entry and re-verifies on demand. A
/// running tunnel lives independently of the daemon — the provider
/// reads the vault in-process — so a mid-session hiccup never tears
/// the tunnel list down; trouble resurfaces here only through the
/// gate's own re-checks.
@Observable
@MainActor
final class TunnelVaultSession {

    enum State: Equatable {
        /// Probe in flight — the extension may still be spawning.
        case connecting
        /// Chain proven end to end; the tunnel UI may exist.
        case ready
        /// The extension never answered.
        case silent
        /// The extension answered but the System keychain did not.
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

    /// `state` is injectable so previews can render every gate story.
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

    /// Entry probe. Patient with silence — the first connection races
    /// launchd's cold spawn — but a definite "door failed" answer is
    /// believed the first time: it is an answer, not an absence.
    func establish() async {
        guard !isProbing else { return }
        isProbing = true
        defer { isProbing = false }

        state = .connecting

        for attempt in 1...Self.attempts {
            switch await vault.ping() {
            case .ready(let payloads):
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

    /// The gate's "check again".
    func checkAgain() {
        Task { await establish() }
    }

    /// The extension gate dropping below ready voids the proof: a
    /// reinstalled extension is a cold one, and the next entry must
    /// probe again rather than trust a stale `.ready`.
    func invalidate() {
        state = .connecting
    }

    private static let attempts = 3

    /// Foreground return re-probes a broken chain — the catch-all
    /// mirror of `TunnelsManager`'s trigger. A ready session is left
    /// alone; the data paths carry their own guards.
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
