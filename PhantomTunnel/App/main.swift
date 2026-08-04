import Foundation
import NetworkExtension
import os.log

let bootLog = OSLog(subsystem: "com.remrearas.Phantom-WG-MacOS.PhantomTunnel", category: "boot")
os_log("PhantomTunnel system extension BOOT", log: bootLog, type: .default)

// Custody server first: the app stores a tunnel's secrets at import
// time, long before that tunnel is ever activated, so the listener
// must be up before any provider exists.
TunnelVaultDaemon.shared = TunnelVaultDaemon(
    machServiceName: TunnelVaultService.machServiceName,
    subsystem: "com.remrearas.Phantom-WG-MacOS.PhantomTunnel"
)
TunnelVaultDaemon.shared?.start()

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}

os_log("PhantomTunnel entering dispatchMain", log: bootLog, type: .default)

dispatchMain()
