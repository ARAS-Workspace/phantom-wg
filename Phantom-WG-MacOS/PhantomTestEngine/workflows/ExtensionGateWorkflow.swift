#if DEBUG
import Foundation
import SystemExtensions

/// The extension gate's removal path: the budget under an approval
/// prompt, and what happens to the answer that arrives after this app
/// has stopped waiting for it.
///
/// Every step here composes its OWN `ExtensionGateController` over a
/// capturing submitter, and that is the only way this surface can be
/// measured at all. The app's three real controllers drive real system
/// extensions — the scenarios below would mean removing the user's
/// tunnel extension and then not approving it — so the steps do not go
/// anywhere near them. Nothing here is submitted, nothing is installed,
/// nothing is removed, and no id used here exists.
///
/// It also means these steps plant NO residue: no vault payload, no NE
/// entry, no running session. There is no teardown net in this file
/// because there is nothing for one to sweep, which is said here so
/// that its absence reads as a fact rather than an omission.
final class ExtensionGateWorkflow: TestWorkflow {
    override var displayName: String { "Extension Gate (Removal Budget + Late Answers)" }

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("A Removal Nobody Approves Ends Its Own Wait", unansweredRemovalEndsItsWait),
            WorkflowStep("An Approval Prompt For A Removal Does Not Paint The Gate", approvalForARemovalDoesNotPaint),
            WorkflowStep("An Answer Past The Budget Is Still Read As A Removal", lateAnswerIsStillARemoval),
            WorkflowStep("A Second Removal Is Refused While One Is In Flight", secondRemovalIsRefused),
            WorkflowStep("A Retry's Wait Is Not Answered By The Removal It Replaced",
                         aRetryIsNotAnsweredByTheRemovalItReplaced),
        ]
    }

    /// A bundle identifier for an extension that does not exist.
    ///
    /// Nothing in this file is submitted, so the id is never resolved by
    /// anything — but composing with the real one would leave the safety
    /// of these steps resting on that fact staying true. A name the
    /// system has never heard of makes it independent of it.
    private static let absentBundleID = "com.remrearas.Phantom-WG-MacOS.TE-NoSuchExtension"

    /// The DEFAULT budget, and the reason it is two seconds rather than
    /// the app's sixty: what is under test is that the wait ENDS and
    /// what it hands back when it does, and neither claim is about the
    /// size of the number. The path is the same one production takes.
    ///
    /// THREE steps override it — 2, 4 and 5 — so changing this number
    /// moves the other two. Only step 5 needs the override: its
    /// arrangement has to still be standing while the budget is
    /// measured, and its own doc derives the margin. Steps 2 and 4 take
    /// four seconds as HEADROOM rather than necessity; the default
    /// would satisfy both arrangements today.
    ///
    /// The other number that pins this one is the ceiling in
    /// `answer(of:)` — a budget at or above it would be waited out by
    /// the step rather than by the product.
    ///
    /// `nonisolated` because it is read as a default argument, which is
    /// evaluated at the call site before the workflow's actor is
    /// entered. An immutable `Duration` has nothing to isolate.
    private nonisolated static let testBudget: Duration = .seconds(2)

    /// What a removal attempt answered, in a shape that can cross a
    /// task boundary — `Error` cannot, so the case and the sentence the
    /// user would read are carried instead of the error itself.
    private enum RemovalAnswer: Sendable, Equatable {
        case completed
        case notAnswered(String)
        case alreadyInFlight(String)
        case other(String)
    }

    private func rig(budget: Duration = ExtensionGateWorkflow.testBudget)
        -> (controller: ExtensionGateController, submitter: FakeExtensionSubmitter) {
        let submitter = FakeExtensionSubmitter()
        let controller = ExtensionGateController(
            bundleID: Self.absentBundleID,
            displayName: "TE-Gate",
            submitter: submitter,
            deactivationBudget: budget
        )
        return (controller, submitter)
    }

    private func attemptRemoval(_ controller: ExtensionGateController) -> Task<RemovalAnswer, Never> {
        Task { @MainActor in
            do {
                try await controller.deactivate()
                return .completed
            } catch let error as ExtensionGateController.ExtensionGateError {
                switch error {
                case .deactivationNotAnswered: return .notAnswered(error.localizedDescription)
                case .deactivationAlreadyInFlight: return .alreadyInFlight(error.localizedDescription)
                }
            } catch {
                return .other(error.localizedDescription)
            }
        }
    }

    /// Waits for a removal's answer under a ceiling of the HARNESS's
    /// own, because a wait that never ends is exactly the defect the
    /// budget exists to prevent and a step must not inherit it.
    private func answer(of removal: Task<RemovalAnswer, Never>) async -> RemovalAnswer? {
        await race(8) { await removal.value }
    }

    // MARK: - Steps

    /// The whole reason the budget exists. A deactivation raises a
    /// system approval prompt, and a user who walks away from it used
    /// to hold this app's uninstall flow open for the life of the
    /// process — with the refresh latch up behind it, so ingest,
    /// restore and realign all stayed dead and only a relaunch cured it.
    ///
    /// Nothing answers the request here, and nothing can: the submitter
    /// never handed it anywhere. So the wait has exactly one possible
    /// end, and the step's ceiling is what tells a budget that fired
    /// from one that does not exist.
    private func unansweredRemovalEndsItsWait() async {
        let (controller, submitter) = rig()
        let removal = attemptRemoval(controller)

        guard await settle(within: 3, until: { submitter.submitted.count == 1 }) else {
            removal.cancel()
            fail("the removal never reached the submitter — submitted=\(submitter.submitted.count)")
            return
        }
        log("the removal was submitted, and nothing in this step will ever answer it")

        guard let answer = await answer(of: removal) else {
            fail("the removal was still waiting 8s into a 2s budget — this wait has no end")
            return
        }
        guard case .notAnswered(let sentence) = answer else {
            fail("the wait ended by some other route — answer=\(answer)")
            return
        }
        log("the wait ended on its own budget, with the reason named")
        check(sentence == LocalizationManager.shared.t("error_uninstall_not_approved"),
              "and what it hands back is the sentence the user reads — an unconformed error here would surface as \"The operation couldn't be completed\" (\"\(sentence)\")")
        // Pins a contract rather than discriminating this package's own
        // revert: nothing in the tree writes a status on the budget's
        // path today, and this is what goes red the day something does.
        check(controller.status == .unknown,
              "the gate itself was left where it was: giving up on an answer is not a verdict about the extension (status=\(controller.status))")
    }

    /// `requestNeedsUserApproval` fires for a DEACTIVATION too, and
    /// painting the gate `.needsApproval` for one says the opposite of
    /// what happened — that status is the install story, and the screen
    /// it drives offers the user System Settings to approve an extension
    /// they just asked to remove.
    ///
    /// Both halves are needed. The first alone would pass just as well
    /// if the callback had gone nowhere at all; the second sends the
    /// same callback for a request that is NOT a removal and reads the
    /// paint that proves the path is live.
    private func approvalForARemovalDoesNotPaint() async {
        let (controller, submitter) = rig(budget: .seconds(4))
        let removal = attemptRemoval(controller)

        guard await settle(within: 3, until: { submitter.submitted.count == 1 }),
              let removalRequest = submitter.last else {
            removal.cancel()
            fail("the removal never reached the submitter — submitted=\(submitter.submitted.count)")
            return
        }

        controller.requestNeedsUserApproval(removalRequest)
        let paintedForRemoval = await settle(within: 1) { controller.status == .needsApproval }
        check(!paintedForRemoval,
              "the prompt a REMOVAL raises leaves the gate alone (status=\(controller.status))")

        controller.activate()
        guard await settle(within: 2, until: { submitter.submitted.count == 2 }),
              let activationRequest = submitter.last, activationRequest !== removalRequest else {
            _ = await answer(of: removal)
            fail("the activation never reached the submitter — submitted=\(submitter.submitted.count)")
            return
        }
        // The control must MOVE the gate off the paint it is about to
        // look for, or it would be reading a `.needsApproval` that was
        // already there and passing while the callback did nothing.
        guard check(controller.status == .activating,
                    "the activation moved the gate off the state the check below looks for (status=\(controller.status))") else {
            _ = await answer(of: removal)
            return
        }
        controller.requestNeedsUserApproval(activationRequest)
        let paintedForInstall = await settle(within: 2) { controller.status == .needsApproval }
        check(paintedForInstall,
              "while the same callback for an INSTALL paints it, so the half above is a guard holding rather than a callback that went nowhere (status=\(controller.status))")

        _ = await answer(of: removal)
    }

    /// The one macOS will not let this app take back. There is no cancel
    /// API for a submitted request: the delegate stays wired, and the
    /// answer arrives whenever the user finally acts — minutes after the
    /// budget ended the wait.
    ///
    /// Clearing the identity pointer on the budget's way out did not
    /// make that request go away. It made its late answer demux as an
    /// ACTIVATION, and the gate painted `.needsApproval` over an
    /// extension that had just been removed, offering a button that
    /// reinstalls it — the exact wrongness the approval branch was
    /// changed to stop telling, arriving by another door.
    private func lateAnswerIsStillARemoval() async {
        let (controller, submitter) = rig()
        let removal = attemptRemoval(controller)

        guard await settle(within: 3, until: { submitter.submitted.count == 1 }),
              let request = submitter.last else {
            removal.cancel()
            fail("the removal never reached the submitter — submitted=\(submitter.submitted.count)")
            return
        }
        guard let answer = await answer(of: removal), case .notAnswered = answer else {
            fail("the budget never ended the wait, so there is nothing abandoned here to measure")
            return
        }

        // The user finally acts, long after this app stopped waiting.
        controller.requestNeedsUserApproval(request)
        let painted = await settle(within: 1) { controller.status == .needsApproval }
        check(!painted,
              "the abandoned request's prompt is still read as the removal it is (status=\(controller.status))")

        controller.request(request, didFinishWithResult: .completed)
        let settled = await settle(within: 3) { controller.status == .notInstalled }
        check(settled,
              "and its answer lands on the REMOVAL branch — the extension is gone (status=\(controller.status))")
        check(submitter.submitted.count == 1,
              "with no properties query behind it, which is what the activation branch would have issued (submitted=\(submitter.submitted.count))")
    }

    /// One deactivation at a time, and the refusal is a real one rather
    /// than a silent return: a second call would overwrite the stored
    /// continuation and strand the first caller for ever — nothing would
    /// resume it — and the uninstall flow awaits three of these in
    /// sequence, so a stall there stops the whole teardown with nothing
    /// to show for it.
    private func secondRemovalIsRefused() async {
        let (controller, submitter) = rig(budget: .seconds(4))
        let first = attemptRemoval(controller)

        guard await settle(within: 3, until: { submitter.submitted.count == 1 }) else {
            first.cancel()
            fail("the first removal never reached the submitter — submitted=\(submitter.submitted.count)")
            return
        }

        // Through the file's own ceiling, not awaited bare: the refusal
        // is expected to answer at once, and a step must not inherit
        // the wedge that would follow if it ever stopped doing so.
        guard let second = await answer(of: attemptRemoval(controller)) else {
            _ = await answer(of: first)
            fail("the second removal neither answered nor refused inside the step's ceiling")
            return
        }
        guard case .alreadyInFlight(let sentence) = second else {
            _ = await answer(of: first)
            fail("the second removal was not refused — answer=\(second)")
            return
        }
        // "One at a time" is about this app's WAIT, not about the
        // system: the budget cancels nothing, so more than one removal
        // of ours can be outstanding — which is what the step below
        // measures.
        log("the second removal was refused with its own reason, not folded into the first one's wait")
        check(sentence == LocalizationManager.shared.t("error_uninstall_already_running"),
              "and the refusal reaches the user as its own sentence (\"\(sentence)\")")
        check(submitter.submitted.count == 1,
              "nothing was submitted for it: the first request is still the one the system holds (submitted=\(submitter.submitted.count))")

        guard let firstAnswer = await answer(of: first), case .notAnswered = firstAnswer else {
            fail("the first removal did not end on its budget after the refusal")
            return
        }
        log("and the first wait still ended on its own budget afterwards, so the refusal took nothing from it")
    }

    /// The third door into the wrongness the abandoned ledger was added
    /// to close, and the one the ledger itself opened.
    ///
    /// Giving up on an answer neither cancels the request nor stops the
    /// user: the alert names the reason and invites another try, and the
    /// re-entrance guard is keyed to the continuation the budget has
    /// just cleared — so the retry is admitted by design. From there two
    /// removals are live at once, the one the system still holds and the
    /// one this app is waiting on. An exit guarded on the continuation's
    /// EXISTENCE alone hands the first one's answer to the second one's
    /// caller and clears the pointer with it, after which the second
    /// request's own answer lands as a stranger and takes the ACTIVATION
    /// branch — painting `.needsApproval` over an extension that was
    /// just removed.
    ///
    /// The budget here is four seconds rather than the file's default,
    /// because this step has to still be inside the RETRY's budget while
    /// it observes that nothing answered the retry. The two numbers,
    /// written rather than expressed as a ratio: the observation window
    /// is 1.5 seconds of that 4-second budget, leaving roughly 2.4
    /// before it fires. A retry budget that fires inside the window
    /// anyway is named as an environment exit rather than read as the
    /// theft under test — the two are different facts and must not
    /// arrive under one verdict, and the theft cannot disguise itself as
    /// one: a stolen answer resumes with `.completed`, never with the
    /// budget's own `.notAnswered`.
    private func aRetryIsNotAnsweredByTheRemovalItReplaced() async {
        let (controller, submitter) = rig(budget: .seconds(4))
        let first = attemptRemoval(controller)

        guard await settle(within: 3, until: { submitter.submitted.count == 1 }),
              let firstRequest = submitter.last else {
            first.cancel()
            fail("the first removal never reached the submitter — submitted=\(submitter.submitted.count)")
            return
        }
        guard let abandoned = await answer(of: first), case .notAnswered = abandoned else {
            fail("the budget never ended the first wait, so there is no abandoned request here to measure")
            return
        }

        // The user takes the alert at its word and starts again.
        let second = attemptRemoval(controller)
        guard await settle(within: 3, until: { submitter.submitted.count == 2 }),
              let secondRequest = submitter.last, secondRequest !== firstRequest else {
            second.cancel()
            fail("the retry never reached the submitter as a request of its own — submitted=\(submitter.submitted.count)")
            return
        }

        // The ORIGINAL prompt is finally answered, long after this app
        // stopped waiting on it and while a different removal is live.
        controller.request(firstRequest, didFinishWithResult: .completed)
        switch await race(1.5, { await second.value }) {
        case .none:
            log("the retry is still waiting on its OWN request — the answer to the removal it replaced was not handed to it")
        case .some(.notAnswered):
            skip("environment: the retry's own budget fired inside the observation window — nothing was measured")
            return
        case .some(let stolen):
            fail("the retry's wait was answered by the removal it replaced — answer=\(stolen)")
            return
        }
        check(controller.status == .notInstalled,
              "while that answer still carried its own gate state, which is the whole reason the abandoned ledger outlives the wait (status=\(controller.status))")

        // And the retry's own answer is still read as the removal it is.
        controller.request(secondRequest, didFinishWithResult: .completed)
        guard let own = await answer(of: second), case .completed = own else {
            fail("the retry did not complete on its own answer — it was no longer recognised as a removal of ours")
            return
        }
        log("and the retry completed on its own answer, recognised as the removal it was")
        check(submitter.submitted.count == 2,
              "with no properties query behind either of them — one is what the activation branch would have issued for a request it no longer recognised (submitted=\(submitter.submitted.count))")
    }
}
#endif
