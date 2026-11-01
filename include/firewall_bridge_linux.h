/**
 * firewall_bridge_linux.h — Kernel operations backend
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
#define FW_ERR_NOT_INITIALIZED  -8

/* ---- nftables ---- */

int32_t     nft_init(void);
void        nft_close(void);

int64_t     nft_add_rule(const char* chain, const char* action,
                         int32_t family, const char* proto, int32_t dport,
                         const char* source, const char* destination,
                         const char* in_iface, const char* out_iface,
                         const char* state_match, const char* comment);

int32_t     nft_remove_rule(const char* chain, uint64_t handle);

/* One rule for nft_replace_rules; the fields are nft_add_rule's. */
typedef struct {
    const char* chain;
    const char* action;
    int32_t     family;
    const char* proto;
    int32_t     dport;
    const char* source;
    const char* destination;
    const char* in_iface;
    const char* out_iface;
    const char* state_match;
    const char* comment;
} fw_nft_rule;

/* Flush the phantom table and add rules[0..count) in one nft transaction;
 * on success handles[i] is rule i's handle. On an error the table is as it
 * was and handles is not written. */
int32_t     nft_replace_rules(const fw_nft_rule* rules, int32_t count,
                              uint64_t* handles);
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

/* Deprecated: pointer is invalidated by the next recorded error.
 * Prefer firewall_bridge_get_last_error_copy. Do NOT free. */
const char* firewall_bridge_get_last_error(void);

/* Copy last error into buf (at most len-1 bytes + NUL), under the
 * error lock. Returns bytes copied, or FW_ERR_INVALID_PARAM for null
 * buf / len <= 0. 0 = nothing copied: no error recorded, or len == 1.
 * buf must not point into the string firewall_bridge_get_last_error
 * returned. */
int32_t     firewall_bridge_get_last_error_copy(char* buf, int32_t len);

void        firewall_bridge_free_string(char* ptr);

#ifdef __cplusplus
}
#endif

#endif /* FIREWALL_BRIDGE_LINUX_H */
