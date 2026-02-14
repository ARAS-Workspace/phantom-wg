#ifndef WSTUNNEL_MAC_H
#define WSTUNNEL_MAC_H

#include <stdint.h>
#include <stdbool.h>

/*
 * wstunnel-mac: C FFI wrapper for wstunnel (macOS)
 *
 * Wraps wstunnel identically to wstunnel-cli: constructs the same Client
 * config and calls run_client() internally. Only the interface differs.
 *
 * Usage:
 *   1. (Optional) wstunnel_set_log_callback()
 *   2. wstunnel_init_logging()
 *   3. config = wstunnel_config_new()
 *   4. wstunnel_config_set_remote_url(config, ...)
 *   5. wstunnel_config_add_tunnel_udp/tcp/socks5(config, ...)
 *   6. wstunnel_client_start(config)
 *   7. wstunnel_config_free(config)
 *   ...
 *   8. wstunnel_client_stop()
 */

/* ═══════════════════════════════════════════════════════════════
 * Return codes
 * ═══════════════════════════════════════════════════════════════ */
#define WS_OK                    0
#define WS_ERR_ALREADY_RUNNING  -1
#define WS_ERR_INVALID_PARAM    -2
#define WS_ERR_RUNTIME          -3
#define WS_ERR_START_FAILED     -4
#define WS_ERR_NOT_RUNNING      -5
#define WS_ERR_CONFIG_NULL      -6

/* ═══════════════════════════════════════════════════════════════
 * Log levels
 * ═══════════════════════════════════════════════════════════════ */
#define WS_LOG_ERROR  0
#define WS_LOG_WARN   1
#define WS_LOG_INFO   2
#define WS_LOG_DEBUG  3
#define WS_LOG_TRACE  4

/* ═══════════════════════════════════════════════════════════════
 * Opaque config handle
 * ═══════════════════════════════════════════════════════════════ */
typedef struct WstunnelConfig WstunnelConfig;

/* ═══════════════════════════════════════════════════════════════
 * Log callback
 * ═══════════════════════════════════════════════════════════════ */

typedef void (*WstunnelLogCallback)(int32_t level, const char *message, void *context);

void wstunnel_set_log_callback(WstunnelLogCallback callback, void *context);
void wstunnel_init_logging(int32_t log_level);

/* ═══════════════════════════════════════════════════════════════
 * Config Builder
 * ═══════════════════════════════════════════════════════════════ */

WstunnelConfig *wstunnel_config_new(void);
void wstunnel_config_free(WstunnelConfig *config);

/* Remote server URL (required) — e.g. "wss://example.com:443" */
int32_t wstunnel_config_set_remote_url(WstunnelConfig *config, const char *url);

/* HTTP upgrade path prefix (default: "v1", used as secret in Ghost Mode) */
int32_t wstunnel_config_set_http_upgrade_path_prefix(WstunnelConfig *config, const char *prefix);

/* HTTP upgrade credentials for Basic auth — format: "USER:PASS" */
int32_t wstunnel_config_set_http_upgrade_credentials(WstunnelConfig *config, const char *credentials);

/* TLS certificate verification (default: false) */
int32_t wstunnel_config_set_tls_verify(WstunnelConfig *config, bool verify);

/* Override TLS SNI domain name */
int32_t wstunnel_config_set_tls_sni_override(WstunnelConfig *config, const char *domain);

/* Disable sending SNI during TLS handshake */
int32_t wstunnel_config_set_tls_sni_disable(WstunnelConfig *config, bool disable);

/* WebSocket ping frequency in seconds (default: 30, 0 to disable) */
int32_t wstunnel_config_set_websocket_ping_frequency(WstunnelConfig *config, uint32_t secs);

/* WebSocket frame masking (default: false) */
int32_t wstunnel_config_set_websocket_mask_frame(WstunnelConfig *config, bool mask);

/* Minimum idle connections in pool (default: 0) */
int32_t wstunnel_config_set_connection_min_idle(WstunnelConfig *config, uint32_t count);

/* Maximum connection retry backoff in seconds (default: 300 = 5 min) */
int32_t wstunnel_config_set_connection_retry_max_backoff(WstunnelConfig *config, uint64_t secs);

/* HTTP proxy for connecting to server — "HOST:PORT" or "http://HOST:PORT" */
int32_t wstunnel_config_set_http_proxy(WstunnelConfig *config, const char *proxy);

/* Add custom HTTP header to upgrade request */
int32_t wstunnel_config_add_http_header(WstunnelConfig *config, const char *name, const char *value);

/* Tokio worker threads (default: 2) */
int32_t wstunnel_config_set_worker_threads(WstunnelConfig *config, uint32_t threads);

/* ─── Tunnel Rules (equivalent to CLI -L flag) ─────────────── */

/* UDP tunnel: -L udp://local_host:local_port:remote_host:remote_port */
int32_t wstunnel_config_add_tunnel_udp(
    WstunnelConfig *config,
    const char     *local_host,
    uint16_t        local_port,
    const char     *remote_host,
    uint16_t        remote_port,
    uint64_t        timeout_secs
);

/* TCP tunnel: -L tcp://local_host:local_port:remote_host:remote_port */
int32_t wstunnel_config_add_tunnel_tcp(
    WstunnelConfig *config,
    const char     *local_host,
    uint16_t        local_port,
    const char     *remote_host,
    uint16_t        remote_port
);

/* SOCKS5 proxy: -L socks5://local_host:local_port */
int32_t wstunnel_config_add_tunnel_socks5(
    WstunnelConfig *config,
    const char     *local_host,
    uint16_t        local_port,
    uint64_t        timeout_secs
);

/* ═══════════════════════════════════════════════════════════════
 * Client Control
 * ═══════════════════════════════════════════════════════════════ */

int32_t wstunnel_client_start(WstunnelConfig *config);
int32_t wstunnel_client_stop(void);
int32_t wstunnel_client_is_running(void);
const char *wstunnel_client_get_last_error(void);
const char *wstunnel_get_version(void);

#endif /* WSTUNNEL_MAC_H */
