# ADR-0007 — Post-Acceptance Hardening of the Activation and Vault Surfaces

## Status

Accepted — 2026-08-08

This is an ADR written alongside a hardening pass. It gathers two hardenings in a single document; neither reverses a decision, each only narrows one.

- Fix: stop re-activating a live extension when opening Settings from the gate (cf1eac7)

- Fix: roll back the vault store on a failed rewrite, propagate broken enumerations, and pin the vault peer identifier (1db8811)

## Context

A review after 2026-08-05 showed that the accepted text had fallen behind the code on two surfaces. On both, the code behaves more strictly than the document describes.

### 1. The gate row's activation is now conditional

The System Settings button on the `.needsApproval` row previously called `activate()` unconditionally before opening Settings (ADR-0002 item 4). ADR-0006 measured that an activation request, even for a bundle byte-identical to the installed one, rebuilds the extension through a full replacement and terminates the running provider process in the act. `controller.status` is read the moment the button is pressed; if a foreground refresh moves the status to `.activated` in the short window between the panel being drawn and the button being pressed, the unconditional call would rebuild and terminate the extension running at that instant. Activation is now issued only while the status is still `.notInstalled` or `.needsApproval`:

```swift
onOpenSettings: {
    if controller.status == .notInstalled
        || controller.status == .needsApproval {
        controller.activate()
    }
    openSystemSettings()
}
```

The `.needsApproval` call is preserved; its purpose is to surface the approval prompt again, which is item 4's original function. The only state left out is `.activated`: sending an activation to a running extension rebuilds and terminates it. File: `Phantom-WG-MacOS/App/ExtensionGate/ExtensionGateView.swift`.

### 2. The vault daemon's peer requirement now pins the identifier too

The vault and proxy daemons share the same XPC skeleton and pin the peer to the team signature (ADR-0004 item 6, ADR-0005 item 2). But the vault daemon hands out the private key, preshared key, and wstunnel secret through `fetchVault` and `storeVault`; the proxy daemon only writes the bypass list. A binary the team signs but that is not the app (a debug build, a test harness, another product) could reach the key-custody RPCs with the team pin alone. The vault daemon now pins the identifier as well:

```swift
private static let peerCodeRequirement =
    #"identifier "com.remrearas.Phantom-WG-MacOS" and anchor apple generic and certificate leaf[subject.OU] = "9C5SL5H7CM""#
```

The requirement is enforced off the kernel audit token and is race-free. The proxy daemon stays on the team pin alone because its threat model is different. Files: `PhantomTunnel/Infrastructure/TunnelVaultDaemon.swift`, `Extensions/Domain/IPC/ProxyConfigDaemon.swift`.

## Consequences

- Opening Settings no longer kills an extension that went live at the moment of the click; the `.needsApproval` approval prompt continues as before.
- ADR-0006's principle that "no activation call is unmeasured" now covers the last call site as well.
- The XPC surface that hands out vault keys is now closed to unrelated binaries the team signs as well; the posture is stricter than what ADR-0005 documents.
- Both changes are restrictive at their core. No flow gains a new capability; the two surfaces simply permit less.

## Related Records

- ADR-0002 item 4: the behavioral clause was narrowed by this ADR.
- ADR-0004 item 6: the proxy peer pin; unchanged, cited for contrast.
- ADR-0005 item 2: the vault peer pin was tightened by this ADR.
- ADR-0006 item 4: measured activation; extended to the last call site by this ADR.
