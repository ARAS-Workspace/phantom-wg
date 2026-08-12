#if DEBUG
import Foundation

/// Live pass over the PhantomTunnel extension's XPC surface, driven as
/// the app identity against one of the user-validated door configs.
/// One class, two catalog registrations (standalone / ghost), so every
/// claim is proven under both layer shapes.
///
/// Claim discipline: mechanical claims (our code's promises) FAIL when
/// broken whatever the server does; environment claims (a server that
/// must answer) SKIP honestly when the answer never comes. The real
/// endpoints behind the door configs owe us nothing — a silent-server
/// day still seals the machinery.
final class PhantomTunnelWorkflow: TestWorkflow {

    enum Mode { case standalone, ghost }
    private let mode: Mode

    init(_ mode: Mode) {
        self.mode = mode
        super.init()
    }

    override var displayName: String {
        mode == .ghost ? "Test PhantomTunnel (Ghost)" : "Test PhantomTunnel (Standalone)"
    }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Activate", activate),
            WorkflowStep("XPC 0: Handshake Proven", handshakeProven),
            WorkflowStep("XPC 0 x Vault: Running Config Matches Vault", runningKeyMatchesVault),
            WorkflowStep("XPC 1: Log Buffer Streams", logBufferStreams),
            WorkflowStep("XPC 2: Flush Round-Trip", flushRoundTrip),
            WorkflowStep("XPC 3: Layer Reset In Place", layerResetInPlace),
            WorkflowStep("XPC 3 x2: Concurrent Reset Converges", concurrentReset),
            WorkflowStep("Negative: Empty and Unknown Opcode Rejected", negativeContract),
            WorkflowStep("Deactivate + Disarm Sweep", deactivateAndSweep),
        ]
    }

    private var configName: String {
        mode == .ghost ? TestContext.ghostName : TestContext.wireGuardName
    }
    private var target: TunnelContainer? { tunnel(named: configName) }

    private var sessionUp = false
    private var lastHandshakeTs: Int64 = 0
    private var preFlushBytes = 0

    // MARK: - Steps

    private func activate() async {
        guard let t = target else {
            fail("\(configName): not found")
            return
        }
        if t.status != .inactive {
            log("precondition: \(configName) is \(t.status) — grounding to inactive first", .warn)
            tunnels.startDeactivation(of: t)
            guard await awaitStatus(t, is: .inactive, within: 20) else {
                fail("could not ground to inactive")
                return
            }
        }
        // This is the user's own door config, so the net grounds it —
        // it never removes it. `deactivateAndSweep` owns the normal
        // path and earns the armed-count verdict; the steps between
        // here and there carry cancel-returns that would otherwise
        // leave a live session with an armed recovery rule behind.
        onTeardown("door config left running") { [weak self] in
            guard let self else { return }
            let armedNow = self.tunnels.tunnels.filter(\.isActivateOnDemandEnabled).count
            guard let leftover = self.tunnel(named: self.configName) else {
                self.log("teardown: \(self.configName) not in the list, armed-count=\(armedNow)",
                         armedNow == 0 ? .info : .warn)
                return
            }
            guard leftover.status != .inactive else {
                // Inactive is not the same as disarmed: a rung that
                // failed its save after arming leaves exactly that
                // pair, and grounding would skip it. Same answer as
                // the RecoverySwitch net gives the same residue.
                guard armedNow > 0 else {
                    self.log("teardown: \(self.configName) already grounded, armed-count=0")
                    return
                }
                await self.tunnels.disarmAllRecovery()
                let after = self.tunnels.tunnels.filter(\.isActivateOnDemandEnabled).count
                self.log("teardown: \(self.configName) grounded but armed — swept, armed-count=\(after)",
                         after == 0 ? .warn : .error)
                return
            }
            self.tunnels.startDeactivation(of: leftover)
            let grounded = await self.awaitStatus(leftover, is: .inactive, within: 15)
            let armed = self.tunnels.tunnels.filter(\.isActivateOnDemandEnabled).count
            self.log("teardown: grounded \(self.configName)=\(grounded), armed-count=\(armed)", .warn)
        }
        tunnels.startActivation(of: t)
        // The ladder's own budget, not a round number: a rung that
        // retries eight times at five seconds is still a correct
        // activation at t=38s, and 30 would have called it a failure.
        if await awaitStatus(t, is: .active, within: activationBudget) {
            sessionUp = true
            log("session up — mode=\(mode == .ghost ? "ghost" : "standalone")", .ok)
            // The identity projection must agree with the mode the door
            // config was imported as, and activation must arm recovery
            // on THIS tunnel alone — the other pole of the armed<=1
            // invariant the deactivate step checks at zero.
            check(t.isGhost == (mode == .ghost), "identity projection agrees — isGhost=\(t.isGhost)")
            let armed = tunnels.tunnels.filter(\.isActivateOnDemandEnabled)
            check(armed.count == 1 && armed.first === t,
                  "recovery armed on this tunnel only — armed-count=\(armed.count)")
        } else {
            fail("no active within \(Int(activationBudget))s — lastActivationError=\(t.lastActivationError.map { String(describing: $0) } ?? "nil")")
        }
    }

    private func handshakeProven() async {
        guard sessionUp, let t = target else {
            skip("session not up")
            return
        }
        var answered = false
        let start = Date()
        while Date().timeIntervalSince(start) < 20 {
            if Task.isCancelled { return }
            switch await providerMessage(t, [0]) {
            case .data(let d):
                answered = true
                let stats = StatsFormatter.parse(String(data: d, encoding: .utf8) ?? "")
                if stats.lastHandshakeTimestamp > 0 {
                    lastHandshakeTs = stats.lastHandshakeTimestamp
                    log("handshake proven — last_handshake_time_sec=\(stats.lastHandshakeTimestamp) rx=\(stats.rxBytes) tx=\(stats.txBytes)", .ok)
                    return
                }
            case .empty:
                answered = true
            case .unanswered:
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
        if answered {
            skip("environment: no handshake within 20s — server did not answer")
        } else {
            fail("XPC stats channel mute for 20s while status=active")
        }
    }

    /// The family's heart: the peer key running on the wire (uapi, hex)
    /// must be the peer key of the vault payload (base64). Proves the
    /// custody chain end to end — the config the user imported IS the
    /// config the extension runs. Needs no handshake, only a session.
    private func runningKeyMatchesVault() async {
        guard sessionUp, let t = target else {
            skip("session not up")
            return
        }
        guard case .config(let cfg) = await vault.read(id: t.id) else {
            fail("vault did not return the config")
            return
        }
        guard let keyData = Data(base64Encoded: cfg.wireguard.peer.publicKey.base64) else {
            fail("vault peer key is not base64")
            return
        }
        let expectedHex = keyData.map { String(format: "%02x", $0) }.joined()
        guard case .data(let d) = await providerMessage(t, [0]),
              let uapi = String(data: d, encoding: .utf8) else {
            fail("no uapi answer for the key comparison")
            return
        }
        let runningKeys = uapi.split(separator: "\n")
            .filter { $0.hasPrefix("public_key=") }
            .map { String($0.dropFirst("public_key=".count)) }
        check(runningKeys.contains(expectedHex),
              "running peer key matches the vault payload (\(expectedHex.prefix(16))…, \(runningKeys.count) peer(s))")
    }

    private func logBufferStreams() async {
        guard sessionUp, let t = target else {
            skip("session not up")
            return
        }
        switch await providerMessage(t, [1]) {
        case .data(let d):
            // The buffer arrives as one serialized blob, so byte size
            // is the honest measure — line counting reported "1 entry"
            // for thousands of bytes on the first live run.
            preFlushBytes = d.count
            check(!d.isEmpty, "log buffer streams — \(d.count) bytes")
        case .empty:
            fail("log request answered empty")
        case .unanswered:
            fail("log request unanswered (5s)")
        }
    }

    private func flushRoundTrip() async {
        guard sessionUp, let t = target else {
            skip("session not up")
            return
        }
        let echo = await providerMessage(t, [2])
        check(echo == .data(Data([2])), "flush acknowledged — reply=\(echo.label)")
        switch await providerMessage(t, [1]) {
        case .data(let d):
            // No `|| preFlushBytes == 0` escape hatch. That clause
            // could only ever be true when the previous step had
            // already failed to read a buffer, and it turned this step
            // green precisely then — a flush proven against a log
            // surface that was mute.
            check(preFlushBytes > 0, "a pre-flush measurement exists to compare against (\(preFlushBytes) bytes)")
            check(d.count < preFlushBytes, "buffer after flush: \(preFlushBytes) → \(d.count) bytes")
        case .empty:
            // An empty buffer after a flush is the flush working, but
            // only if there was something to flush.
            check(preFlushBytes > 0, "buffer empty after flush, from \(preFlushBytes) bytes")
        case .unanswered:
            fail("buffer read after flush unanswered")
        }
    }

    private func layerResetInPlace() async {
        guard sessionUp, let t = target else {
            skip("session not up")
            return
        }
        // Three outcomes told apart, because they are three different
        // facts: nil is the 15s ceiling (a mute extension), false is
        // the reset call throwing (the old `try?`-only shape folded
        // this into "returned"), true is a clean return.
        let outcome: Bool? = await race(15) {
            (try? await self.tunnels.resetConnection(of: t)) != nil
        }
        guard let returned = outcome else {
            fail("reset did not return within 15s — extension may be wedged")
            return
        }
        guard returned else {
            fail("reset call threw — the send failed before the extension could act")
            return
        }
        // Only what is known at this line: the call came back. Whether
        // the layer was rebuilt is what the rest of the step measures.
        log("reset call returned", .ok)
        guard await awaitStatus(t, is: .active, within: 30) else {
            fail("no return to active after reset")
            return
        }
        guard lastHandshakeTs > 0 else {
            // Without a baseline from XPC 0 the rebuild cannot be
            // proven, only the return-to-active above — and a step
            // that proved half its name reports that as a skip, not
            // as a quiet pass.
            skip("no handshake baseline from XPC 0 — rebuild proof not applicable")
            return
        }
        let start = Date()
        while Date().timeIntervalSince(start) < 30 {
            if Task.isCancelled { return }
            if case .data(let d) = await providerMessage(t, [0]) {
                let stats = StatsFormatter.parse(String(data: d, encoding: .utf8) ?? "")
                if stats.lastHandshakeTimestamp > lastHandshakeTs {
                    log("fresh handshake after reset — \(stats.lastHandshakeTimestamp) > \(lastHandshakeTs)", .ok)
                    return
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        // The fresh handshake needs the server to answer a second time,
        // so it is the same environment class as Handshake Proven — a
        // live run proved it: ghost (TCP transport) re-handshakes while
        // standalone (plain UDP through a router) can stall. The
        // mechanical core of the reset (echo + return to active) was
        // already checked above.
        skip("environment: layer rebuilt, no fresh handshake within 30s")
    }

    /// Two resets fired without waiting between them. The extension
    /// opens a fresh Task per opcode-3 message with no in-flight guard,
    /// so their stop/start phases can interleave and fight over the
    /// `reasserting` flag. Whatever the ordering, the tunnel must
    /// converge to one consistent live state — never left down.
    private func concurrentReset() async {
        guard sessionUp, let t = target else {
            skip("session not up")
            return
        }
        // Same three-way contract as the single reset above: nil is
        // the ceiling, false is a throw, true is a clean return.
        async let first: Bool? = race(20) { (try? await self.tunnels.resetConnection(of: t)) != nil }
        async let second: Bool? = race(20) { (try? await self.tunnels.resetConnection(of: t)) != nil }
        let (a, b) = await (first, second)
        guard let ra = a, let rb = b else {
            fail("a concurrent reset did not return within 20s — wedge")
            return
        }
        guard ra, rb else {
            fail("a concurrent reset threw (first=\(ra) second=\(rb))")
            return
        }
        log("both concurrent resets returned without throwing", .ok)
        // The claim this step can actually earn: overlapping resets
        // did not leave the tunnel down. Their internal ordering is
        // the extension's business and is not observable from here.
        check(await awaitStatus(t, is: .active, within: 30),
              "tunnel is live after overlapping resets — status=\(t.status)")
    }

    private func negativeContract() async {
        guard sessionUp, let t = target else {
            skip("session not up")
            return
        }
        let empty = await providerMessage(t, [])
        check(empty == .empty, "empty message rejected — reply=\(empty.label)")
        let unknown = await providerMessage(t, [9])
        check(unknown == .empty, "unknown opcode 9 rejected — reply=\(unknown.label)")
    }

    private func deactivateAndSweep() async {
        guard let t = target else {
            skip("tunnel not found")
            return
        }
        if t.status == .inactive {
            log("already inactive")
        } else {
            tunnels.startDeactivation(of: t)
            check(await awaitStatus(t, is: .inactive, within: 20), "deactivation landed — status=inactive")
        }
        let armed = tunnels.tunnels.filter(\.isActivateOnDemandEnabled)
        check(armed.isEmpty, "armed-count=\(armed.count) across \(tunnels.tunnels.count) tunnels")
    }
}
#endif
