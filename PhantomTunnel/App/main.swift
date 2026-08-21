import Foundation
import NetworkExtension
import os.log

let bootLog = OSLog(subsystem: "com.remrearas.Phantom-WG-MacOS.PhantomTunnel", category: "boot")
os_log("PhantomTunnel system extension BOOT", log: bootLog, type: .default)

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
