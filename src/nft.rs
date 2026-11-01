//! nftables operations through the nft program.
//!
//! All firewall rules live in the `inet phantom` table.
//! This avoids conflicts with UFW, iptables, or any other rulesets.
//! No DB dependency — pure kernel operations.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

// ---------------------------------------------------------------------------
// nft program
// ---------------------------------------------------------------------------

/// Where nft is looked for when the environment names no other path.
const DEFAULT_NFT_PATH: &str = "/usr/sbin/nft";

/// Overrides `DEFAULT_NFT_PATH`.
const NFT_PATH_ENV: &str = "FIREWALL_BRIDGE_NFT_PATH";

// ---------------------------------------------------------------------------
// NftContext — one nft process per command
// ---------------------------------------------------------------------------

pub struct NftContext {
    binary: PathBuf,
}

impl NftContext {
    /// Resolves nft from `FIREWALL_BRIDGE_NFT_PATH`, else `/usr/sbin/nft`.
    pub fn new() -> Result<Self, &'static str> {
        let binary = std::env::var_os(NFT_PATH_ENV)
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(DEFAULT_NFT_PATH));
        Self::with_binary(binary)
    }

    fn with_binary(binary: impl Into<PathBuf>) -> Result<Self, &'static str> {
        let binary = binary.into();
        if !binary.is_file() {
            return Err("nft program not found");
        }
        Ok(Self { binary })
    }

    pub fn run(&self, cmd: &str) -> Result<String, String> {
        self.exec(&[], cmd)
    }

    pub fn run_json(&self, cmd: &str) -> Result<String, String> {
        self.exec(&["--json", "--handle"], cmd)
    }

    /// `nft -f -` takes the command on stdin, the buffer form
    /// `nft_run_cmd_from_buffer` took. The child gets an empty environment
    /// apart from `LC_ALL=C`.
    fn exec(&self, flags: &[&str], cmd: &str) -> Result<String, String> {
        let mut child = Command::new(&self.binary)
            .args(flags)
            .args(["-f", "-"])
            .env_clear()
            .env("LC_ALL", "C")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("nft could not be started: {e}"))?;

        // The handle drops at the end of the arm, closing stdin, so nft has
        // its whole input before the output is read.
        let written = match child.stdin.take() {
            Some(mut stdin) => stdin.write_all(cmd.as_bytes()),
            None => Ok(()),
        };

        let out = child.wait_with_output()
            .map_err(|e| format!("nft did not finish: {e}"))?;

        if !out.status.success() {
            let error = String::from_utf8_lossy(&out.stderr).into_owned();
            return Err(if error.trim().is_empty() {
                let rc = out.status.code().unwrap_or(-1);
                format!("nft command failed (rc={rc}): {cmd}")
            } else {
                error
            });
        }
        written.map_err(|e| format!("nft input could not be written: {e}"))?;

        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
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

    // -----------------------------------------------------------------------
    // NftContext — against a stand-in nft
    // -----------------------------------------------------------------------

    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;
    use std::sync::{Mutex, MutexGuard};

    /// Writing a script while another thread forks can leave the write end
    /// open in that child, and exec then fails with ETXTBSY. The tests that
    /// spawn take this lock for their whole body.
    static SPAWN: Mutex<()> = Mutex::new(());

    fn serial() -> MutexGuard<'static, ()> {
        SPAWN.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// A shell script that records its arguments and stdin next to itself,
    /// then runs `body`.
    fn fake_nft(name: &str, body: &str) -> PathBuf {
        let dir = std::env::temp_dir()
            .join(format!("fwb-nft-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("nft");
        std::fs::write(
            &script,
            format!("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.args\"\ncat > \"$0.stdin\"\n{body}\n"),
        ).unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        script
    }

    fn recorded(script: &Path, what: &str) -> String {
        std::fs::read_to_string(script.with_extension(what)).unwrap()
    }

    #[test]
    fn test_nft_missing_program() {
        assert!(NftContext::with_binary("/nonexistent/nft").is_err());
    }

    #[test]
    fn test_nft_run_sends_the_command_on_stdin() {
        let _serial = serial();
        let nft = fake_nft("run", "printf 'ok'");
        let ctx = NftContext::with_binary(&nft).unwrap();
        assert_eq!(ctx.run("add table inet phantom").unwrap(), "ok");
        assert_eq!(recorded(&nft, "args"), "-f\n-\n");
        assert_eq!(recorded(&nft, "stdin"), "add table inet phantom");
    }

    #[test]
    fn test_nft_run_json_asks_for_json_with_handles() {
        let _serial = serial();
        let nft = fake_nft("run_json", r#"printf '{"nftables": []}'"#);
        let ctx = NftContext::with_binary(&nft).unwrap();
        assert_eq!(ctx.run_json("list table inet phantom").unwrap(), r#"{"nftables": []}"#);
        assert_eq!(recorded(&nft, "args"), "--json\n--handle\n-f\n-\n");
    }

    #[test]
    fn test_nft_failure_carries_stderr() {
        let _serial = serial();
        let nft = fake_nft("stderr", "printf 'Error: syntax error' >&2; exit 1");
        let ctx = NftContext::with_binary(&nft).unwrap();
        assert_eq!(ctx.run("add rule").unwrap_err(), "Error: syntax error");
    }

    #[test]
    fn test_nft_failure_without_stderr_names_the_command() {
        let _serial = serial();
        let nft = fake_nft("silent", "exit 3");
        let ctx = NftContext::with_binary(&nft).unwrap();
        assert_eq!(
            ctx.run("flush table inet phantom").unwrap_err(),
            "nft command failed (rc=3): flush table inet phantom"
        );
    }

    #[test]
    fn test_nft_environment_is_cleared() {
        let _serial = serial();
        let nft = fake_nft(
            "env",
            r#"printf '%s\n' "LC_ALL=${LC_ALL-unset}" "HOME=${HOME-unset}" > "$0.env""#,
        );
        let ctx = NftContext::with_binary(&nft).unwrap();
        ctx.run("list ruleset").unwrap();
        assert_eq!(recorded(&nft, "env"), "LC_ALL=C\nHOME=unset\n");
    }

    #[test]
    fn test_nft_output_larger_than_a_pipe_buffer() {
        let _serial = serial();
        let nft = fake_nft("large", r"head -c 300000 /dev/zero | tr '\0' x");
        let ctx = NftContext::with_binary(&nft).unwrap();
        assert_eq!(ctx.run_json("list table inet phantom").unwrap().len(), 300_000);
    }
}
