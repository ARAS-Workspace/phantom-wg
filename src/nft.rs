//! nftables operations via libnftables C library.
//!
//! All firewall rules live in the `inet phantom` table.
//! This avoids conflicts with UFW, iptables, or any other rulesets.
//! No DB dependency — pure kernel operations.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

// ---------------------------------------------------------------------------
// libnftables FFI bindings
// ---------------------------------------------------------------------------

#[allow(non_camel_case_types)]
enum nft_ctx {}

const NFT_CTX_DEFAULT: u32 = 0;
const NFT_CTX_OUTPUT_JSON: u32 = 1 << 4;
const NFT_CTX_OUTPUT_HANDLE: u32 = 1 << 3;

extern "C" {
    fn nft_ctx_new(flags: u32) -> *mut nft_ctx;
    fn nft_ctx_free(ctx: *mut nft_ctx);
    fn nft_ctx_buffer_output(ctx: *mut nft_ctx) -> i32;
    fn nft_ctx_buffer_error(ctx: *mut nft_ctx) -> i32;
    fn nft_ctx_get_output_buffer(ctx: *const nft_ctx) -> *const c_char;
    fn nft_ctx_get_error_buffer(ctx: *const nft_ctx) -> *const c_char;
    fn nft_run_cmd_from_buffer(ctx: *mut nft_ctx, buf: *const c_char) -> i32;
    fn nft_ctx_output_set_flags(ctx: *mut nft_ctx, flags: u32);
}

// ---------------------------------------------------------------------------
// NftContext — safe wrapper
// ---------------------------------------------------------------------------

pub struct NftContext {
    ctx: *mut nft_ctx,
}

unsafe impl Send for NftContext {}

impl NftContext {
    pub fn new() -> Result<Self, &'static str> {
        let ctx = unsafe { nft_ctx_new(NFT_CTX_DEFAULT) };
        if ctx.is_null() {
            return Err("Failed to create nftables context");
        }
        unsafe {
            nft_ctx_buffer_output(ctx);
            nft_ctx_buffer_error(ctx);
        }
        Ok(Self { ctx })
    }

    pub fn run(&self, cmd: &str) -> Result<String, String> {
        let c_cmd = CString::new(cmd).map_err(|e| e.to_string())?;
        let rc = unsafe { nft_run_cmd_from_buffer(self.ctx, c_cmd.as_ptr()) };
        let output = self.get_output();
        let error = self.get_error();
        if rc != 0 {
            Err(if error.is_empty() {
                format!("nft command failed (rc={}): {}", rc, cmd)
            } else {
                error
            })
        } else {
            Ok(output)
        }
    }

    pub fn run_json(&self, cmd: &str) -> Result<String, String> {
        unsafe { nft_ctx_output_set_flags(self.ctx, NFT_CTX_OUTPUT_JSON | NFT_CTX_OUTPUT_HANDLE); }
        let result = self.run(cmd);
        unsafe { nft_ctx_output_set_flags(self.ctx, NFT_CTX_OUTPUT_HANDLE); }
        result
    }

    fn get_output(&self) -> String {
        unsafe {
            let ptr = nft_ctx_get_output_buffer(self.ctx);
            if ptr.is_null() { String::new() }
            else { CStr::from_ptr(ptr).to_string_lossy().into_owned() }
        }
    }

    fn get_error(&self) -> String {
        unsafe {
            let ptr = nft_ctx_get_error_buffer(self.ctx);
            if ptr.is_null() { String::new() }
            else { CStr::from_ptr(ptr).to_string_lossy().into_owned() }
        }
    }
}

impl Drop for NftContext {
    fn drop(&mut self) {
        if !self.ctx.is_null() {
            unsafe { nft_ctx_free(self.ctx) };
            self.ctx = ptr::null_mut();
        }
    }
}

// ---------------------------------------------------------------------------
// Table + chain management
// ---------------------------------------------------------------------------

const TABLE: &str = "inet phantom";

pub fn ensure_table(nft: &NftContext) -> Result<(), String> {
    nft.run(&format!("add table {TABLE}")).map(|_| ())?;
    nft.run(&format!(
        "add chain {TABLE} input {{ type filter hook input priority 0; policy accept; }}"
    )).map(|_| ())?;
    nft.run(&format!(
        "add chain {TABLE} output {{ type filter hook output priority 0; policy accept; }}"
    )).map(|_| ())?;
    nft.run(&format!(
        "add chain {TABLE} forward {{ type filter hook forward priority 0; policy accept; }}"
    )).map(|_| ())?;
    nft.run(&format!(
        "add chain {TABLE} prerouting {{ type nat hook prerouting priority -100; policy accept; }}"
    )).map(|_| ())?;
    nft.run(&format!(
        "add chain {TABLE} postrouting {{ type nat hook postrouting priority 100; policy accept; }}"
    )).map(|_| ())?;
    Ok(())
}

pub fn flush_table(nft: &NftContext) -> Result<(), String> {
    nft.run(&format!("flush table {TABLE}")).map(|_| ())
}

pub fn list_table(nft: &NftContext) -> Result<String, String> {
    nft.run_json(&format!("list table {TABLE}"))
}

// ---------------------------------------------------------------------------
// Rule operations — parametric, no DB dependency
// ---------------------------------------------------------------------------

/// Add a firewall rule. Returns nft handle on success.
/// Parameters map directly to nft rule expression components.
pub fn add_rule(
    nft: &NftContext,
    chain: &str,
    action: &str,
    family: i32,
    proto: &str,
    dport: i32,
    source: &str,
    destination: &str,
    in_iface: &str,
    out_iface: &str,
    state_match: &str,
    comment: &str,
) -> Result<u64, String> {
    let cmd = build_rule_cmd(chain, action, family, proto, dport,
                              source, destination, in_iface, out_iface,
                              state_match, comment)?;
    nft.run(&cmd)?;

    // Find the handle of the newly added rule
    let chain_json = nft.run_json(&format!("list chain {TABLE} {chain}"))?;

    if !comment.is_empty() {
        if let Some(h) = find_handle_by_comment(&chain_json, comment) {
            return Ok(h);
        }
    }

    find_max_handle(&chain_json).ok_or_else(|| "Rule applied but handle not found".to_string())
}

/// Remove a rule by chain + nft handle.
pub fn remove_rule(nft: &NftContext, chain: &str, handle: u64) -> Result<(), String> {
    nft.run(&format!("delete rule {TABLE} {chain} handle {handle}")).map(|_| ())
}

// ---------------------------------------------------------------------------
// Rule command builder
// ---------------------------------------------------------------------------

fn build_rule_cmd(
    chain: &str,
    action: &str,
    family: i32,
    proto: &str,
    dport: i32,
    source: &str,
    destination: &str,
    in_iface: &str,
    out_iface: &str,
    state_match: &str,
    comment: &str,
) -> Result<String, String> {
    let mut parts = Vec::new();

    let fam = if family == libc::AF_INET6 as i32 { "ip6" } else { "ip" };

    if !in_iface.is_empty() {
        parts.push(format!("iifname \"{}\"", in_iface));
    }
    if !out_iface.is_empty() {
        parts.push(format!("oifname \"{}\"", out_iface));
    }
    if !source.is_empty() {
        parts.push(format!("{fam} saddr {}", source));
    }
    if !destination.is_empty() {
        parts.push(format!("{fam} daddr {}", destination));
    }
    if !proto.is_empty() && dport > 0 {
        parts.push(format!("{} dport {}", proto, dport));
    }
    if !state_match.is_empty() {
        parts.push(format!("ct state {}", state_match.to_lowercase()));
    }

    // `dnat to <addr>` is rejected in an inet table — it carries both families,
    // so nftables cannot infer which one the address belongs to and demands an
    // explicit `ip` / `ip6`. The preset declares the intent; the family field
    // already resolved above is what makes it expressible here.
    if let Some(target) = action.strip_prefix("dnat to ") {
        parts.push(format!("dnat {fam} to {}", target));
    } else {
        parts.push(action.to_string());
    }

    if !comment.is_empty() {
        parts.push(format!("comment \"{}\"", comment));
    }

    let match_expr = parts.join(" ");
    Ok(format!("add rule {TABLE} {} {}", chain, match_expr))
}

// ---------------------------------------------------------------------------
// Handle lookup (JSON parsing)
// ---------------------------------------------------------------------------

fn find_handle_by_comment(json: &str, comment: &str) -> Option<u64> {
    let parsed: serde_json::Value = serde_json::from_str(json).ok()?;
    let nftables = parsed.get("nftables")?.as_array()?;

    for item in nftables {
        if let Some(rule) = item.get("rule") {
            let handle = rule.get("handle")?.as_u64()?;

            if let Some(c) = rule.get("comment").and_then(|c| c.as_str()) {
                if c == comment { return Some(handle); }
            }

            if let Some(expr) = rule.get("expr").and_then(|e| e.as_array()) {
                for e in expr {
                    if let Some(c) = e.get("comment").and_then(|c| c.as_str()) {
                        if c == comment { return Some(handle); }
                    }
                }
            }
        }
    }
    None
}

fn find_max_handle(json: &str) -> Option<u64> {
    let parsed: serde_json::Value = serde_json::from_str(json).ok()?;
    let nftables = parsed.get("nftables")?.as_array()?;
    let mut max_handle = 0u64;
    let mut found = false;

    for item in nftables {
        if let Some(rule) = item.get("rule") {
            if let Some(h) = rule.get("handle").and_then(|h| h.as_u64()) {
                if h > max_handle { max_handle = h; found = true; }
            }
        }
    }

    if found { Some(max_handle) } else { None }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_basic_accept() {
        let cmd = build_rule_cmd("input", "accept", 2, "tcp", 443,
                                  "", "", "", "", "", "").unwrap();
        assert!(cmd.contains("inet phantom"));
        assert!(cmd.contains("input"));
        assert!(cmd.contains("tcp dport 443"));
        assert!(cmd.contains("accept"));
    }

    #[test]
    fn test_build_forward_with_ifaces() {
        let cmd = build_rule_cmd("forward", "accept", 2, "", 0,
                                  "", "", "wg0", "eth0", "", "").unwrap();
        assert!(cmd.contains("iifname \"wg0\""));
        assert!(cmd.contains("oifname \"eth0\""));
        assert!(cmd.contains("accept"));
        assert!(!cmd.contains("dport"));
    }

    #[test]
    fn test_build_forward_with_state() {
        let cmd = build_rule_cmd("forward", "accept", 2, "", 0,
                                  "", "", "eth0", "wg0",
                                  "established,related", "").unwrap();
        assert!(cmd.contains("ct state established,related"));
    }

    #[test]
    fn test_build_masquerade() {
        let cmd = build_rule_cmd("postrouting", "masquerade", 2, "", 0,
                                  "10.0.1.0/24", "", "", "eth0", "", "").unwrap();
        assert!(cmd.contains("ip saddr 10.0.1.0/24"));
        assert!(cmd.contains("oifname \"eth0\""));
        assert!(cmd.contains("masquerade"));
    }

    #[test]
    fn test_build_ipv6_drop() {
        let cmd = build_rule_cmd("input", "drop", 10, "", 0,
                                  "", "", "", "", "", "").unwrap();
        assert!(cmd.contains("drop"));
        // family=10 (AF_INET6) affects source/dest prefix, no src/dst → no ip6 in cmd
    }

    #[test]
    fn test_build_dnat_v4_gets_explicit_family() {
        // inet tables reject a bare `dnat to <addr>`: "ip or ip6 must be
        // specified with address for inet tables".
        let cmd = build_rule_cmd("prerouting", "dnat to 172.28.0.4:443", 2,
                                  "tcp", 443, "", "", "", "", "", "").unwrap();
        assert!(cmd.contains("dnat ip to 172.28.0.4:443"), "got: {cmd}");
    }

    #[test]
    fn test_build_dnat_v6_gets_explicit_family() {
        let cmd = build_rule_cmd("prerouting", "dnat to [2001:db8::1]:443", 10,
                                  "tcp", 443, "", "", "", "", "", "").unwrap();
        assert!(cmd.contains("dnat ip6 to [2001:db8::1]:443"), "got: {cmd}");
    }

    #[test]
    fn test_build_non_dnat_action_untouched() {
        for action in ["accept", "drop", "reject", "masquerade"] {
            let cmd = build_rule_cmd("forward", action, 2,
                                      "", 0, "", "", "", "", "", "").unwrap();
            assert!(cmd.ends_with(action), "got: {cmd}");
        }
    }

    #[test]
    fn test_build_with_comment() {
        let cmd = build_rule_cmd("input", "accept", 2, "udp", 51820,
                                  "", "", "", "", "", "phantom-rule-42").unwrap();
        assert!(cmd.contains("comment \"phantom-rule-42\""));
    }

    #[test]
    fn test_build_source_dest() {
        let cmd = build_rule_cmd("output", "drop", 2, "tcp", 53,
                                  "192.168.1.0/24", "8.8.8.8", "", "", "", "").unwrap();
        assert!(cmd.contains("ip saddr 192.168.1.0/24"));
        assert!(cmd.contains("ip daddr 8.8.8.8"));
        assert!(cmd.contains("tcp dport 53"));
        assert!(cmd.contains("drop"));
    }

    #[test]
    fn test_find_handle_by_comment_rule_level() {
        let json = r#"{"nftables": [
            {"rule": {"chain": "input", "handle": 42, "comment": "phantom-rule-7", "expr": []}}
        ]}"#;
        assert_eq!(find_handle_by_comment(json, "phantom-rule-7"), Some(42));
    }

    #[test]
    fn test_find_handle_by_comment_expr_level() {
        let json = r#"{"nftables": [
            {"rule": {"chain": "input", "handle": 99, "expr": [
                {"comment": "phantom-rule-13"},
                {"accept": null}
            ]}}
        ]}"#;
        assert_eq!(find_handle_by_comment(json, "phantom-rule-13"), Some(99));
    }

    #[test]
    fn test_find_handle_not_found() {
        let json = r#"{"nftables": [
            {"rule": {"chain": "input", "handle": 5, "expr": [{"accept": null}]}}
        ]}"#;
        assert_eq!(find_handle_by_comment(json, "phantom-rule-1"), None);
    }

    #[test]
    fn test_find_max_handle() {
        let json = r#"{"nftables": [
            {"rule": {"chain": "input", "handle": 3}},
            {"rule": {"chain": "input", "handle": 17}},
            {"rule": {"chain": "input", "handle": 9}}
        ]}"#;
        assert_eq!(find_max_handle(json), Some(17));
    }

    #[test]
    fn test_find_max_handle_empty() {
        assert_eq!(find_max_handle("{}"), None);
        assert_eq!(find_max_handle(r#"{"nftables": []}"#), None);
    }
}
