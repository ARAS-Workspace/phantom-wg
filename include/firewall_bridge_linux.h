/**
 * firewall_bridge_linux.h — Kernel operations backend
 *
 * Pure nftables + netlink operations. No database, no state machine.
 * State management, persistence, presets → Python side (ufw pattern).
 *
 * Functions returning char* (JSON) must be freed with firewall_bridge_free_string().
 * Functions returning const char* are static and must NOT be freed.
 * All other functions return 0 on success, negative on error.
 */

#ifndef FIREWALL_BRIDGE_LINUX_H
#define FIREWALL_BRIDGE_LINUX_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Error codes ---- */

#define FW_OK                    0
#define FW_ERR_NFT_FAILED       -3
#define FW_ERR_NETLINK_FAILED   -4
#define FW_ERR_INVALID_PARAM    -5
#define FW_ERR_IO_ERROR         -6
#define FW_ERR_PERMISSION       -7

/* ---- nftables ---- */

int32_t     nft_init(void);
void        nft_close(void);

int64_t     nft_add_rule(const char* chain, const char* action,
                         int32_t family, const char* proto, int32_t dport,
                         const char* source, const char* destination,
                         const char* in_iface, const char* out_iface,
                         const char* state_match, const char* comment);

int32_t     nft_remove_rule(const char* chain, uint64_t handle);
int32_t     nft_flush_table(void);
char*       nft_list_table(void);   /* JSON, caller frees */

/* ---- Routing ---- */

int32_t     rt_table_ensure(uint32_t table_id, const char* table_name);

/* family is AF_INET (2) or AF_INET6 (10). */

int32_t     rt_policy_add(const char* from_network, const char* to_network,
                          const char* table_name, uint32_t priority,
                          int32_t family);
int32_t     rt_policy_delete(const char* from_network, const char* to_network,
                             const char* table_name, uint32_t priority,
                             int32_t family);

int32_t     rt_route_add(const char* destination, const char* device,
                         const char* table_name, int32_t family);
int32_t     rt_route_delete(const char* destination, const char* device,
                            const char* table_name, int32_t family);

int32_t     rt_enable_ip_forward(void);
int32_t     rt_flush_cache(void);

/* ---- Utility ---- */

const char* firewall_bridge_get_version(void);      /* static, do NOT free */
const char* firewall_bridge_get_last_error(void);    /* static, do NOT free */
void        firewall_bridge_free_string(char* ptr);

#ifdef __cplusplus
}
#endif

#endif /* FIREWALL_BRIDGE_LINUX_H */
