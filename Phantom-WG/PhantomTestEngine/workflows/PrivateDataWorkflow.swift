// Private Data
//
// `PrivateDataGuard.grants`, the one door copy, export, edit and delete ask
// before they touch a tunnel's private data, measured at its own boundary:
// the owner check is handed in as a closure answering granted, declined or
// failed. The device's Face ID and passcode sheet is not driven here; it
// is the user-facing surface that answers this method, tried by hand.
//
// Scenarios:
//
//   A — A Granted Owner Check Opens The Door
//       The check is asked with the caller's reason; the door answers true
//       and reports no failure.
//
//   B — A Declined Owner Check Closes It Silently
//       The check is asked once; the door answers false and reports no
//       failure.
//
//   C — A Failed Owner Check Closes It And Names The Failure
//       The door answers false and hands the check's message to the
//       caller once.
//
//   D — A Second Request While One Is Open Answers False Without Asking
//       While a first check is held open, a second request answers false
//       at once, silently, and the check is not asked again; the first, once
//       granted, opens the door; a third request after it is asked again.
//       A refused request does not release the first: another one after
//       it is refused the same way.

#if DEBUG
import Foundation

final class PrivateDataWorkflow: TestWorkflow {
    override var displayName: String { "Private Data (The Owner Check's Door)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("A Granted Owner Check Opens The Door", aGrantedOwnerCheckOpensTheDoor),
            WorkflowStep("A Declined Owner Check Closes It Silently", aDeclinedOwnerCheckClosesItSilently),
            WorkflowStep("A Failed Owner Check Closes It And Names The Failure", aFailedOwnerCheckClosesItAndNamesTheFailure),
            WorkflowStep("A Second Request While One Is Open Answers False Without Asking",
                         aSecondRequestWhileOneIsOpenAnswersFalseWithoutAsking)
        ]
    }

    /// What one `grants` call left behind.
    @MainActor
    private final class Ledger {
        var asked: [String] = []
        var failures: [String] = []
    }

    /// A check held open until `answer(_:)` is called.
    @MainActor
    private final class HeldCheck {
        var asked = 0
        private var continuation: CheckedContinuation<PrivateDataAuthorization.Outcome, Never>?

        var isOpen: Bool { continuation != nil }

        func ask() async -> PrivateDataAuthorization.Outcome {
            asked += 1
            return await withCheckedContinuation { continuation = $0 }
        }

        func answer(_ outcome: PrivateDataAuthorization.Outcome) {
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }

    private func request(_ outcome: PrivateDataAuthorization.Outcome, _ ledger: Ledger) async -> Bool {
        await PrivateDataGuard.grants(
            reason: "TE private data reason",
            authorize: { reason in
                ledger.asked.append(reason)
                return outcome
            },
            onFailure: { ledger.failures.append($0) }
        )
    }

    // MARK: - Steps

    func aGrantedOwnerCheckOpensTheDoor() async {
        let ledger = Ledger()
        let opened = await request(.granted, ledger)
        check(ledger.asked == ["TE private data reason"], "the check is asked once, with the caller's reason (asked=\(ledger.asked))")
        check(opened && ledger.failures.isEmpty,
              "the door answers true and reports no failure (opened=\(opened), failures=\(ledger.failures.count))")
    }

    func aDeclinedOwnerCheckClosesItSilently() async {
        let ledger = Ledger()
        let opened = await request(.declined, ledger)
        check(ledger.asked.count == 1, "the declined check is asked once (asked=\(ledger.asked.count))")
        check(!opened && ledger.failures.isEmpty,
              "the door answers false and reports no failure (opened=\(opened), failures=\(ledger.failures.count))")
    }

    func aFailedOwnerCheckClosesItAndNamesTheFailure() async {
        let ledger = Ledger()
        let opened = await request(.failed("TE owner check failed"), ledger)
        check(!opened && ledger.failures == ["TE owner check failed"],
              "the door answers false and hands the check's message to the caller once"
              + " (opened=\(opened), failures=\(ledger.failures))")
    }

    func aSecondRequestWhileOneIsOpenAnswersFalseWithoutAsking() async {
        let held = HeldCheck()
        let first = Task { @MainActor in
            await PrivateDataGuard.grants(reason: "TE first", authorize: { _ in await held.ask() }, onFailure: { _ in })
        }
        onTeardown("answer a check still held open") { held.answer(.declined) }
        let reached = await settle(within: 2, until: { held.isOpen })
        guard check(reached, "the first request reaches its check (asked=\(held.asked))") else { return }

        let ledger = Ledger()
        let second = await request(.granted, ledger)
        check(!second && ledger.asked.isEmpty,
              "a second request while the first is open answers false and its check is not asked (second=\(second), asked=\(ledger.asked.count))")
        check(ledger.failures.isEmpty, "the refused request reports no failure (failures=\(ledger.failures.count))")

        let again = Ledger()
        let another = await request(.granted, again)
        check(!another && again.asked.isEmpty,
              "another request while the first is still open answers false too and its check is not asked"
              + " (another=\(another), asked=\(again.asked.count))")

        held.answer(.granted)
        let firstOpened = await first.value
        check(firstOpened, "the first, once granted, opens the door (first=\(firstOpened))")

        let after = Ledger()
        let third = await request(.granted, after)
        check(third && after.asked.count == 1,
              "a third request after it is asked again (third=\(third), asked=\(after.asked.count))")
    }
}
#endif
