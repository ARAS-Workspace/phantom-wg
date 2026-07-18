import Foundation
import NetworkExtension
import os.log

let bootLog = OSLog(subsystem: "com.remrearas.Phantom-WG-MacOS.PhantomSplitTunnel", category: "boot")
os_log("PhantomSplitTunnel system extension BOOT", log: bootLog, type: .default)

// Listener must answer before any client connects; the provider is
// lazy-spawned by the OS on the first outbound flow.
ProxyConfigDaemon.shared = ProxyConfigDaemon(
    machServiceName: ProxyConfigService.splitTunnel,
    subsystem: "com.remrearas.Phantom-WG-MacOS.PhantomSplitTunnel"
)
ProxyConfigDaemon.shared?.start()

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}

os_log("PhantomSplitTunnel entering dispatchMain", log: bootLog, type: .default)

dispatchMain()
