#if DEBUG
import Foundation

/// A vault the harness can make answer a custody state of its own
/// choosing, so the branches that only a misbehaving vault reaches can
/// be driven at all.
///
/// It is a SUBCLASS rather than a stand-in because the production
/// client was already built to be one — the preview canvas has served
/// fixtures through `PreviewVaultClient` since before this harness
/// existed — so nothing in the app had to be widened, wrapped or
/// abstracted to make this possible. Every answer defaults to `.real`,
/// which forwards to the production implementation, so a client nobody
/// configures behaves exactly as the one it replaces.
///
/// The retry ladders come free and are NOT overridden on purpose:
/// `read(id:attempts:)`, `store(_:attempts:)` and `delete(id:attempts:)`
/// call the single-shot methods on `self`, so a fabricated verdict
/// drives the ladder that sits above it — including its patience, which
/// is part of what a caller is promised.
///
/// One sharp edge, named here because it is the only way to be bitten:
/// a step that fabricates ONE surface and leaves the others `.real`
/// still reaches the user's real vault through the rest. The steps here
/// run inside the user's own app, so anything they can reach is
/// production data. Fabricate every surface the code under test will
/// touch, not just the one the assertion reads.
///
/// And the surfaces are FOUR, not all of them: `ping()` is inherited
/// whole, so it wakes the user's real extension and reports its real
/// payload count whatever else is fabricated here. Nothing the custody
/// paths drive calls it — the two callers are the vault session and the
/// extension gate — so it is left real rather than given a knob no step
/// spends. A step that drives either of those must add the fifth
/// surface first.
@MainActor
final class FaultVaultClient: TunnelVaultClient {

    // MARK: - Injectable answers

    /// What one surface answers. The RPC families the harness drives
    /// differ only in their verdict type, so they share one shape
    /// rather than a copy each.
    ///
    /// There is no `.hangs`: a vault that never answers would need a
    /// held continuation, and nothing here needs one. Silence is
    /// spelled `.answers(.unreachable)`, which is what the production
    /// client's own 5-second race turns silence INTO before any caller
    /// sees it, and a window that has to stay open for a while is
    /// `.answersAfter`, which ends on its own.
    enum Answer<Verdict> {
        /// Forward to the production client — the real vault, really
        /// asked.
        case real
        case answers(Verdict)
        /// Answers, but late. The vault's own latency is what opens
        /// every window in the CRUD paths — a caller that has already
        /// marked its id in flight and not yet landed its entry — and
        /// a window nothing can hold open cannot be driven.
        case answersAfter(seconds: Double, Verdict)
    }

    /// The verdict every per-id read answers, unless `readAnswers`
    /// names that id.
    var readAnswer: Answer<Read> = .real
    /// Per-id verdicts, consulted first. A pass whose candidates
    /// disagree — one payload still there, one gone, one unreadable —
    /// is the only way to prove a probe is per-id rather than a single
    /// gate the whole pass shares.
    var readAnswers: [UUID: Answer<Read>] = [:]
    var readAllAnswer: Answer<ReadAll> = .real
    var storeAnswer: Answer<Write> = .real
    var deleteAnswer: Answer<Write> = .real

    // MARK: - Observed state

    /// Every id this client was asked about, in order. Counting is the
    /// whole proof for a short-circuit: a pass that stops probing after
    /// the first dark answer is indistinguishable from one that probes
    /// them all, unless the ledger is read.
    private(set) var readIds: [UUID] = []
    /// Every id a delete was ISSUED for — including one the vault would
    /// have refused, because the claim under test is what the app tried
    /// to do to a payload, not whether the keychain let it.
    private(set) var deletedIds: [UUID] = []
    /// Every id a store was issued for, appended BEFORE the answer is
    /// waited out. That order is what makes it a window signal: a
    /// caller whose id appears here has passed everything above its own
    /// vault write. It says nothing about what came after — under
    /// `.answers` the caller is already past the write by the time a
    /// step can read this, so a step using it to hold a window open has
    /// to be the one that made the answer late.
    private(set) var storedIds: [UUID] = []

    // All three ledgers count SINGLE-SHOT issues, and the retry ladders
    // sit above them: a caller using `delete(id:attempts: 3)` against a
    // fabricated `.refused` or `.unreachable` records the same id three
    // times, with the ladder's 600ms/1200ms sleeps between. A step that
    // asserts an exact count therefore has to fabricate `.done`, or
    // expect the ladder's multiple.

    // MARK: - RPCs

    override func read(id: UUID) async -> Read {
        readIds.append(id)
        switch readAnswers[id] ?? readAnswer {
        case .real: return await super.read(id: id)
        case .answers(let verdict): return verdict
        case .answersAfter(let seconds, let verdict): return await Self.after(seconds, verdict)
        }
    }

    override func readAll() async -> ReadAll {
        switch readAllAnswer {
        case .real: return await super.readAll()
        case .answers(let verdict): return verdict
        case .answersAfter(let seconds, let verdict): return await Self.after(seconds, verdict)
        }
    }

    @discardableResult
    override func store(_ config: TunnelConfig) async -> Write {
        storedIds.append(config.id)
        switch storeAnswer {
        case .real: return await super.store(config)
        case .answers(let verdict): return verdict
        case .answersAfter(let seconds, let verdict): return await Self.after(seconds, verdict)
        }
    }

    @discardableResult
    override func delete(id: UUID) async -> Write {
        deletedIds.append(id)
        switch deleteAnswer {
        case .real: return await super.delete(id: id)
        case .answers(let verdict): return verdict
        case .answersAfter(let seconds, let verdict): return await Self.after(seconds, verdict)
        }
    }

    /// The delay a late answer waits out. Sleeping rather than holding
    /// a continuation: every surface here is `async` all the way down,
    /// so there is no completion handler to retain and no way to
    /// mis-resume one. A cancelled step ends the wait and still gets
    /// its verdict, which is the production client's own behaviour when
    /// its race is cut short.
    private static func after<Verdict>(_ seconds: Double, _ verdict: Verdict) async -> Verdict {
        try? await Task.sleep(for: .seconds(seconds))
        return verdict
    }
}
#endif
