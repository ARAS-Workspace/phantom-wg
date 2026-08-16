#if DEBUG
import Foundation
import SystemExtensions

/// A submitter that CAPTURES requests instead of handing them to the
/// system, so the gate controller's request lifecycle can be driven
/// from a step without installing or removing anything.
///
/// This is the only stand-in in the harness whose whole value is what
/// it does NOT do. Every other fake here answers in place of a real
/// surface; this one makes the controller inert on purpose — an
/// activation stages nothing, a deactivation takes nothing down, and
/// the user's three extensions are untouched by a suite that drives all
/// three code paths. Nothing else about the controller changes: it
/// builds a genuine `OSSystemExtensionRequest`, wires itself as the
/// delegate, and stores the identity it demuxes on.
///
/// What a step supplies in the framework's place is the delegate
/// callbacks, delivered by hand onto the captured request. That is the
/// whole seam: the framework's ONLY inputs to this controller are those
/// callbacks, so a step that owns both ends owns the scenario —
/// including the two the system will not stage on request, an approval
/// prompt nobody answers and an answer that arrives after this app has
/// stopped waiting for it.
///
/// The bundle identifier a step composes its controller with should be
/// one that does not exist. Nothing here submits, so the id is never
/// resolved, and a synthetic one makes that unmistakable at the call
/// site rather than resting on this file being read.
///
/// Ledger only, no knobs: a request that is never submitted cannot fail
/// or succeed on its own, so there is nothing here to configure. The
/// answers a step wants are the callbacks it delivers itself.
final class FakeExtensionSubmitter: SystemExtensionSubmitting {

    /// Every request handed to this submitter, oldest first. The order
    /// is the proof for a negative: the activation branch of
    /// `didFinishWithResult` re-issues a properties query, so a step
    /// asserting that a late answer was NOT read as an activation reads
    /// this count rather than trusting the status alone.
    private(set) var submitted: [OSSystemExtensionRequest] = []

    var last: OSSystemExtensionRequest? { submitted.last }

    func submit(_ request: OSSystemExtensionRequest) {
        submitted.append(request)
    }
}
#endif
