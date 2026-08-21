import Foundation
import NetworkExtension
import os.log

let bootLog = OSLog(subsystem: "com.remrearas.Phantom-WG-MacOS.PhantomSplitTunnel", category: "boot")
os_log("PhantomSplitTunnel system extension BOOT", log: bootLog, type: .default)

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
