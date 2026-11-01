//! nftables through the nft program, in the `inet phantom` table.

use std::ffi::OsString;
use std::net::IpAddr;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use serde_json::{json, Value};

// ---------------------------------------------------------------------------
// nft program
// ---------------------------------------------------------------------------

/// Where nft is looked for when the environment names no other path.
///
/// @witness nft::tests::test_nft_from_env_defaults_to_usr_sbin
const DEFAULT_NFT_PATH: &str = "/usr/sbin/nft";

/// Overrides `DEFAULT_NFT_PATH`; takes an absolute path.
///
/// @witness nft::tests::test_nft_from_env_takes_the_variable
const NFT_PATH_ENV: &str = "FIREWALL_BRIDGE_NFT_PATH";

// ---------------------------------------------------------------------------
// NftContext
// ---------------------------------------------------------------------------

pub struct NftContext {
    binary: PathBuf,
}

impl NftContext {
    /// Resolves nft from `FIREWALL_BRIDGE_NFT_PATH`, else `/usr/sbin/nft`.
    ///
    /// @witness nft::tests::test_nft_from_env_takes_the_variable
    /// @witness nft::tests::test_nft_from_env_defaults_to_usr_sbin
    pub fn new() -> Result<Self, &'static str> {
        Self::from_env(std::env::var_os(NFT_PATH_ENV))
    }

    /// `new`, with the variable's value passed in.
    fn from_env(value: Option<OsString>) -> Result<Self, &'static str> {
        let binary = value
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(DEFAULT_NFT_PATH));
        Self::with_binary(binary)
    }

    /// @witness nft::tests::test_nft_relative_path_is_refused
    /// @witness nft::tests::test_nft_missing_program
    fn with_binary(binary: impl Into<PathBuf>) -> Result<Self, &'static str> {
        let binary = binary.into();
        if !binary.is_absolute() {
            return Err("nft path must be absolute");
        }
        if !binary.is_file() {
            return Err("nft program not found");
        }
        Ok(Self { binary })
    }

    /// @witness nft::tests::test_nft_run_passes_the_command_as_one_argument
    pub fn run(&self, cmd: &str) -> Result<String, String> {
        self.exec(&[], cmd)
    }

    /// @witness nft::tests::test_nft_run_json_asks_for_json_with_handles
    pub fn run_json(&self, cmd: &str) -> Result<String, String> {
        self.exec(&["--json", "--handle"], cmd)
    }

    /// Runs an `add` command with `--echo --json --handle`.
    ///
    /// @witness nft::tests::test_add_rule_takes_the_handle_from_one_run
    /// @witness nft::tests::test_find_added_handle
    pub fn run_echo(&self, cmd: &str) -> Result<String, String> {
        self.exec(&["--echo", "--json", "--handle"], cmd)
    }

    /// @witness nft::tests::test_nft_run_passes_the_command_as_one_argument
    /// @witness nft::tests::test_nft_environment_is_cleared
    /// @witness nft::tests::test_nft_failure_carries_stderr
    /// @witness nft::tests::test_nft_failure_without_stderr_names_the_command
    /// @witness nft::tests::test_nft_that_cannot_start_or_is_killed
    /// @witness nft::tests::test_nft_output_that_is_not_utf8
    /// @witness nft::tests::test_nft_output_larger_than_a_pipe_buffer
    /// @witness nft::tests::test_nft_leaves_no_child_behind
    /// @witness kernel_tests::kernel_nft_leaves_no_child_behind
    /// @witness kernel_tests::kernel_nft_with_sigchld_ignored
    fn exec(&self, flags: &[&str], cmd: &str) -> Result<String, String> {
        let child = Command::new(&self.binary)
            .args(flags)
            .arg("--")
            .arg(cmd)
            .env_clear()
            .env("LC_ALL", "C")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("nft could not be started: {e}"))?;

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

        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }
}

// ---------------------------------------------------------------------------
// Table + chain management
// ---------------------------------------------------------------------------

const TABLE: &str = "inet phantom";
const TABLE_FAMILY: &str = "inet";
const TABLE_NAME: &str = "phantom";

/// The `inet phantom` table with its input, output, forward, prerouting and
/// postrouting chains, in one nft run.
///
/// @witness nft::tests::test_ensure_table_is_one_run
/// @witness kernel_tests::kernel_nft_ensure_table_is_all_or_nothing
/// @witness kernel_tests::kernel_nft_table_rules_and_handles
pub fn ensure_table(nft: &NftContext) -> Result<(), String> {
    let cmd = [
        format!("add table {TABLE}"),
        format!("add chain {TABLE} input {{ type filter hook input priority 0; policy accept; }}"),
        format!("add chain {TABLE} output {{ type filter hook output priority 0; policy accept; }}"),
        format!("add chain {TABLE} forward {{ type filter hook forward priority 0; policy accept; }}"),
        format!("add chain {TABLE} prerouting {{ type nat hook prerouting priority -100; policy accept; }}"),
        format!("add chain {TABLE} postrouting {{ type nat hook postrouting priority 100; policy accept; }}"),
    ].join("; ");
    nft.run(&cmd).map(|_| ())
}

/// @witness nft::tests::test_table_and_rule_commands
/// @witness kernel_tests::kernel_nft_table_rules_and_handles
pub fn flush_table(nft: &NftContext) -> Result<(), String> {
    nft.run(&format!("flush table {TABLE}")).map(|_| ())
}

/// @witness nft::tests::test_table_and_rule_commands
/// @witness kernel_tests::kernel_nft_table_rules_and_handles
pub fn list_table(nft: &NftContext) -> Result<String, String> {
    nft.run_json(&format!("list table {TABLE}"))
}

// ---------------------------------------------------------------------------
// Rule operations
// ---------------------------------------------------------------------------

/// One rule, field for field as `nft_add_rule` takes it across the C ABI;
/// unused strings are empty and unused numbers 0.
///
/// @witness nft::tests::test_build_rule_exact_output
#[derive(Default)]
pub struct RuleSpec<'a> {
    pub chain: &'a str,
    pub action: &'a str,
    pub family: i32,
    pub proto: &'a str,
    pub dport: i32,
    pub source: &'a str,
    pub destination: &'a str,
    pub in_iface: &'a str,
    pub out_iface: &'a str,
    pub state_match: &'a str,
    pub comment: &'a str,
}

/// Add a rule `build_rule` made; returns its nft handle.
///
/// @witness nft::tests::test_add_rule_takes_the_handle_from_one_run
/// @witness nft::tests::test_add_rule_reports_a_failure_and_a_missing_handle
/// @witness kernel_tests::kernel_nft_table_rules_and_handles
/// @witness kernel_tests::kernel_nft_builds_what_nft_builds_from_text
pub fn add_rule(nft: &NftContext, rule: &str) -> Result<u64, String> {
    let echo = nft.run_echo(rule)?;
    find_added_handle(&echo).ok_or_else(|| "Rule applied but handle not found".to_string())
}

/// Remove a rule by chain + nft handle.
///
/// @witness nft::tests::test_table_and_rule_commands
/// @witness kernel_tests::kernel_nft_table_rules_and_handles
/// @witness kernel_tests::kernel_nft_errors_reach_the_caller
pub fn remove_rule(nft: &NftContext, chain: &str, handle: u64) -> Result<(), String> {
    let cmd = json!({"nftables": [{"delete": {"rule": {
        "family": TABLE_FAMILY, "table": TABLE_NAME, "chain": chain, "handle": handle,
    }}}]});
    nft.run_json(&cmd.to_string()).map(|_| ())
}

// ---------------------------------------------------------------------------
// Rule builder
// ---------------------------------------------------------------------------

/// The `add rule` command for `rule`, in nft's JSON input format.
///
/// @witness nft::tests::test_build_rule_exact_output
/// @witness kernel_tests::kernel_nft_builds_what_nft_builds_from_text
pub fn build_rule(rule: &RuleSpec) -> Result<String, String> {
    let RuleSpec { chain, action, family, proto, dport, source, destination,
                   in_iface, out_iface, state_match, comment } = *rule;
    if chain.is_empty() {
        return Err("Rule chain is empty".to_string());
    }
    let fam = if family == libc::AF_INET6 { "ip6" } else { "ip" };
    let equals = |left: Value, right: Value| json!({"match": {"op": "==", "left": left, "right": right}});

    let mut expr = Vec::new();
    if !in_iface.is_empty() {
        expr.push(equals(json!({"meta": {"key": "iifname"}}), json!(in_iface)));
    }
    if !out_iface.is_empty() {
        expr.push(equals(json!({"meta": {"key": "oifname"}}), json!(out_iface)));
    }
    for (field, value) in [("saddr", source), ("daddr", destination)] {
        if !value.is_empty() {
            expr.push(equals(json!({"payload": {"protocol": fam, "field": field}}),
                             address(value, family)?));
        }
    }
    if !proto.is_empty() && dport > 0 {
        expr.push(equals(json!({"payload": {"protocol": proto, "field": "dport"}}), json!(dport)));
    }
    if !state_match.is_empty() {
        let states: Vec<String> = state_match.to_lowercase().split(',')
            .map(|s| s.trim().to_string()).collect();
        expr.push(json!({"match": {"op": "in", "left": {"ct": {"key": "state"}}, "right": states}}));
    }
    expr.push(statement(action, family)?);

    let mut body = json!({"family": TABLE_FAMILY, "table": TABLE_NAME, "chain": chain, "expr": expr});
    if !comment.is_empty() {
        body["comment"] = json!(comment);
    }
    Ok(json!({"nftables": [{"add": {"rule": body}}]}).to_string())
}

/// Any family other than AF_INET6 reads as IPv4.
fn is_v6(family: i32) -> bool {
    family == libc::AF_INET6
}

/// An address, or a network as nft's prefix, of the rule's family.
///
/// @witness nft::tests::test_build_rule_exact_output
fn address(value: &str, family: i32) -> Result<Value, String> {
    let (addr, len) = match value.split_once('/') {
        Some((addr, len)) => (addr, Some(len)),
        None => (value, None),
    };
    let ip: IpAddr = addr.parse().map_err(|_| format!("Invalid address: {value:?}"))?;
    if ip.is_ipv6() != is_v6(family) {
        return Err(format!("Address family {family} does not match {value}"));
    }
    let Some(len) = len else { return Ok(json!(addr)) };
    let max = if ip.is_ipv6() { 128 } else { 32 };
    match len.parse::<u8>() {
        Ok(len) if len <= max => Ok(json!({"prefix": {"addr": addr, "len": len}})),
        _ => Err(format!("Invalid prefix length: {value:?}")),
    }
}

/// The verdict or nat statement `action` names: accept, drop, reject,
/// masquerade, or `dnat to <address>[:<port>]` with an IPv6 address in
/// brackets.
///
/// @witness nft::tests::test_build_rule_exact_output
fn statement(action: &str, family: i32) -> Result<Value, String> {
    if let "accept" | "drop" | "reject" | "masquerade" = action {
        let mut verdict = serde_json::Map::new();
        verdict.insert(action.to_string(), Value::Null);
        return Ok(Value::Object(verdict));
    }
    let bad = || format!("Unknown action: {action:?}");
    let target = action.strip_prefix("dnat to ").ok_or_else(bad)?;
    let (addr, port) = match target.strip_prefix('[') {
        Some(rest) => {
            let (addr, after) = rest.split_once(']').ok_or_else(bad)?;
            match after {
                "" => (addr, None),
                _ => (addr, Some(after.strip_prefix(':').ok_or_else(bad)?)),
            }
        }
        None => match target.split_once(':') {
            Some((addr, port)) => (addr, Some(port)),
            None => (target, None),
        },
    };
    let ip: IpAddr = addr.parse().map_err(|_| bad())?;
    if ip.is_ipv6() != is_v6(family) || (ip.is_ipv6() && !target.starts_with('[')) {
        return Err(bad());
    }
    let fam = if is_v6(family) { "ip6" } else { "ip" };
    let mut dnat = json!({"family": fam, "addr": addr});
    if let Some(port) = port {
        match port.parse::<u16>() {
            Ok(port) if port > 0 => dnat["port"] = json!(port),
            _ => return Err(bad()),
        }
    }
    Ok(json!({"dnat": dnat}))
}

// ---------------------------------------------------------------------------
// Handle lookup (JSON parsing)
// ---------------------------------------------------------------------------

/// The handle in nft's echo of an `add rule`.
///
/// @witness nft::tests::test_find_added_handle
/// @witness nft::tests::test_find_added_handle_absent
fn find_added_handle(json: &str) -> Option<u64> {
    let parsed: serde_json::Value = serde_json::from_str(json).ok()?;
    parsed.get("nftables")?.as_array()?.iter()
        .find_map(|item| item.get("add")?.get("rule")?.get("handle")?.as_u64())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
pub(crate) mod tests {
    //! The command text and a stand-in nft script. Whether nft accepts the
    //! commands is kernel_tests' part.

    use super::*;

    // -----------------------------------------------------------------------
    // build_rule — the whole command for every branch
    // -----------------------------------------------------------------------

    /// What build_rule makes of a rule: the rule object without its family
    /// and table, or the error.
    pub(crate) type Built = Result<&'static str, &'static str>;

    /// Every branch of build_rule, with the rule it writes and, where the
    /// rule has one, the same rule in nft's text syntax after `add rule
    /// inet <table> `. kernel_tests sends the rules to nft and checks each
    /// against its text form.
    pub(crate) fn rule_cases() -> Vec<(RuleSpec<'static>, Built, Option<&'static str>)> {
        vec![
            (RuleSpec { chain: "input", action: "accept", family: 2, ..Default::default() },
             Ok(r#"{"chain":"input","expr":[{"accept":null}]}"#),
             Some("input accept")),
            (RuleSpec { chain: "input", action: "accept", family: 2, proto: "tcp", dport: 443,
                        ..Default::default() },
             Ok(r#"{"chain":"input","expr":[{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":443}},{"accept":null}]}"#),
             Some("input tcp dport 443 accept")),
            // A port match needs both a protocol and a port above 0.
            (RuleSpec { chain: "input", action: "drop", family: 2, proto: "udp", ..Default::default() },
             Ok(r#"{"chain":"input","expr":[{"drop":null}]}"#),
             Some("input drop")),
            (RuleSpec { chain: "input", action: "drop", family: 2, dport: 53, ..Default::default() },
             Ok(r#"{"chain":"input","expr":[{"drop":null}]}"#),
             Some("input drop")),
            (RuleSpec { chain: "input", action: "drop", family: 2, proto: "tcp", dport: -1,
                        ..Default::default() },
             Ok(r#"{"chain":"input","expr":[{"drop":null}]}"#),
             Some("input drop")),
            (RuleSpec { chain: "forward", action: "accept", family: 2, in_iface: "wg0",
                        out_iface: "eth0", ..Default::default() },
             Ok(r#"{"chain":"forward","expr":[{"match":{"op":"==","left":{"meta":{"key":"iifname"}},"right":"wg0"}},{"match":{"op":"==","left":{"meta":{"key":"oifname"}},"right":"eth0"}},{"accept":null}]}"#),
             Some(r#"forward iifname "wg0" oifname "eth0" accept"#)),
            (RuleSpec { chain: "output", action: "drop", family: 2, proto: "tcp", dport: 53,
                        source: "192.168.1.0/24", destination: "8.8.8.8", ..Default::default() },
             Ok(r#"{"chain":"output","expr":[{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"saddr"}},"right":{"prefix":{"addr":"192.168.1.0","len":24}}}},{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"daddr"}},"right":"8.8.8.8"}},{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":53}},{"drop":null}]}"#),
             Some("output ip saddr 192.168.1.0/24 ip daddr 8.8.8.8 tcp dport 53 drop")),
            (RuleSpec { chain: "input", action: "accept", family: 10, source: "2001:db8::/32",
                        destination: "2001:db8::1", ..Default::default() },
             Ok(r#"{"chain":"input","expr":[{"match":{"op":"==","left":{"payload":{"protocol":"ip6","field":"saddr"}},"right":{"prefix":{"addr":"2001:db8::","len":32}}}},{"match":{"op":"==","left":{"payload":{"protocol":"ip6","field":"daddr"}},"right":"2001:db8::1"}},{"accept":null}]}"#),
             Some("input ip6 saddr 2001:db8::/32 ip6 daddr 2001:db8::1 accept")),
            // Any family other than AF_INET6 (10) reads as IPv4.
            (RuleSpec { chain: "input", action: "accept", family: 0, source: "10.0.0.0/8",
                        ..Default::default() },
             Ok(r#"{"chain":"input","expr":[{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"saddr"}},"right":{"prefix":{"addr":"10.0.0.0","len":8}}}},{"accept":null}]}"#),
             Some("input ip saddr 10.0.0.0/8 accept")),
            (RuleSpec { chain: "forward", action: "accept", family: 2,
                        state_match: "ESTABLISHED,Related", ..Default::default() },
             Ok(r#"{"chain":"forward","expr":[{"match":{"op":"in","left":{"ct":{"key":"state"}},"right":["established","related"]}},{"accept":null}]}"#),
             Some("forward ct state established,related accept")),
            (RuleSpec { chain: "forward", action: "accept", family: 2,
                        state_match: "established, related", ..Default::default() },
             Ok(r#"{"chain":"forward","expr":[{"match":{"op":"in","left":{"ct":{"key":"state"}},"right":["established","related"]}},{"accept":null}]}"#),
             Some("forward ct state established,related accept")),
            (RuleSpec { chain: "postrouting", action: "masquerade", family: 2,
                        source: "10.0.1.0/24", out_iface: "eth0", ..Default::default() },
             Ok(r#"{"chain":"postrouting","expr":[{"match":{"op":"==","left":{"meta":{"key":"oifname"}},"right":"eth0"}},{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"saddr"}},"right":{"prefix":{"addr":"10.0.1.0","len":24}}}},{"masquerade":null}]}"#),
             Some(r#"postrouting oifname "eth0" ip saddr 10.0.1.0/24 masquerade"#)),
            (RuleSpec { chain: "prerouting", action: "dnat to 172.28.0.4:443", family: 2,
                        proto: "tcp", dport: 443, ..Default::default() },
             Ok(r#"{"chain":"prerouting","expr":[{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":443}},{"dnat":{"family":"ip","addr":"172.28.0.4","port":443}}]}"#),
             Some("prerouting tcp dport 443 dnat ip to 172.28.0.4:443")),
            (RuleSpec { chain: "prerouting", action: "dnat to [2001:db8::1]:443", family: 10,
                        proto: "tcp", dport: 443, ..Default::default() },
             Ok(r#"{"chain":"prerouting","expr":[{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":443}},{"dnat":{"family":"ip6","addr":"2001:db8::1","port":443}}]}"#),
             Some("prerouting tcp dport 443 dnat ip6 to [2001:db8::1]:443")),
            (RuleSpec { chain: "prerouting", action: "dnat to 192.0.2.10", family: 2,
                        destination: "192.0.2.1", ..Default::default() },
             Ok(r#"{"chain":"prerouting","expr":[{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"daddr"}},"right":"192.0.2.1"}},{"dnat":{"family":"ip","addr":"192.0.2.10"}}]}"#),
             Some("prerouting ip daddr 192.0.2.1 dnat ip to 192.0.2.10")),
            (RuleSpec { chain: "input", action: "reject", family: 10, ..Default::default() },
             Ok(r#"{"chain":"input","expr":[{"reject":null}]}"#),
             Some("input reject")),
            (RuleSpec { chain: "input", action: "accept", family: 2, proto: "udp", dport: 51820,
                        comment: "phantom-rule-42", ..Default::default() },
             Ok(r#"{"chain":"input","expr":[{"match":{"op":"==","left":{"payload":{"protocol":"udp","field":"dport"}},"right":51820}},{"accept":null}],"comment":"phantom-rule-42"}"#),
             Some(r#"input udp dport 51820 accept comment "phantom-rule-42""#)),
            (RuleSpec { chain: "forward", action: "accept", family: 2, proto: "tcp", dport: 8080,
                        source: "10.0.0.0/24", destination: "10.0.1.5", in_iface: "wg0",
                        out_iface: "eth0", state_match: "NEW", comment: "c" },
             Ok(r#"{"chain":"forward","expr":[{"match":{"op":"==","left":{"meta":{"key":"iifname"}},"right":"wg0"}},{"match":{"op":"==","left":{"meta":{"key":"oifname"}},"right":"eth0"}},{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"saddr"}},"right":{"prefix":{"addr":"10.0.0.0","len":24}}}},{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"daddr"}},"right":"10.0.1.5"}},{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":8080}},{"match":{"op":"in","left":{"ct":{"key":"state"}},"right":["new"]}},{"accept":null}],"comment":"c"}"#),
             Some(r#"forward iifname "wg0" oifname "eth0" ip saddr 10.0.0.0/24 ip daddr 10.0.1.5 tcp dport 8080 ct state new accept comment "c""#)),
            // A host prefix and host bits under a prefix: nft keeps what its text parser keeps.
            (RuleSpec { chain: "input", action: "accept", family: 2, source: "10.0.0.1/32",
                        destination: "10.0.0.5/24", ..Default::default() },
             Ok(r#"{"chain":"input","expr":[{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"saddr"}},"right":{"prefix":{"addr":"10.0.0.1","len":32}}}},{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"daddr"}},"right":{"prefix":{"addr":"10.0.0.5","len":24}}}},{"accept":null}]}"#),
             Some("input ip saddr 10.0.0.1/32 ip daddr 10.0.0.5/24 accept")),
            // Quotes and semicolons stay inside the value.
            (RuleSpec { chain: "input", action: "accept", family: 2, in_iface: "a\";b", ..Default::default() },
             Ok(r#"{"chain":"input","expr":[{"match":{"op":"==","left":{"meta":{"key":"iifname"}},"right":"a\";b"}},{"accept":null}]}"#),
             None),
            (RuleSpec { chain: "prerouting", action: "dnat", family: 2, ..Default::default() },
             Err("Unknown action: \"dnat\""), None),
            (RuleSpec { chain: "input", action: "accept; flush ruleset", family: 2, ..Default::default() },
             Err("Unknown action: \"accept; flush ruleset\""), None),
            // An IPv6 target needs brackets.
            (RuleSpec { chain: "prerouting", action: "dnat to 2001:db8::1", family: 10, ..Default::default() },
             Err("Unknown action: \"dnat to 2001:db8::1\""), None),
            (RuleSpec { chain: "prerouting", action: "dnat to 192.0.2.1:70000", family: 2, ..Default::default() },
             Err("Unknown action: \"dnat to 192.0.2.1:70000\""), None),
            (RuleSpec { chain: "prerouting", action: "dnat to 192.0.2.1", family: 10, ..Default::default() },
             Err("Unknown action: \"dnat to 192.0.2.1\""), None),
            // A name is not looked up.
            (RuleSpec { chain: "input", action: "accept", family: 2, source: "example.com",
                        ..Default::default() },
             Err("Invalid address: \"example.com\""), None),
            (RuleSpec { chain: "input", action: "accept", family: 2, source: "fd00::/64",
                        ..Default::default() },
             Err("Address family 2 does not match fd00::/64"), None),
            (RuleSpec { chain: "input", action: "accept", family: 2, destination: "10.0.0.0/33",
                        ..Default::default() },
             Err("Invalid prefix length: \"10.0.0.0/33\""), None),
            (RuleSpec::default(),
             Err("Rule chain is empty"), None),
        ]
    }

    /// Compares the whole rule, so a change in a field, its order or its
    /// form shows up, not only a missing fragment.
    #[test]
    fn test_build_rule_exact_output() {
        for (i, (rule, want, _)) in rule_cases().into_iter().enumerate() {
            let got = build_rule(&rule).map(|cmd| {
                let mut parsed: Value = serde_json::from_str(&cmd).unwrap();
                let body = parsed["nftables"][0]["add"]["rule"].take();
                let Value::Object(mut body) = body else { panic!("case {i}: {cmd}") };
                assert_eq!(body.remove("family"), Some(json!("inet")), "case {i}");
                assert_eq!(body.remove("table"), Some(json!("phantom")), "case {i}");
                Value::Object(body)
            });
            match want {
                Ok(json) => assert_eq!(got, Ok(serde_json::from_str(json).unwrap()), "case {i}"),
                Err(msg) => assert_eq!(got, Err(msg.to_string()), "case {i}"),
            }
        }
    }

    /// nft 1.1.3's echo of `add rule inet phantom input tcp dport 22 accept
    /// comment "kural-ğüş"`.
    const ECHO: &str = r#"{"nftables": [{"add": {"rule": {"family": "inet", "table": "phantom", "chain": "input", "handle": 2, "comment": "kural-ğüş", "expr": [{"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": 22}}, {"accept": null}]}}}]}"#;

    #[test]
    fn test_find_added_handle() {
        assert_eq!(find_added_handle(ECHO), Some(2));
    }

    #[test]
    fn test_find_added_handle_absent() {
        assert_eq!(find_added_handle("{}"), None);
        assert_eq!(find_added_handle(r#"{"nftables": []}"#), None);
        // A listing names rules without "add"; only an echo counts.
        assert_eq!(find_added_handle(r#"{"nftables": [{"rule": {"handle": 5}}]}"#), None);
        assert_eq!(find_added_handle("not json"), None);
    }

    // -----------------------------------------------------------------------
    // NftContext — against a stand-in nft
    // -----------------------------------------------------------------------

    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;

    use crate::test_support::{children, serial};

    /// A shell script that records its arguments and stdin next to itself,
    /// then runs `body`. It lives under target/, not the system temp
    /// directory, which may be mounted noexec.
    fn fake_nft(name: &str, body: &str) -> PathBuf {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("target/nft-tests")
            .join(name);
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
    fn test_nft_from_env_takes_the_variable() {
        let _serial = serial();
        let nft = fake_nft("from_env", "printf 'ok'");
        let ctx = NftContext::from_env(Some(nft.clone().into_os_string())).unwrap();
        assert_eq!(ctx.binary, nft);
        assert_eq!(NftContext::from_env(Some("nft".into())).err(),
                   Some("nft path must be absolute"));
        assert_eq!(NftContext::from_env(Some("/nonexistent/nft".into())).err(),
                   Some("nft program not found"));
    }

    #[test]
    fn test_nft_from_env_defaults_to_usr_sbin() {
        match NftContext::from_env(None) {
            Ok(ctx) => assert_eq!(ctx.binary, Path::new(DEFAULT_NFT_PATH)),
            Err(e) => {
                assert!(!Path::new(DEFAULT_NFT_PATH).is_file());
                assert_eq!(e, "nft program not found");
            }
        }
    }

    #[test]
    fn test_nft_relative_path_is_refused() {
        for path in ["nft", "./nft", "sbin/nft"] {
            assert_eq!(NftContext::with_binary(path).err(),
                       Some("nft path must be absolute"), "path: {path}");
        }
    }

    #[test]
    fn test_nft_run_passes_the_command_as_one_argument() {
        let _serial = serial();
        let nft = fake_nft("run", "printf 'ok'");
        let ctx = NftContext::with_binary(&nft).unwrap();
        assert_eq!(ctx.run("add table inet phantom").unwrap(), "ok");
        assert_eq!(recorded(&nft, "args"), "--\nadd table inet phantom\n");
        assert_eq!(recorded(&nft, "stdin"), "");
    }

    #[test]
    fn test_nft_run_json_asks_for_json_with_handles() {
        let _serial = serial();
        let nft = fake_nft("run_json", r#"printf '{"nftables": []}'"#);
        let ctx = NftContext::with_binary(&nft).unwrap();
        assert_eq!(ctx.run_json("list table inet phantom").unwrap(), r#"{"nftables": []}"#);
        assert_eq!(recorded(&nft, "args"), "--json\n--handle\n--\nlist table inet phantom\n");
    }

    #[test]
    fn test_table_and_rule_commands() {
        let _serial = serial();
        let nft = fake_nft("commands", r#"printf '{"nftables": []}'"#);
        let ctx = NftContext::with_binary(&nft).unwrap();
        flush_table(&ctx).unwrap();
        assert_eq!(recorded(&nft, "args"), "--\nflush table inet phantom\n");
        remove_rule(&ctx, "forward", 42).unwrap();
        assert_eq!(recorded(&nft, "args"), "--json\n--handle\n--\n\
            {\"nftables\":[{\"delete\":{\"rule\":{\"chain\":\"forward\",\"family\":\"inet\",\
            \"handle\":42,\"table\":\"phantom\"}}}]}\n");
        assert_eq!(list_table(&ctx).unwrap(), r#"{"nftables": []}"#);
        assert_eq!(recorded(&nft, "args"), "--json\n--handle\n--\nlist table inet phantom\n");
    }

    #[test]
    fn test_add_rule_reports_a_failure_and_a_missing_handle() {
        let _serial = serial();
        let rule = build_rule(&RuleSpec { chain: "input", action: "accept", family: 2,
                                          ..Default::default() }).unwrap();
        let failing = fake_nft("add_rule-fails", "printf 'Error: no such chain' >&2; exit 1");
        assert_eq!(add_rule(&NftContext::with_binary(&failing).unwrap(), &rule).unwrap_err(),
                   "Error: no such chain");
        let no_echo = fake_nft("add_rule-no-echo", r#"printf '{"nftables": []}'"#);
        assert_eq!(add_rule(&NftContext::with_binary(&no_echo).unwrap(), &rule).unwrap_err(),
                   "Rule applied but handle not found");
    }

    #[test]
    fn test_nft_that_cannot_start_or_is_killed() {
        let _serial = serial();
        let script = fake_nft("not-executable", "printf 'ok'");
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o644)).unwrap();
        let err = NftContext::with_binary(&script).unwrap().run("list ruleset").unwrap_err();
        assert!(err.starts_with("nft could not be started: "), "got: {err}");
        let killed = fake_nft("killed", "kill -9 $$");
        assert_eq!(NftContext::with_binary(&killed).unwrap().run("list ruleset").unwrap_err(),
                   "nft command failed (rc=-1): list ruleset");
    }

    #[test]
    fn test_nft_output_that_is_not_utf8() {
        let _serial = serial();
        let nft = fake_nft("not-utf8", r"printf 'a\377b'");
        assert_eq!(NftContext::with_binary(&nft).unwrap().run("list ruleset").unwrap(),
                   "a\u{FFFD}b");
    }

    #[test]
    fn test_ensure_table_is_one_run() {
        let _serial = serial();
        let nft = fake_nft("ensure_table", "printf 'x\\n' >> \"$0.calls\"");
        let ctx = NftContext::with_binary(&nft).unwrap();
        ensure_table(&ctx).unwrap();
        assert_eq!(recorded(&nft, "calls"), "x\n");
        // One line, so nft's error context shows the command that failed.
        let args = recorded(&nft, "args");
        let lines: Vec<&str> = args.lines().collect();
        assert_eq!(lines.len(), 2, "got: {args}");
        assert_eq!(lines[0], "--");
        let commands: Vec<&str> = lines[1].split("; add ").collect();
        assert_eq!(commands[0], "add table inet phantom");
        assert_eq!(commands.len(), 6, "got: {}", lines[1]);
        for (command, chain) in commands[1..].iter()
            .zip(["input", "output", "forward", "prerouting", "postrouting"]) {
            assert!(command.starts_with(&format!("chain inet phantom {chain} {{")), "got: {command}");
        }
    }

    #[test]
    fn test_add_rule_takes_the_handle_from_one_run() {
        let _serial = serial();
        let nft = fake_nft("add_rule", &format!(
            "printf 'x\\n' >> \"$0.calls\"\nprintf '%s' '{ECHO}'"));
        let ctx = NftContext::with_binary(&nft).unwrap();
        let rule = build_rule(&RuleSpec {
            chain: "input", action: "accept", family: 2, proto: "tcp", dport: 443,
            ..Default::default()
        }).unwrap();
        let handle = add_rule(&ctx, &rule).unwrap();
        assert_eq!(handle, 2);
        assert_eq!(recorded(&nft, "calls"), "x\n");
        assert_eq!(recorded(&nft, "args"), format!("--echo\n--json\n--handle\n--\n{rule}\n"));
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

    /// /proc/$$/environ holds the environment the script was started with,
    /// before the shell adds anything, so the check does not depend on what
    /// the test process itself inherited.
    #[test]
    fn test_nft_environment_is_cleared() {
        let _serial = serial();
        let nft = fake_nft("env", r#"tr '\0' '\n' < /proc/$$/environ > "$0.env""#);
        let ctx = NftContext::with_binary(&nft).unwrap();
        ctx.run("list ruleset").unwrap();
        assert_eq!(recorded(&nft, "env"), "LC_ALL=C\n");
    }

    /// Every nft is waited for before the call returns, whether it
    /// succeeded, failed or was killed, so none is left behind as a zombie.
    /// The serial lock keeps other tests from having children meanwhile.
    #[test]
    fn test_nft_leaves_no_child_behind() {
        let _serial = serial();
        let ok = NftContext::with_binary(fake_nft("reap-ok", "printf 'ok'")).unwrap();
        let failed = NftContext::with_binary(
            fake_nft("reap-failed", "printf 'Error' >&2; exit 1")).unwrap();
        let killed = NftContext::with_binary(fake_nft("reap-killed", "kill -9 $$")).unwrap();
        for _ in 0..20 {
            ok.run("list ruleset").unwrap();
            failed.run("list ruleset").unwrap_err();
            killed.run("list ruleset").unwrap_err();
        }
        assert_eq!(children(), Vec::<String>::new());
    }

    #[test]
    fn test_nft_output_larger_than_a_pipe_buffer() {
        let _serial = serial();
        let nft = fake_nft("large", r"head -c 300000 /dev/zero | tr '\0' x");
        let ctx = NftContext::with_binary(&nft).unwrap();
        assert_eq!(ctx.run_json("list table inet phantom").unwrap().len(), 300_000);
    }
}
