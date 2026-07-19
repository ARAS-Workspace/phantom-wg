import Foundation

enum DNSResolver {

    /// Resolves a hostname to its IPv4 addresses using getaddrinfo.
    static func resolveIPv4(_ hostname: String, timeout: TimeInterval = 5.0) -> [String] {
        resolve(hostname, family: AF_INET, timeout: timeout)
    }

    /// Resolves a hostname to its IPv6 addresses using getaddrinfo.
    static func resolveIPv6(_ hostname: String, timeout: TimeInterval = 5.0) -> [String] {
        resolve(hostname, family: AF_INET6, timeout: timeout)
    }

    // MARK: - Private

    private static func resolve(_ hostname: String, family: Int32, timeout: TimeInterval) -> [String] {
        var result: [String] = []
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            result = resolveSync(hostname, family: family)
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            TunnelLogger.log(.tunnel, "WARNING: DNS resolution timed out for \(hostname)")
            return []
        }
        return result
    }

    private static func resolveSync(_ hostname: String, family: Int32) -> [String] {
        var hints = addrinfo()
        hints.ai_family = family
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, nil, &hints, &result) == 0, let info = result else {
            return []
        }
        defer { freeaddrinfo(info) }

        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = info
        while let addr = current {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr.pointee.ai_addr, addr.pointee.ai_addrlen,
                           &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buf)
                if !addresses.contains(ip) { addresses.append(ip) }
            }
            current = addr.pointee.ai_next
        }
        return addresses
    }
}
