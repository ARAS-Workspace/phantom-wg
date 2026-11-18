// PhantomTunnel (Opcode Surface)
//
// A live pass over the tunnel extension's opcode surface, driven against
// one of the user's own test tunnels. One class with two catalogue
// registrations, standalone (`Test-WireGuard`) and ghost (`Test-Ghost`),
// so every claim is measured under both layer shapes. Mac's PhantomTunnel
// is the source. It runs behind the live gate.
//
// Claim discipline: a claim about our own code FAILS when broken whatever
// the server does; a claim that needs a server to answer SKIPS when the
// answer does not come.
//
// Scenarios:
//
//   A — Activate
//       Waits on the activation ladder's own length. The configuration's
//       mode agrees with the registration, and the activation armed
//       recovery on this tunnel alone.
//
//   B — Opcode 0: Handshake Proven
//       Within 20 s the stats reply carries a handshake. Answers without
//       one skip (the server did not answer); no answer at all fails.
//
//   C — Opcode 0: Three Numbers And No Key
//       The stats reply decodes as `TunnelRuntimeStats`, its keys are
//       exactly rxBytes, txBytes and lastHandshakeTimestamp, and its text
//       names no key field (iOS's own step: Mac compares the running peer
//       key against its vault, which on iOS the reply does not carry).
//
//   D — Opcode 1: Log Buffer Streams
//   E — Opcode 4: Log Count Matches The Buffer
//       The count is read first and the buffer right after; lines that
//       land between the two reads may only add rows.
//   F — Opcode 2: Flush Round-Trip
//       The flush answers with its opcode and the buffer read after it is
//       smaller than the one before.
//   G — Opcode 3: Layer Reset In Place
//       `resetConnection` returns without an error within 15 s, the row is
//       active again, and a handshake newer than B's arrives within 30 s.
//   H — Opcode 3: The Reply Names The Outcome
//       A raw opcode 3 answers two bytes, the opcode and `rebuilt`.
//   I — Opcode 3 x2: Concurrent Reset Converges
//       Two overlapping resets both return without an error and two raw
//       ones both answer `rebuilt`; the row is active after them.
//   J — Negative: Empty And Unknown Opcode Rejected
//       An empty message and opcode 9 are answered with no data.
//   K — Deactivate And Disarm Sweep
//       The tunnel rests and no tunnel in the list is armed.
//
// The tunnel driven here is the user's own test tunnel: the teardown
// brings it to rest and writes its rule down, and never removes it.

#if DEBUG
import Foundation

private enum ResetCall: Sendable {
    case returned
    case refused(String)
}

final class PhantomTunnelWorkflow: TestWorkflow {

    enum Mode { case standalone, ghost }
    private let mode: Mode

    init(_ mode: Mode) {
        self.mode = mode
        super.init()
    }

    override var displayName: String {
        mode == .ghost ? "PhantomTunnel (Ghost)" : "PhantomTunnel (Standalone)"
    }
    override var requiresLiveTunnels: Bool { true }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("Activate", activate),
            WorkflowStep("Opcode 0: Handshake Proven", handshakeProven),
            WorkflowStep("Opcode 0: Three Numbers And No Key", statsCarryThreeNumbersAndNoKey),
            WorkflowStep("Opcode 1: Log Buffer Streams", logBufferStreams),
            WorkflowStep("Opcode 4: Log Count Matches The Buffer", logCountMatchesTheBuffer),
            WorkflowStep("Opcode 2: Flush Round-Trip", flushRoundTrip),
            WorkflowStep("Opcode 3: Layer Reset In Place", layerResetInPlace),
            WorkflowStep("Opcode 3: The Reply Names The Outcome", resetReplyNamesTheOutcome),
            WorkflowStep("Opcode 3 x2: Concurrent Reset Converges", concurrentResetConverges),
            WorkflowStep("Negative: Empty And Unknown Opcode Rejected", emptyAndUnknownOpcodeRejected),
            WorkflowStep("Deactivate And Disarm Sweep", deactivateAndDisarmSweep)
        ]
    }

    private var configName: String {
        mode == .ghost ? TestContext.ghostName : TestContext.wireGuardName
    }
    private var target: TunnelContainer? { tunnel(named: configName) }

    private var sessionUp = false
    private var lastHandshake: Int64 = 0
    private var preFlushBytes = 0

    /// The activation ladder's whole length and a margin.
    private var activationBudget: Double { Double(tunnels.maxRetries) * tunnels.retryInterval + 5 }

    private func armed() -> [TunnelContainer] {
        tunnels.tunnels.filter { $0.tunnelProvider.isOnDemandEnabled }
    }

    private func stats(_ reply: ProviderReply) -> TunnelRuntimeStats? {
        guard case .data(let data) = reply else { return nil }
        return TunnelRuntimeStats.decoded(from: data)
    }

    /// Brings the test tunnel to rest and writes its rule down.
    private func ground(_ row: TunnelContainer) async -> String {
        var notes: [String] = []
        if row.status != .inactive {
            tunnels.startDeactivation(of: row)
            let rested = await awaitStatus(row, is: .inactive, within: 20)
            notes.append("rested=\(rested)")
        }
        if row.tunnelProvider.isOnDemandEnabled {
            row.tunnelProvider.isOnDemandEnabled = false
            do {
                try await row.tunnelProvider.savePreferences()
                notes.append("rule written down")
            } catch {
                notes.append("rule write refused (\(error.localizedDescription))")
            }
        }
        return notes.isEmpty ? "already rested, not armed" : notes.joined(separator: ", ")
    }

    // MARK: - Steps

    func activate() async {
        guard let row = target else {
            fail("\(configName) is not listed")
            return
        }
        if row.status != .inactive {
            log("precondition: \(configName) is \(row.status), bringing it to rest first", .warn)
            tunnels.startDeactivation(of: row)
            guard await awaitStatus(row, is: .inactive, within: 20) else {
                fail("\(configName) did not come to rest")
                return
            }
        }
        onTeardown("bring \(configName) to rest") { [weak self] in
            guard let self, let row = self.target else { return }
            let note = await self.ground(row)
            self.log("teardown: \(self.configName) \(note)")
        }
        tunnels.startActivation(of: row)
        guard await awaitStatus(row, is: .active, within: activationBudget) else {
            fail("\(configName) did not reach active within \(Int(activationBudget))s"
                 + " (error=\(row.lastActivationError.map { String(describing: $0) } ?? "nil"))")
            return
        }
        sessionUp = true
        let ghost = row.tunnelConfig?.wstunnel != nil
        check(ghost == (mode == .ghost), "the configuration's mode agrees with the registration (ghost=\(ghost))")
        let now = armed()
        check(now.count == 1 && now.first === row, "recovery is armed on this tunnel alone (armed=\(now.count))")
    }

    func handshakeProven() async {
        guard sessionUp, let row = target else {
            skip("the session is not up")
            return
        }
        var answered = false
        let start = Date()
        while Date().timeIntervalSince(start) < 20 {
            if Task.isCancelled { return }
            let reply = await providerMessage(row, [0])
            if case .unanswered = reply {} else { answered = true }
            if let reading = stats(reply), reading.lastHandshakeTimestamp > 0 {
                lastHandshake = reading.lastHandshakeTimestamp
                log("handshake at \(reading.lastHandshakeTimestamp), rx=\(reading.rxBytes) tx=\(reading.txBytes)", .ok)
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        if answered {
            skip("environment: no handshake within 20s, the server did not answer")
        } else {
            fail("the stats opcode was unanswered for 20s while the row was active")
        }
    }

    func statsCarryThreeNumbersAndNoKey() async {
        guard sessionUp, let row = target else {
            skip("the session is not up")
            return
        }
        guard case .data(let data) = await providerMessage(row, [0]) else {
            fail("the stats opcode did not answer with data")
            return
        }
        let keys = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).map { Set($0.keys) } ?? []
        check(TunnelRuntimeStats.decoded(from: data) != nil
                && keys == ["rxBytes", "txBytes", "lastHandshakeTimestamp"],
              "the reply decodes as the three numbers and carries no other field (keys=\(keys.sorted()))")
        let text = String(data: data, encoding: .utf8) ?? ""
        let named = ["private_key", "preshared_key", "public_key", "privateKey", "presharedKey"].filter { text.contains($0) }
        check(named.isEmpty, "and its text names no key field (named=\(named))")
    }

    func logBufferStreams() async {
        guard sessionUp, let row = target else {
            skip("the session is not up")
            return
        }
        switch await providerMessage(row, [1]) {
        case .data(let data):
            preFlushBytes = data.count
            check(!data.isEmpty, "the log buffer streams (\(data.count) bytes)")
        case .empty:
            fail("the log request was answered with no data")
        case .unanswered:
            fail("the log request was unanswered (5s)")
        }
    }

    func logCountMatchesTheBuffer() async {
        guard sessionUp, let row = target else {
            skip("the session is not up")
            return
        }
        let countReply = await providerMessage(row, [TunnelLogCountReply.opcode])
        guard case .data(let data) = countReply, let count = TunnelLogCountReply.read(data) else {
            fail("the log count was unreadable (reply=\(countReply.label))")
            return
        }
        switch await providerMessage(row, [1]) {
        case .data(let logs):
            let rows = ((try? JSONSerialization.jsonObject(with: logs)) as? [Any])?.count ?? -1
            check(rows >= count && rows - count <= 20, "log count \(count), the buffer read right after holds \(rows) rows")
        case .empty:
            check(count == 0, "log count \(count), the buffer read right after is empty")
        case .unanswered:
            fail("the buffer read after the count was unanswered")
        }
    }

    func flushRoundTrip() async {
        guard sessionUp, let row = target else {
            skip("the session is not up")
            return
        }
        let echo = await providerMessage(row, [2])
        check(echo == .data(Data([2])), "the flush is acknowledged with its opcode (reply=\(echo.label))")
        switch await providerMessage(row, [1]) {
        case .data(let data):
            check(preFlushBytes > 0 && data.count < preFlushBytes,
                  "the buffer after the flush is smaller (\(preFlushBytes) → \(data.count) bytes)")
        case .empty:
            check(preFlushBytes > 0, "the buffer after the flush is empty (from \(preFlushBytes) bytes)")
        case .unanswered:
            fail("the buffer read after the flush was unanswered")
        }
    }

    func layerResetInPlace() async {
        guard sessionUp, let row = target else {
            skip("the session is not up")
            return
        }
        let outcome: ResetCall? = await race(15) {
            do {
                try await self.tunnels.resetConnection(of: row)
                return .returned
            } catch {
                return .refused(error.localizedDescription)
            }
        }
        guard let outcome else {
            fail("the reset did not return within 15s")
            return
        }
        if case .refused(let why) = outcome {
            fail("the reset was refused rather than rebuilding the layer (\(why))")
            return
        }
        guard check(await awaitStatus(row, is: .active, within: 30), "the row is active after the reset (status=\(row.status))") else { return }
        guard lastHandshake > 0 else {
            skip("no handshake from step B to compare against")
            return
        }
        let start = Date()
        while Date().timeIntervalSince(start) < 30 {
            if Task.isCancelled { return }
            if let reading = stats(await providerMessage(row, [0])), reading.lastHandshakeTimestamp > lastHandshake {
                log("a handshake newer than the one before the reset: \(reading.lastHandshakeTimestamp) > \(lastHandshake)", .ok)
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        skip("environment: the layer was rebuilt, no newer handshake within 30s")
    }

    func resetReplyNamesTheOutcome() async {
        guard sessionUp, let row = target else {
            skip("the session is not up")
            return
        }
        guard case .data(let reply) = await providerMessage(row, [3], timeout: 20) else {
            fail("opcode 3 did not answer within 20s")
            return
        }
        check(reply.count == 2 && reply[reply.startIndex] == 3,
              "the reply is the opcode and an outcome byte (bytes=\(Array(reply)))")
        check(TunnelResetReply.read(reply) == .outcome(.rebuilt), "a live layer answers rebuilt (\(TunnelResetReply.read(reply)))")
        check(await awaitStatus(row, is: .active, within: 30), "the row is active after the raw reset (status=\(row.status))")
    }

    func concurrentResetConverges() async {
        guard sessionUp, let row = target else {
            skip("the session is not up")
            return
        }
        async let first: Bool? = race(20) { (try? await self.tunnels.resetConnection(of: row)) != nil }
        async let second: Bool? = race(20) { (try? await self.tunnels.resetConnection(of: row)) != nil }
        let (one, two) = await (first, second)
        guard let one, let two else {
            fail("an overlapping reset did not return within 20s")
            return
        }
        check(one && two, "both overlapping resets return without an error (first=\(one), second=\(two))")
        async let rawFirst = providerMessage(row, [3], timeout: 20)
        async let rawSecond = providerMessage(row, [3], timeout: 20)
        let (replyOne, replyTwo) = await (rawFirst, rawSecond)
        let readings = [replyOne, replyTwo].map { reply -> TunnelResetReply.Reading? in
            if case .data(let data) = reply { return TunnelResetReply.read(data) }
            return nil
        }
        check(readings.allSatisfy { $0 == .outcome(.rebuilt) }, "both overlapping raw resets answer rebuilt (\(readings))")
        check(await awaitStatus(row, is: .active, within: 30), "the row is active after them (status=\(row.status))")
    }

    func emptyAndUnknownOpcodeRejected() async {
        guard sessionUp, let row = target else {
            skip("the session is not up")
            return
        }
        let empty = await providerMessage(row, [])
        check(empty == .empty, "an empty message is answered with no data (reply=\(empty.label))")
        let unknown = await providerMessage(row, [9])
        check(unknown == .empty, "opcode 9 is answered with no data (reply=\(unknown.label))")
    }

    func deactivateAndDisarmSweep() async {
        guard let row = target else {
            skip("\(configName) is not listed")
            return
        }
        if row.status != .inactive {
            tunnels.startDeactivation(of: row)
            check(await awaitStatus(row, is: .inactive, within: 20), "the tunnel rests (status=\(row.status))")
        }
        let now = armed()
        check(now.isEmpty, "no tunnel in the list is armed (armed=\(now.count) of \(tunnels.tunnels.count))")
    }
}
#endif
