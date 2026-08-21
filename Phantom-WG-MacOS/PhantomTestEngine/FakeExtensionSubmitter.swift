#if DEBUG
import Foundation
import SystemExtensions

final class FakeExtensionSubmitter: SystemExtensionSubmitting {

    private(set) var submitted: [OSSystemExtensionRequest] = []

    var last: OSSystemExtensionRequest? { submitted.last }

    func submit(_ request: OSSystemExtensionRequest) {
        submitted.append(request)
    }
}
#endif
