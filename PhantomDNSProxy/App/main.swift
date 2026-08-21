import Foundation
import NetworkExtension
import os.log

let bootLog = OSLog(subsystem: "com.remrearas.Phantom-WG-MacOS.PhantomDNSProxy", category: "boot")
os_log("PhantomDNSProxy system extension BOOT", log: bootLog, type: .default)

ProxyConfigDaemon.shared = ProxyConfigDaemon(
    machServiceName: ProxyConfigService.dnsProxy,
    subsystem: "com.remrearas.Phantom-WG-MacOS.PhantomDNSProxy"
)
ProxyConfigDaemon.shared?.start()

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}

os_log("PhantomDNSProxy entering dispatchMain", log: bootLog, type: .default)

dispatchMain()
