// ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
// ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
// ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
// ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
// ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
// ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
//
// Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
// Licensed under AGPL-3.0 - see LICENSE file for details
// WireGuard® is a registered trademark of Jason A. Donenfeld.
//
// Extension Gate (Removal Budget)
//
// The extension gate's removal path — what the budget does under an
// approval prompt, and what happens to an answer that arrives after this
// app has stopped waiting for it — and the ledger that decides when an
// activation is over.
//
// Every step composes its OWN `ExtensionGateController` over a capturing
// submitter, and that is the only way this surface can be measured at all
// — the app's three real controllers drive real system extensions, so the
// scenarios below would mean removing the user's. Nothing here is ever
// submitted; the bundle identifier names an extension the system has never
// heard of, so the safety of these steps does not rest on a real id
// staying unresolved.
//
// Scenarios:
//
//   A — A Removal Nobody Approves Ends Its Own Wait
//       The reason the budget exists. A deactivation raises a system
//       approval prompt, and a user who walks away from it used to hold
//       the uninstall flow open for the life of the process — with the
//       refresh latch up behind it, so ingest, restore and realign all
//       stayed dead until a relaunch.
//
//   B — An Approval Prompt For A Removal Does Not Paint The Gate
//   C — An Answer Past The Budget Is Still Read As A Removal
//   D — A Second Removal Is Refused While One Is In Flight
//   E — A Retry's Wait Is Not Answered By The Removal It Replaced
//
//   F — A Failed Refresh Spends No Part Of An Activation
//       The gate holds its promotion while an activation is in flight,
//       and the count of what is in flight is what holds it. This drives
//       a properties query — the request a refresh issues, which no
//       activation ever counted — to both of its terminal callbacks
//       while an activation is still open.
//
// The default budget here is two seconds rather than the app's sixty,
// because what is under test is that the wait ENDS and what it hands back
// when it does — neither claim is about the size of the number, and the
// path is the one production takes. Three steps override it; only one
// needs to, and changing the default moves the other two.

#if DEBUG
import Foundation
import SystemExtensions

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
            WorkflowStep("A Failed Refresh Spends No Part Of An Activation",
                         aFailedRefreshSpendsNoPartOfAnActivation)
        ]
    }

    private static let absentBundleID = "com.remrearas.Phantom-WG-MacOS.TE-NoSuchExtension"

    private nonisolated static let testBudget: Duration = .seconds(2)

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

    private func answer(of removal: Task<RemovalAnswer, Never>) async -> RemovalAnswer? {
        await race(8) { await removal.value }
    }

    // MARK: - Steps

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
        check(controller.status == .unknown,
              "the gate itself was left where it was: giving up on an answer is not a verdict about the extension (status=\(controller.status))")
    }

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

    private func aFailedRefreshSpendsNoPartOfAnActivation() async {
        let (controller, submitter) = rig()

        controller.activate()
        guard await settle(within: 2, until: { submitter.submitted.count == 1 }),
              let activationRequest = submitter.last else {
            fail("the activation never reached the submitter — submitted=\(submitter.submitted.count)")
            return
        }
        guard check(controller.activationsInFlightForTesting == 1,
                    "the activation is counted while it is in flight, which is the only thing holding the promotion"
                    + " — inFlight=\(controller.activationsInFlightForTesting), expected 1") else { return }
        check(controller.status == .activating,
              "and the gate is mid-activation — status=\(controller.status)")

        controller.refresh()
        guard await settle(within: 2, until: { submitter.submitted.count == 2 }),
              let refreshRequest = submitter.last, refreshRequest !== activationRequest else {
            fail("the refresh never reached the submitter as its OWN request — submitted=\(submitter.submitted.count)")
            return
        }

        let failure = NSError(domain: "TE.Gate", code: 71,
                              userInfo: [NSLocalizedDescriptionKey: "driven properties failure"])
        controller.request(refreshRequest, didFailWithError: failure)

        let spent = await settle(within: 2) { controller.activationsInFlightForTesting != 1 }
        check(!spent,
              "a properties query that failed spent no part of the activation still in flight —"
              + " inFlight=\(controller.activationsInFlightForTesting), expected 1")
        check(controller.status == .activating,
              "and it wrote no verdict over the gate, since a query that failed says nothing about the extension"
              + " — status=\(controller.status)")

        controller.refresh()
        guard await settle(within: 2, until: { submitter.submitted.count == 3 }),
              let secondRefresh = submitter.last, secondRefresh !== refreshRequest else {
            fail("the second refresh never reached the submitter — submitted=\(submitter.submitted.count)")
            return
        }
        controller.request(secondRefresh, didFinishWithResult: .completed)

        let spentOnCompletion = await settle(within: 2) { controller.activationsInFlightForTesting != 1 }
        check(!spentOnCompletion,
              "and a properties query that SUCCEEDED spent no part of it either, which is the same door on the other"
              + " callback — inFlight=\(controller.activationsInFlightForTesting), expected 1")
    }

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

    private func secondRemovalIsRefused() async {
        let (controller, submitter) = rig(budget: .seconds(4))
        let first = attemptRemoval(controller)

        guard await settle(within: 3, until: { submitter.submitted.count == 1 }) else {
            first.cancel()
            fail("the first removal never reached the submitter — submitted=\(submitter.submitted.count)")
            return
        }

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

        let second = attemptRemoval(controller)
        guard await settle(within: 3, until: { submitter.submitted.count == 2 }),
              let secondRequest = submitter.last, secondRequest !== firstRequest else {
            second.cancel()
            fail("the retry never reached the submitter as a request of its own — submitted=\(submitter.submitted.count)")
            return
        }

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
