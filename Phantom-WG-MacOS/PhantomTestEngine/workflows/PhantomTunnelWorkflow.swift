#if DEBUG
import Foundation

/// What a call to `resetConnection(of:)` did, with the refusal's own
/// sentence carried out of the closure — `race` hands back a value,
/// not a thrown error, and the reason is the half worth reporting.
private enum ResetCall: Sendable {
    case returned
    case refused(String)
}

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
            WorkflowStep("XPC 3: The Reply Names The Outcome", resetReplyNamesOutcome),
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
        // facts: nil is the 15s ceiling (a mute extension), a throw is
        // the wrapper refusing (the old `try?`-only shape folded this
        // into "returned"), a plain return is a clean one.
        //
        // The throw's REASON is carried out now. It used to be
        // reported as "the send failed before the extension could
        // act", which was the only way the wrapper could throw when
        // that line was written. It is not any more: the wrapper also
        // throws when the extension answers that the layer did NOT
        // come back, and when nothing answers inside its own budget.
        // Reporting any of those as a failed send would name the
        // wrong half of the stack to whoever reads the run.
        let outcome: ResetCall? = await race(15) {
            do {
                try await self.tunnels.resetConnection(of: t)
                return .returned
            } catch {
                return .refused(error.localizedDescription)
            }
        }
        guard let outcome else {
            fail("reset did not return within 15s — extension may be wedged")
            return
        }
        if case .refused(let why) = outcome {
            fail("the reset wrapper refused rather than rebuilding the layer — \(why)")
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

    /// The outcome byte, read off the DEPLOYED extension rather than
    /// off a fake — which is the half a driven rig cannot prove. The
    /// step above measures whether the layer came back; this one
    /// measures whether the extension SAID SO, because for as long as
    /// opcode 3 answered with a single byte, "the layer came back"
    /// and "the reset ended" were the same reply and three of the
    /// four endings were failures wearing it.
    ///
    /// Sent raw, not through `resetConnection(of:)`: the wrapper
    /// consumes the bytes and hands back a verdict, so going through
    /// it would test the app's reading of the reply and never the
    /// reply itself.
    private func resetReplyNamesOutcome() async {
        guard sessionUp, let t = target else {
            skip("session not up")
            return
        }
        // Wider than the default: this really does rebuild the layer,
        // and the extension answers only once the sequence is done.
        guard case .data(let reply) = await providerMessage(t, [3], timeout: 20) else {
            fail("opcode 3 did not answer inside 20s — the layer reset is the one message that does real work before replying")
            return
        }
        check(reply.count == 2, "the reply carries an outcome beside the opcode — bytes=\(reply.count), expected 2")
        guard reply.count == 2 else { return }
        check(reply[reply.startIndex] == 3,
              "and its first byte still names the message it answers, so nothing already on the wire changed meaning — \(reply[reply.startIndex]), expected 3")
        guard let outcome = TunnelResetReply.read(reply) else {
            fail("the outcome byte is not one this app has a case for — raw=\(reply[reply.startIndex + 1])")
            return
        }
        check(outcome == .rebuilt, "a live layer answers rebuilt — \(outcome)")
        // The reset was real. Leave the tunnel where the next step
        // expects to find it rather than mid-reassert.
        guard await awaitStatus(t, is: .active, within: 30) else {
            fail("the layer did not come back to active after the raw reset — status=\(t.status)")
            return
        }
    }

    /// Two resets fired without waiting between them. The extension
    /// serializes them now: a second opcode-3 arriving mid-rebuild
    /// JOINS the one in flight rather than driving the adapter a
    /// second time. Whatever the ordering, the tunnel must converge to
    /// one consistent live state — never left down — and neither
    /// caller may be told the layer is down while it is up.
    ///
    /// That last clause is what a live run bought. Before the outcome
    /// byte, both calls returned whatever happened, so this step's
    /// throw check could not fail and the race underneath it was
    /// invisible. The first run with the byte turned it red in BOTH
    /// modes: `WireGuardAdapter` serializes its own bodies on one
    /// queue and its `start` opens with `guard case .stopped`, so the
    /// second start was refused `.invalidState` — "already running" —
    /// which this extension then reported as a failed adapter.
    private func concurrentReset() async {
        guard sessionUp, let t = target else {
            skip("session not up")
            return
        }
        // Same three-way contract as the single reset above: nil is
        // the ceiling, a refusal is a throw, true is a clean return.
        async let first: Bool? = race(20) { (try? await self.tunnels.resetConnection(of: t)) != nil }
        async let second: Bool? = race(20) { (try? await self.tunnels.resetConnection(of: t)) != nil }
        let (a, b) = await (first, second)
        guard let ra = a, let rb = b else {
            fail("a concurrent reset did not return within 20s — wedge")
            return
        }
        // MEASURED BEFORE the throw verdict, deliberately. This is the
        // claim the step's own doc says it can earn, and it used to sit
        // behind a `return` that a refusal took — so the one run where
        // a racer was refused reported red without ever measuring
        // whether the tunnel had converged, which is the reading that
        // says how bad the refusal was.
        check(await awaitStatus(t, is: .active, within: 30),
              "tunnel is live after overlapping resets — status=\(t.status)")
        guard ra, rb else {
            fail("a concurrent reset was refused (first=\(ra) second=\(rb)) — with the layer live above, that refusal describes a state the tunnel is not in")
            return
        }
        log("both concurrent resets returned without throwing", .ok)
        // The serialization itself, read off the wire: two raw opcode-3
        // messages in flight together must BOTH come back saying the
        // layer was rebuilt. The joiner answers with the in-flight
        // reset's own outcome, so a second `rebuilt` here is the
        // signature of one rebuild answered twice — and the shape the
        // refusal above would have broken.
        async let rawFirst = providerMessage(t, [3], timeout: 20)
        async let rawSecond = providerMessage(t, [3], timeout: 20)
        let (r1, r2) = await (rawFirst, rawSecond)
        guard case .data(let d1) = r1, case .data(let d2) = r2 else {
            fail("a raw concurrent opcode 3 went unanswered inside 20s")
            return
        }
        let o1 = TunnelResetReply.read(d1)
        let o2 = TunnelResetReply.read(d2)
        check(o1 == .rebuilt && o2 == .rebuilt,
              "both overlapping resets were answered with a rebuilt layer — first=\(o1.map { "\($0)" } ?? "no outcome byte"), second=\(o2.map { "\($0)" } ?? "no outcome byte")")
        _ = await awaitStatus(t, is: .active, within: 30)
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
