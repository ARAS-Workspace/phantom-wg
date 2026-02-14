import Foundation
import NetworkExtension
import os.log

let bootLog = OSLog(subsystem: "com.remrearas.Phantom-WG-MacOS.PhantomTunnel", category: "boot")
os_log("PhantomTunnel system extension BOOT", log: bootLog, type: .default)
NSLog("PhantomTunnel system extension BOOT (NSLog)")

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}

os_log("PhantomTunnel entering dispatchMain", log: bootLog, type: .default)
NSLog("PhantomTunnel entering dispatchMain (NSLog)")

dispatchMain()
