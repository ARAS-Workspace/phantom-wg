// Sanity Check
//
// Proves the harness is wired to the system this build talks to before
// anything else is measured. No session is raised.
//
// It runs first in the catalogue because every verdict printed after it
// is a claim about the system it names.
//
// Scenarios:
//
//   A — System Under Test
//       Names the build (version and build number) and the system: the
//       simulated Network Extension on a simulator, the system's on a
//       device. Every listed tunnel's provider must be of that system's
//       kind; a mismatch ABORTS the suite, because every later verdict
//       would describe another system than the one named. An empty list
//       has no provider to read the kind from, so the step skips.
//
//   B — Keychain Round Trip In The App Group
//       Seals a throwaway value with `Keychain.makeReference`, reads the
//       access group the Keychain holds for the item, opens it with
//       `openReference`, deletes it with `deleteReference` and opens the
//       reference again. Every tunnel configuration is stored this way,
//       and the tunnel extension reads it out of the app group; a refused
//       write ABORTS the suite, because no later step could store one.

#if DEBUG
import Foundation
import NetworkExtension
import Security

final class SanityWorkflow: TestWorkflow {
    override var displayName: String { "Sanity Check" }

    /// The app group the app and the tunnel extension are both entitled to.
    private static let appGroup = "group.com.artek.phantom-wg"

    override var steps: [WorkflowStep] {
        [
            WorkflowStep("System Under Test", systemUnderTest),
            WorkflowStep("Keychain Round Trip In The App Group", keychainRoundTrip)
        ]
    }

    /// The access group the Keychain holds for the item `ref` opens.
    private func accessGroup(of ref: Data) -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecValuePersistentRef: ref,
            kSecReturnAttributes: true
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrAccessGroup as String] as? String
    }

    // MARK: - Steps

    func systemUnderTest() async {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        log("build: \(version) (\(build))")

        #if targetEnvironment(simulator)
        let system = "simulated Network Extension (simulator)"
        let ofThisSystem: (TunnelProviding) -> Bool = { $0 is SimulatedTunnelProvider }
        #else
        let system = "system Network Extension (device)"
        let ofThisSystem: (TunnelProviding) -> Bool = { $0 is NETunnelProviderManager }
        #endif
        log("system: \(system)")

        let rows = tunnels.tunnels
        guard !rows.isEmpty else {
            skip("environment: no tunnel listed, provider kind unread")
            return
        }
        let foreign = rows.filter { !ofThisSystem($0.tunnelProvider) }.map(\.name)
        if !check(foreign.isEmpty, "every listed tunnel's provider is of this system's kind (\(rows.count) listed)") {
            abortRun("tunnels on another system than this build's: \(foreign.joined(separator: ", "))")
        }
    }

    func keychainRoundTrip() async {
        let name = "phantom-testengine-\(UUID().uuidString)"
        let value = UUID().uuidString
        let sealed = Keychain.makeReference(containing: value, called: name)
        guard check(sealed != nil, "makeReference seals the item"), let ref = sealed else {
            abortRun("the app group Keychain refused a write; no configuration could be stored")
            return
        }
        var deleted = false
        onTeardown("delete the probe item") {
            if !deleted { Keychain.deleteReference(called: ref) }
        }
        let group = accessGroup(of: ref)
        check(group == Self.appGroup, "the sealed item's access group is the app group (\(group ?? "unread"))")
        check(Keychain.openReference(called: ref) == value, "openReference reads back the sealed value")
        Keychain.deleteReference(called: ref)
        deleted = true
        check(Keychain.openReference(called: ref) == nil, "after deleteReference the reference opens nothing")
    }
}
#endif
