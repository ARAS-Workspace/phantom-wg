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
// Test Engine: Workflow Catalogue
//
// The ordered list a run executes, top to bottom. Order is part of the
// arrangement rather than presentation: `SanityWorkflow` measures the
// environment before anything drives it, and `SplitControlPlaneWorkflow`
// raises a real proxy session, so it runs last.
//
// A workflow reaches a run only by appearing here.

#if DEBUG
import Foundation

@MainActor
enum TestCatalog {
    static var workflows: [TestWorkflow] {
        [
            SanityWorkflow(),
            VaultIntegrityWorkflow(),
            IsolationWorkflow(),
            ActivationSeamWorkflow(),
            ConfigContractWorkflow(),
            PhantomTunnelWorkflow(.standalone),
            PhantomTunnelWorkflow(.ghost),
            RecoverySwitchWorkflow(),
            UnreachableWorkflow(),
            ExtensionGateWorkflow(),
            TunnelEditWorkflow(),
            SplitControlPlaneWorkflow(),
        ]
    }
}
#endif
