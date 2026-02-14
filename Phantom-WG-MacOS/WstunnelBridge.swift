import Foundation

/// Swift bridge for wstunnel-ios C FFI.
/// Wraps wstunnel identically to wstunnel-cli — same Client config, same run_client().
/// Only the interface differs: C FFI → Swift instead of CLI args.
enum WstunnelBridge {

    // MARK: - Error Codes

    enum WstunnelError: Error, LocalizedError {
        case alreadyRunning
        case invalidParameter
        case runtimeError
        case startFailed
        case notRunning
        case configNull
        case unknown(Int32)

        init(code: Int32) {
            switch code {
            case -1: self = .alreadyRunning
            case -2: self = .invalidParameter
            case -3: self = .runtimeError
            case -4: self = .startFailed
            case -5: self = .notRunning
            case -6: self = .configNull
            default: self = .unknown(code)
            }
        }

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: "Wstunnel is already running"
            case .invalidParameter: "Invalid parameter"
            case .runtimeError: "Failed to create runtime"
            case .startFailed: "Failed to start tunnel"
            case .notRunning: "Tunnel is not running"
            case .configNull: "Config is null"
            case .unknown(let code): "Unknown error (\(code))"
            }
        }
    }

    // MARK: - Log Levels

    enum LogLevel: Int32 {
        case error = 0
        case warn  = 1
        case info  = 2
        case debug = 3
        case trace = 4
    }

    // MARK: - Log Callback

    private static var _logHandler: ((LogLevel, String) -> Void)?

    /// Set a Swift closure to receive all wstunnel tracing log messages.
    /// Call BEFORE `initLogging()`.
    static func setLogCallback(_ handler: @escaping (LogLevel, String) -> Void) {
        _logHandler = handler
        wstunnel_set_log_callback({ level, messageCStr, _ in
            guard let messageCStr = messageCStr else { return }
            let message = String(cString: messageCStr)
            let logLevel = LogLevel(rawValue: level) ?? .info
            WstunnelBridge._logHandler?(logLevel, message)
        }, nil as UnsafeMutableRawPointer?)
    }

    static func removeLogCallback() {
        _logHandler = nil
        let nullCallback: WstunnelLogCallback? = nil
        let nullUserData: UnsafeMutableRawPointer? = nil
        wstunnel_set_log_callback(nullCallback, nullUserData)
    }

    // MARK: - Logging

    static func initLogging(level: LogLevel) {
        wstunnel_init_logging(level.rawValue)
    }

    static func initLogging(level: Int32) {
        wstunnel_init_logging(level)
    }

    // MARK: - Config Builder

    /// Mirrors wstunnel-cli's Client config.
    /// Build with chained calls, then call start().
    final class Config {
        private let handle: OpaquePointer

        init() {
            handle = wstunnel_config_new()
        }

        deinit {
            wstunnel_config_free(handle)
        }

        // ─── Required ────────────────────────────────

        /// Remote wstunnel server URL (e.g. "wss://example.com:443")
        @discardableResult
        func setRemoteURL(_ url: String) throws -> Config {
            let result = wstunnel_config_set_remote_url(handle, url)
            if result != 0 { throw WstunnelError(code: result) }
            return self
        }

        // ─── Connection / Path ───────────────────────

        /// HTTP upgrade path prefix. Default "v1". Used as secret in Ghost Mode.
        @discardableResult
        func setHTTPUpgradePathPrefix(_ prefix: String) throws -> Config {
            let result = wstunnel_config_set_http_upgrade_path_prefix(handle, prefix)
            if result != 0 { throw WstunnelError(code: result) }
            return self
        }

        /// HTTP upgrade credentials for Basic auth. Format: "USER:PASS"
        @discardableResult
        func setHTTPUpgradeCredentials(_ credentials: String) throws -> Config {
            let result = wstunnel_config_set_http_upgrade_credentials(handle, credentials)
            if result != 0 { throw WstunnelError(code: result) }
            return self
        }

        /// Minimum idle connections in pool. Default: 0.
        @discardableResult
        func setConnectionMinIdle(_ count: UInt32) -> Config {
            wstunnel_config_set_connection_min_idle(handle, count)
            return self
        }

        /// Maximum connection retry backoff in seconds. Default: 300 (5 min).
        @discardableResult
        func setConnectionRetryMaxBackoff(seconds: UInt64) -> Config {
            wstunnel_config_set_connection_retry_max_backoff(handle, seconds)
            return self
        }

        // ─── WebSocket ──────────────────────────────

        /// WebSocket ping frequency in seconds. Default: 30. Set 0 to disable.
        @discardableResult
        func setWebSocketPingFrequency(seconds: UInt32) -> Config {
            wstunnel_config_set_websocket_ping_frequency(handle, seconds)
            return self
        }

        /// Enable WebSocket frame masking. Default: false.
        @discardableResult
        func setWebSocketMaskFrame(_ mask: Bool) -> Config {
            wstunnel_config_set_websocket_mask_frame(handle, mask)
            return self
        }

        // ─── TLS ────────────────────────────────────

        /// Enable/disable TLS certificate verification. Default: false.
        @discardableResult
        func setTLSVerify(_ verify: Bool) -> Config {
            wstunnel_config_set_tls_verify(handle, verify)
            return self
        }

        /// Override TLS SNI domain name.
        @discardableResult
        func setTLSSNIOverride(_ domain: String) throws -> Config {
            let result = wstunnel_config_set_tls_sni_override(handle, domain)
            if result != 0 { throw WstunnelError(code: result) }
            return self
        }

        /// Disable sending SNI during TLS handshake.
        @discardableResult
        func setTLSSNIDisable(_ disable: Bool) -> Config {
            wstunnel_config_set_tls_sni_disable(handle, disable)
            return self
        }

        // ─── HTTP ───────────────────────────────────

        /// Set HTTP proxy. Format: "HOST:PORT" or "http://HOST:PORT"
        @discardableResult
        func setHTTPProxy(_ proxy: String) throws -> Config {
            let result = wstunnel_config_set_http_proxy(handle, proxy)
            if result != 0 { throw WstunnelError(code: result) }
            return self
        }

        /// Add a custom HTTP header to the upgrade request.
        @discardableResult
        func addHTTPHeader(name: String, value: String) throws -> Config {
            let result = wstunnel_config_add_http_header(handle, name, value)
            if result != 0 { throw WstunnelError(code: result) }
            return self
        }

        // ─── Runtime ────────────────────────────────

        /// Set Tokio worker threads. Default: 2.
        @discardableResult
        func setWorkerThreads(_ threads: UInt32) -> Config {
            wstunnel_config_set_worker_threads(handle, threads)
            return self
        }

        // ─── Tunnel Rules (equivalent to CLI -L) ────

        /// Add UDP tunnel: -L udp://localHost:localPort:remoteHost:remotePort
        @discardableResult
        func addTunnelUDP(
            localHost: String = "127.0.0.1",
            localPort: UInt16,
            remoteHost: String,
            remotePort: UInt16,
            timeoutSeconds: UInt64 = 0
        ) throws -> Config {
            let result = wstunnel_config_add_tunnel_udp(
                handle, localHost, localPort, remoteHost, remotePort, timeoutSeconds
            )
            if result != 0 { throw WstunnelError(code: result) }
            return self
        }

        /// Add TCP tunnel: -L tcp://localHost:localPort:remoteHost:remotePort
        @discardableResult
        func addTunnelTCP(
            localHost: String = "127.0.0.1",
            localPort: UInt16,
            remoteHost: String,
            remotePort: UInt16
        ) throws -> Config {
            let result = wstunnel_config_add_tunnel_tcp(
                handle, localHost, localPort, remoteHost, remotePort
            )
            if result != 0 { throw WstunnelError(code: result) }
            return self
        }

        /// Add SOCKS5 proxy: -L socks5://localHost:localPort
        @discardableResult
        func addTunnelSOCKS5(
            localHost: String = "127.0.0.1",
            localPort: UInt16,
            timeoutSeconds: UInt64 = 0
        ) throws -> Config {
            let result = wstunnel_config_add_tunnel_socks5(
                handle, localHost, localPort, timeoutSeconds
            )
            if result != 0 { throw WstunnelError(code: result) }
            return self
        }

        // ─── Start ──────────────────────────────────

        /// Start the wstunnel client with this config.
        /// Internally calls wstunnel::run_client() exactly like wstunnel-cli.
        func start() throws {
            let result = wstunnel_client_start(handle)
            if result != 0 { throw WstunnelError(code: result) }
        }
    }

    // MARK: - Client Control

    static func stop() throws {
        let result = wstunnel_client_stop()
        if result != 0 {
            throw WstunnelError(code: result)
        }
    }

    static var isRunning: Bool {
        wstunnel_client_is_running() == 1
    }

    static var lastError: String? {
        guard let ptr = wstunnel_client_get_last_error() else { return nil }
        return String(cString: ptr)
    }

    static var version: String {
        String(cString: wstunnel_get_version())
    }
}
