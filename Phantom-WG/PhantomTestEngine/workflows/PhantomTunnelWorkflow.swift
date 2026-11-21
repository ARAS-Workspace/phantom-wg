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
// answer does not come. An opcode the extension leaves unanswered is the
// red of the step's claim.
//
// Scenarios:
//
//   A — Activate
//       The tunnel reaches active within the activation ladder's own
//       length. The configuration's mode agrees with the registration,
//       and the activation armed recovery on this tunnel alone.
//
//   B — Opcode 0: Handshake Proven
//       Within 20 s the stats reply carries a handshake. Answers without
//       one skip (the server did not answer); no answer at all is the
//       claim's red.
//
//   C — Opcode 0: Three Numbers And No Key
//       The stats reply decodes as `TunnelRuntimeStats`, its keys are
//       exactly rxBytes, txBytes and lastHandshakeTimestamp, and its text
//       names no key field (iOS's own step: Mac compares the running peer
//       key against its vault, which on iOS the reply does not carry).
//
//   D — Opcode 1: Log Buffer Streams
//   E — Opcode 4: Log Count Matches The Buffer
//       The count is asked with the opcode's number, 4, and read first,
//       the buffer right after; lines that land between the two reads may
//       only add rows.
//   F — Opcode 2: Flush Round-Trip
//       The flush answers with its opcode and the buffer read after it is
//       smaller than the one before.
//   G — Opcode 3: Layer Reset In Place
//       `resetConnection` returns without an error within 15 s, the row is
//       active again, and a handshake newer than B's arrives within 30 s.
//       The stamp counts whole seconds, so the reset waits for the second
//       of B's handshake to pass; answers that carry no newer one skip
//       with the last stamp read.
//       The extension's log holds the line a rebuild ends on.
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

    /// What a call's ending says when it is not a plain return.
    static func failure(_ call: ResetCall?) -> String? {
        switch call {
        case .returned?: return nil
        case .refused(let why)?: return "it threw: \(why)"
        case nil: return "it did not return"
        }
    }
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

    /// The handshake stamp counts whole seconds: a reset in the second B's
    /// handshake landed in would bring a new one that reads as the old.
    /// Waits, two seconds at most, until that second has passed.
    private func untilTheSecondPasses(_ stamp: Int64) async {
        let limit = Date().addingTimeInterval(2)
        while stamp > 0, Date().timeIntervalSince1970 < Double(stamp + 1), Date() < limit {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Asks the stats once a second, 30 s at most, until they carry a
    /// handshake newer than B's: the last stamp read, and whether any ask
    /// was answered.
    private func handshakeAfterTheReset(on row: TunnelContainer) async -> (stamp: Int64, answered: Bool) {
        var stamp: Int64 = 0
        var answered = false
        let start = Date()
        while stamp <= lastHandshake, Date().timeIntervalSince(start) < 30 {
            if Task.isCancelled { break }
            let reply = await providerMessage(row, [0])
            if case .unanswered = reply {} else { answered = true }
            if let reading = stats(reply) { stamp = reading.lastHandshakeTimestamp }
            if stamp <= lastHandshake { try? await Task.sleep(for: .seconds(1)) }
        }
        return (stamp, answered)
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

    /// Whether the extension's log buffer holds the line a rebuild ends on.
    /// The buffer starts with the session and G's reset is the session's
    /// first, so a line here is that reset's.
    private func rebuildLogged(on row: TunnelContainer) async -> Bool {
        guard case .data(let data) = await providerMessage(row, [1]),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return false }
        return rows.contains { ($0["message"] as? String) == "Reset complete" }
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
        guard check(await awaitStatus(row, is: .active, within: activationBudget),
                    "the tunnel reaches active within the activation ladder's length (\(Int(activationBudget))s,"
                    + " status=\(row.status), error=\(row.lastActivationError.map { String(describing: $0) } ?? "nil"))")
        else { return }
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
        var carried: TunnelRuntimeStats?
        let start = Date()
        while carried == nil, Date().timeIntervalSince(start) < 20 {
            if Task.isCancelled { return }
            let reply = await providerMessage(row, [0])
            if case .unanswered = reply {} else { answered = true }
            if let reading = stats(reply), reading.lastHandshakeTimestamp > 0 {
                carried = reading
            } else {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        if answered, carried == nil {
            skip("environment: no handshake within 20s, the server did not answer")
            return
        }
        lastHandshake = carried?.lastHandshakeTimestamp ?? 0
        let read = carried.map { "at \($0.lastHandshakeTimestamp), rx=\($0.rxBytes) tx=\($0.txBytes)" }
            ?? "the stats opcode was unanswered for 20s while the row was active"
        check(carried != nil, "the stats reply carries a handshake within 20s (\(read))")
    }

    func statsCarryThreeNumbersAndNoKey() async {
        guard sessionUp, let row = target else {
            skip("the session is not up")
            return
        }
        let shape = "the reply decodes as the three numbers and carries no other field"
        let reply = await providerMessage(row, [0])
        guard case .data(let data) = reply else {
            check(false, shape + " (reply=\(reply.label))")
            return
        }
        let keys = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).map { Set($0.keys) } ?? []
        check(TunnelRuntimeStats.decoded(from: data) != nil
                && keys == ["rxBytes", "txBytes", "lastHandshakeTimestamp"],
              shape + " (keys=\(keys.sorted()))")
        let text = String(data: data, encoding: .utf8) ?? ""
        let named = ["private_key", "preshared_key", "public_key", "privateKey", "presharedKey"].filter { text.contains($0) }
        check(named.isEmpty, "and its text names no key field (named=\(named))")
    }

    func logBufferStreams() async {
        guard sessionUp, let row = target else {
            skip("the session is not up")
            return
        }
        let reply = await providerMessage(row, [1])
        if case .data(let data) = reply { preFlushBytes = data.count }
        let read = preFlushBytes > 0 ? "\(preFlushBytes) bytes" : "reply=\(reply.label)"
        check(preFlushBytes > 0, "the log buffer streams (\(read))")
    }

    func logCountMatchesTheBuffer() async {
        guard sessionUp, let row = target else {
            skip("the session is not up")
            return
        }
        let matches = "the log count matches the buffer read right after"
        let countReply = await providerMessage(row, [4])
        guard case .data(let data) = countReply, let count = TunnelLogCountReply.read(data) else {
            check(false, matches + " (the count was unreadable: reply=\(countReply.label))")
            return
        }
        switch await providerMessage(row, [1]) {
        case .data(let logs):
            let rows = ((try? JSONSerialization.jsonObject(with: logs)) as? [Any])?.count ?? -1
            check(rows >= count && rows - count <= 20, matches + " (count=\(count), rows=\(rows))")
        case .empty:
            check(count == 0, matches + " (count=\(count), the buffer is empty)")
        case .unanswered:
            check(false, matches + " (count=\(count), the buffer read was unanswered)")
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
            check(false, "the buffer after the flush is smaller"
                  + " (\(preFlushBytes) bytes before, the read after it was unanswered)")
        }
    }

    func layerResetInPlace() async {
        guard sessionUp, let row = target else {
            skip("the session is not up")
            return
        }
        await untilTheSecondPasses(lastHandshake)
        let outcome: ResetCall? = await race(15) {
            do {
                try await self.tunnels.resetConnection(of: row)
                return .returned
            } catch {
                return .refused(error.localizedDescription)
            }
        }
        let failure = ResetCall.failure(outcome)
        guard check(failure == nil, "the reset returns without an error within 15s" + (failure.map { " (\($0))" } ?? ""))
        else { return }
        guard check(await awaitStatus(row, is: .active, within: 30), "the row is active after the reset (status=\(row.status))") else { return }
        check(await rebuildLogged(on: row), "the extension's log holds the line a rebuild ends on (Reset complete)")
        guard lastHandshake > 0 else {
            skip("no handshake from step B to compare against")
            return
        }
        let after = await handshakeAfterTheReset(on: row)
        if after.answered, after.stamp <= lastHandshake {
            skip("environment: the layer was rebuilt, no newer handshake within 30s"
                 + " (last read \(after.stamp), before the reset \(lastHandshake))")
            return
        }
        let read = after.answered ? "\(after.stamp) > \(lastHandshake)" : "the stats opcode was unanswered for 30s after the reset"
        check(after.stamp > lastHandshake, "a handshake newer than the one before the reset arrives within 30s (\(read))")
    }

    func resetReplyNamesTheOutcome() async {
        guard sessionUp, let row = target else {
            skip("the session is not up")
            return
        }
        let shape = "the reply is the opcode and an outcome byte"
        let answer = await providerMessage(row, [3], timeout: 20)
        guard case .data(let reply) = answer else {
            check(false, shape + " (reply=\(answer.label) after 20s)")
            return
        }
        check(reply.count == 2 && reply[reply.startIndex] == 3, shape + " (bytes=\(Array(reply)))")
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
        let said = [one, two].map { $0.map { "\($0)" } ?? "no return within 20s" }
        check(one == true && two == true,
              "both overlapping resets return without an error (first=\(said[0]), second=\(said[1]))")
        guard one != nil, two != nil else { return }
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
