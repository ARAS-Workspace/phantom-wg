# ADR-0002 — Extension Gate Mechanism

## Status

Accepted — 2026-05-09

The following parts of this ADR have been superseded by ADR-0006 (***Measured Activation***): the closing paragraph of item 1 (the principle that state changes are exclusively user-driven), the "idempotent at the OS level" qualifier in item 4, and item 6's list of sources. The remaining decisions stay in force.

## Context

Phantom-WG Mac depends on three macOS system extensions that ship alongside the host app:

- **PhantomTunnel** — `NEPacketTunnelProvider`, WireGuard or wstunnel + WireGuard tunnel connections
- **PhantomSplitTunnel** — `NETransparentProxyProvider`, per-app traffic bypass
- **PhantomDNSProxy** — `NEDNSProxyProvider`, DNS-routing guarantee through the selected network interface for apps bypassed by PhantomSplitTunnel

Let me start with **system extensions** themselves. On macOS, system extensions are not silent dependencies. The first time each one is loaded, the OS demands explicit user approval through ***System Settings***; the user can disable any of them later from the same panel. The bundle can be replaced in place during an upgrade, removed during an uninstall, or end up in an inconsistent state if the user denies an authorization prompt halfway through. None of these paths can be skipped from inside the app. Apple's `OSSystemExtensionRequest` API is event-driven, runs asynchronously, and surfaces every transition through delegate callbacks rather than a single status query.

Beyond that, the naïve principle of "ask the OS for the system extension's status, mirror it on the UI" is insufficient for two reasons.

- ***First***, `propertiesRequest` is the only API that surveys installed system extensions, but it returns an empty array both for "the extension was never installed" and for "the extension is installed but disabled in System Settings". These two states are operationally distinct: the first needs a fresh activation request, the second needs the user to flip a toggle in *System Settings* — yet the API gives the same shape of reply. Disambiguating requires correlating the reply with whether an activation request has just resolved `.completed`; without that hint, `Extension Gate` will mis-classify a disabled system extension as if it were never installed and re-trigger the OS install flow against the user a second time.

- ***Second***, the user must be able to recover from drop-back. If they later disable a system extension in System Settings, kill its process, or trigger an upgrade that requires a replacement, the app's tunnel UI must not silently continue as if everything were fine. The app needs a single boolean its root view can bind to ("are all three system extensions live?") plus a deterministic UX path back to `Extension Gate` whenever any extension drops out of `.activated`.

## Decision

The activation surface is implemented as a generic per-bundle controller backed by a higher-level coordinator and a dedicated root view; the host app keys off a single readiness boolean.

1. **`ExtensionGateController` — one per bundle.** The controller wraps a single `bundleID + displayName` pair and projects every `OSSystemExtensionRequest` signal onto a closed `Status` enum:

   - `unknown` — initial cold state, no query has resolved yet.
   - `notInstalled` — `propertiesRequest` returned no live entry and no activation has been issued recently.
   - `activating` — an activation request is in flight.
   - `needsApproval` — Apple wants user input (a *System Settings toggle* or *OS Prompt*) before the system extension can move forward.
   - `activated` — `propertiesRequest` shows a live entry with `isEnabled = true` and no pending approval flag.
   - `failed(String)` — terminal error (code signature, system policy, missing entitlement, validation failure, …).

   State changes are user-driven. There is no background polling; transitions only happen in response to a button press (`activate()`, `refresh()`, `deactivate()`) or an *OS delegate callback*.

2. **`pendingActivationCompleted` flag** disambiguates the empty-properties anomaly. When an activation request resolves `.completed`, the controller arms this flag and immediately re-issues `propertiesRequest`. The next properties reply runs through the following rule:

   - Live entry found → status comes from the entry's `isEnabled` / `isAwaitingUserApproval` flags.
   - No live entry, flag was armed → the system extension is registered but disabled in System Settings; status becomes `needsApproval` and the user is guided to *System Settings*.
   - No live entry, flag not armed, controller still in `unknown` → genuinely not installed; status becomes `notInstalled`.
   - No live entry, flag not armed, controller in any other state → transient OS query lag; no-op.

   Replacement upgrades — Apple may report duplicate live versions during a version transition — are handled by `pickLive`, which prefers the entry with `isEnabled = true`, then `isAwaitingUserApproval = true`, then any live entry. The chosen entry reflects the version the system is actually running, not the older version being uninstalled.

3. **`ExtensionGateCoordinator`** owns the three controllers, exposes a single `allReady` boolean to the root view, and re-issues `checkAll()` whenever the app comes to the foreground via the `NSApplication.didBecomeActiveNotification` observer. This is what catches drop-backs: a user who disables a system extension in System Settings and then switches back to the app finds that `Extension Gate` has already re-evaluated state. `ExtensionGateCoordinator` also exposes `uninstallAll()` for the local *settings* menu *uninstall* flow; it sequentially deactivates the three system extensions so the user can fully remove the system extensions the app depends on in one action.

4. **`ExtensionGateView` + `ExtensionGateRow` — the only UI the user sees until `allReady`.** The root view (`PhantomApp`) renders the `Extension Gate` panel whenever any controller is not `.activated`; the tunnel UI is unreachable in any other case. Each row maps the controller's status to:

   - A status icon (green check, orange warning, grey x, red error, spinner).
   - A localized status sentence.
   - A contextual action button (`Activate`, `Open System Settings`, `Retry`).
   - An inline error message for the `.failed` status.

   The "*Open System Settings*" path is defensive: the row always re-issues `activate()` before opening *System Settings*, which is idempotent at the OS level (a missing system extension installs, a pending approval surfaces the prompt again, an already-active extension silently resolves `.completed`). This guarantees that the toggle the user is about to look for actually exists in the Network Extensions pane.

5. **Failure mapping is exhaustive.** Every documented `OSSystemExtensionError.Code` has a localized user message: `authorizationRequired` → `needsApproval`; `extensionNotFound` → `notInstalled`; `unsupportedParentBundleLocation`, `codeSignatureInvalid`, `validationFailed`, `forbiddenBySystemPolicy`, `missingEntitlement` → terminal `.failed` with case-specific copy; unknown codes fall back to a generic message that surfaces the raw code so a future user can report it.

6. **No persisted `Extension Gate` state.** The controllers cache no opinion of their own beyond the in-flight `pendingActivationCompleted` flag. Every status decision is re-derived from `propertiesRequest` replies and delegate callbacks. This avoids the class of bugs where the app's persisted view of the world diverges from the operating system kernel's actual system extension registry. The operating system is the only ***ground truth***.

## Consequences

- **Single readiness boolean.** `allReady` is the only signal `PhantomApp` consumes. Every `Extension Gate` state-machine concern collapses into one binary check at the root, and the tunnel user interface stays unreachable until all three extensions report `.activated`.

- **Recoverable drop-backs.** If a user disables a system extension via the *System Settings* panel, kills its running process, or runs a replacement upgrade, switching back to the app re-evaluates state via the `didBecomeActive` observer and the root view falls back to `Extension Gate`. The tunnel user interface never silently continues past a degraded state.

- **Three consent dialogs on first install.** The user sees three separate *System Settings* prompts the first time the app launches. This is unavoidable since Apple does not group multiple system extensions under a single consent.

- **Bound to Apple's framework.** `propertiesRequest` semantics are not formally specified; the empty-array-on-disabled behaviour is empirical and could change in a future macOS release. The `pendingActivationCompleted` workaround is documented in the controller. This means that if Apple changes the contract, the failure mode will be easy to locate. `OSSystemExtensionError.Code.validationFailed` is the most generic terminal code Apple emits and our message reflects that. A more precise diagnosis requires reading and evaluating the OS-side logs.

- **Manual test matrix.** ***Controller*** has been exercised across the user-driven scenarios it was designed for.
  - Cold boot with the extension already enabled
  - Fresh Install (first launch)
  - Installed but disabled in System Settings
  - Replacement upgrade (version transition)
  - Removing all three extensions through `uninstallAll()`

- **No background polling.** Power and runtime cost are zero between user interactions. `Extension Gate` only does work when the user takes an action or returns to the app.
