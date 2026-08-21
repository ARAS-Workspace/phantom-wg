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
// Test Engine: Extension Submitter That Submits Nothing
//
// A `SystemExtensionSubmitting` that records requests and stages none.
//
// Every other fake here answers in place of a real surface; this one makes
// the controller INERT on purpose. `ExtensionGateController` builds a
// genuine `OSSystemExtensionRequest`, wires itself as the delegate and
// demuxes on identity exactly as it does in production — but nothing
// reaches the system, so the user's three extensions are untouched by a
// run that drives activation and deactivation.
//
// What a workflow asserts on is `submitted`: what was asked for, and what
// was not.

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
