import Foundation

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

    static func setLogCallback(_ handler: @escaping (LogLevel, String) -> Void) {
        _logHandler = handler
        wstunnel_set_log_callback({ level, messageCStr, _ in
            guard let messageCStr = messageCStr else { return }
            let message = String(cString: messageCStr)
            let logLevel = LogLevel(rawValue: level) ?? .info
            WstunnelBridge._logHandler?(logLevel, message)
        }, nil as UnsafeMutableRawPointer?)
    }

    // MARK: - Logging

    static func initLogging(level: LogLevel) {
        wstunnel_init_logging(level.rawValue)
    }

    // MARK: - Config Builder

    final class Config {
        private let handle: OpaquePointer

        init() {
            handle = wstunnel_config_new()
        }

        deinit {
            wstunnel_config_free(handle)
        }

        @discardableResult
        func setRemoteURL(_ url: String) throws -> Config {
            let result = wstunnel_config_set_remote_url(handle, url)
            if result != 0 { throw WstunnelError(code: result) }
            return self
        }

        @discardableResult
        func setHTTPUpgradePathPrefix(_ prefix: String) throws -> Config {
            let result = wstunnel_config_set_http_upgrade_path_prefix(handle, prefix)
            if result != 0 { throw WstunnelError(code: result) }
            return self
        }

        @discardableResult
        func addTunnelUDP(
            localHost: String,
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
