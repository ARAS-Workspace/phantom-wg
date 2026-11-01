//! nftables operations through the nft program.
//!
//! All firewall rules live in the `inet phantom` table.
//! This avoids conflicts with UFW, iptables, or any other rulesets.
//! No DB dependency — pure kernel operations.

use std::path::PathBuf;
use std::process::{Command, Stdio};

// ---------------------------------------------------------------------------
// nft program
// ---------------------------------------------------------------------------

/// Where nft is looked for when the environment names no other path.
const DEFAULT_NFT_PATH: &str = "/usr/sbin/nft";

/// Overrides `DEFAULT_NFT_PATH`; must be an absolute path.
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
        // A relative path would be checked against the working directory
        // but looked up on the default PATH when run.
        if !binary.is_absolute() {
            return Err("nft path must be absolute");
        }
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

    /// Runs an `add` command; nft prints what it added as JSON, handles
    /// included.
    pub fn run_echo(&self, cmd: &str) -> Result<String, String> {
        self.exec(&["--echo", "--json", "--handle"], cmd)
    }

    /// The command goes to nft as one argument after `--`, the buffer form
    /// `nft_run_cmd_from_buffer` took. stdin is closed: nothing is written
    /// to the child, so an nft that exits early cannot raise SIGPIPE in the
    /// host. The child gets an empty environment apart from `LC_ALL=C`.
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

/// One nft run is one transaction: the table and its five chains are
/// created together or not at all. `add` leaves what already exists alone.
pub fn ensure_table(nft: &NftContext) -> Result<(), String> {
    let cmd = [
        format!("add table {TABLE}"),
        format!("add chain {TABLE} input {{ type filter hook input priority 0; policy accept; }}"),
        format!("add chain {TABLE} output {{ type filter hook output priority 0; policy accept; }}"),
        format!("add chain {TABLE} forward {{ type filter hook forward priority 0; policy accept; }}"),
        format!("add chain {TABLE} prerouting {{ type nat hook prerouting priority -100; policy accept; }}"),
        format!("add chain {TABLE} postrouting {{ type nat hook postrouting priority 100; policy accept; }}"),
    ].join("\n");
    nft.run(&cmd).map(|_| ())
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

/// One rule, field for field as `nft_add_rule` takes it across the C ABI.
/// Unused strings are empty and unused numbers 0; `family` is AF_INET6 (10)
/// for IPv6, anything else reads as IPv4.
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

/// Add a firewall rule. Returns nft handle on success.
/// The fields map directly to nft rule expression components.
pub fn add_rule(nft: &NftContext, rule: &RuleSpec) -> Result<u64, String> {
    let cmd = build_rule_cmd(rule)?;

    // The handle comes from the run that added the rule, so no second run
    // can fail after the rule is already in the kernel.
    let echo = nft.run_echo(&cmd)?;
    find_added_handle(&echo).ok_or_else(|| "Rule applied but handle not found".to_string())
}

/// Remove a rule by chain + nft handle.
pub fn remove_rule(nft: &NftContext, chain: &str, handle: u64) -> Result<(), String> {
    nft.run(&format!("delete rule {TABLE} {chain} handle {handle}")).map(|_| ())
}

// ---------------------------------------------------------------------------
// Rule command builder
// ---------------------------------------------------------------------------

fn build_rule_cmd(rule: &RuleSpec) -> Result<String, String> {
    let RuleSpec { chain, action, family, proto, dport, source, destination,
                   in_iface, out_iface, state_match, comment } = *rule;
    let mut parts = Vec::new();

    let fam = if family == libc::AF_INET6 { "ip6" } else { "ip" };

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

/// The handle in nft's echo of an `add rule`:
/// `{"nftables": [{"add": {"rule": {…, "handle": N, …}}}]}`.
fn find_added_handle(json: &str) -> Option<u64> {
    let parsed: serde_json::Value = serde_json::from_str(json).ok()?;
    parsed.get("nftables")?.as_array()?.iter()
        .find_map(|item| item.get("add")?.get("rule")?.get("handle")?.as_u64())
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_basic_accept() {
        let cmd = build_rule_cmd(&RuleSpec {
            chain: "input", action: "accept", family: 2, proto: "tcp", dport: 443,
            ..Default::default()
        }).unwrap();
        assert!(cmd.contains("inet phantom"));
        assert!(cmd.contains("input"));
        assert!(cmd.contains("tcp dport 443"));
        assert!(cmd.contains("accept"));
    }

    #[test]
    fn test_build_forward_with_ifaces() {
        let cmd = build_rule_cmd(&RuleSpec {
            chain: "forward", action: "accept", family: 2, in_iface: "wg0",
            out_iface: "eth0",
            ..Default::default()
        }).unwrap();
        assert!(cmd.contains("iifname \"wg0\""));
        assert!(cmd.contains("oifname \"eth0\""));
        assert!(cmd.contains("accept"));
        assert!(!cmd.contains("dport"));
    }

    #[test]
    fn test_build_forward_with_state() {
        let cmd = build_rule_cmd(&RuleSpec {
            chain: "forward", action: "accept", family: 2, in_iface: "eth0",
            out_iface: "wg0", state_match: "established,related",
            ..Default::default()
        }).unwrap();
        assert!(cmd.contains("ct state established,related"));
    }

    #[test]
    fn test_build_masquerade() {
        let cmd = build_rule_cmd(&RuleSpec {
            chain: "postrouting", action: "masquerade", family: 2, source: "10.0.1.0/24",
            out_iface: "eth0",
            ..Default::default()
        }).unwrap();
        assert!(cmd.contains("ip saddr 10.0.1.0/24"));
        assert!(cmd.contains("oifname \"eth0\""));
        assert!(cmd.contains("masquerade"));
    }

    #[test]
    fn test_build_ipv6_drop() {
        let cmd = build_rule_cmd(&RuleSpec {
            chain: "input", action: "drop", family: 10,
            ..Default::default()
        }).unwrap();
        assert!(cmd.contains("drop"));
        // family=10 (AF_INET6) affects source/dest prefix, no src/dst → no ip6 in cmd
    }

    #[test]
    fn test_build_dnat_v4_gets_explicit_family() {
        // inet tables reject a bare `dnat to <addr>`: "ip or ip6 must be
        // specified with address for inet tables".
        let cmd = build_rule_cmd(&RuleSpec {
            chain: "prerouting", action: "dnat to 172.28.0.4:443", family: 2, proto: "tcp",
            dport: 443,
            ..Default::default()
        }).unwrap();
        assert!(cmd.contains("dnat ip to 172.28.0.4:443"), "got: {cmd}");
    }

    #[test]
    fn test_build_dnat_v6_gets_explicit_family() {
        let cmd = build_rule_cmd(&RuleSpec {
            chain: "prerouting", action: "dnat to [2001:db8::1]:443", family: 10,
            proto: "tcp", dport: 443,
            ..Default::default()
        }).unwrap();
        assert!(cmd.contains("dnat ip6 to [2001:db8::1]:443"), "got: {cmd}");
    }

    #[test]
    fn test_build_non_dnat_action_untouched() {
        for action in ["accept", "drop", "reject", "masquerade"] {
            let cmd = build_rule_cmd(&RuleSpec {
                chain: "forward", action, family: 2,
                ..Default::default()
            }).unwrap();
            assert!(cmd.ends_with(action), "got: {cmd}");
        }
    }

    #[test]
    fn test_build_with_comment() {
        let cmd = build_rule_cmd(&RuleSpec {
            chain: "input", action: "accept", family: 2, proto: "udp", dport: 51820,
            comment: "phantom-rule-42",
            ..Default::default()
        }).unwrap();
        assert!(cmd.contains("comment \"phantom-rule-42\""));
    }

    #[test]
    fn test_build_source_dest() {
        let cmd = build_rule_cmd(&RuleSpec {
            chain: "output", action: "drop", family: 2, proto: "tcp", dport: 53,
            source: "192.168.1.0/24", destination: "8.8.8.8",
            ..Default::default()
        }).unwrap();
        assert!(cmd.contains("ip saddr 192.168.1.0/24"));
        assert!(cmd.contains("ip daddr 8.8.8.8"));
        assert!(cmd.contains("tcp dport 53"));
        assert!(cmd.contains("drop"));
    }

    // -----------------------------------------------------------------------
    // build_rule_cmd — the whole command for every branch
    // -----------------------------------------------------------------------

    type Case<'a> = RuleSpec<'a>;

    fn build(c: &Case) -> String {
        build_rule_cmd(c).unwrap()
    }

    /// Compares the whole command, so a change in wording or field order
    /// shows up, not only a missing fragment.
    #[test]
    fn test_build_rule_cmd_exact_output() {
        let cases: &[(Case, &str)] = &[
            (Case { chain: "input", action: "accept", family: 2, ..Default::default() },
             "add rule inet phantom input accept"),
            (Case { chain: "input", action: "accept", family: 2, proto: "tcp", dport: 443,
                    ..Default::default() },
             "add rule inet phantom input tcp dport 443 accept"),
            // A port match needs both a protocol and a port above 0.
            (Case { chain: "input", action: "drop", family: 2, proto: "udp", ..Default::default() },
             "add rule inet phantom input drop"),
            (Case { chain: "input", action: "drop", family: 2, dport: 53, ..Default::default() },
             "add rule inet phantom input drop"),
            (Case { chain: "input", action: "drop", family: 2, proto: "tcp", dport: -1,
                    ..Default::default() },
             "add rule inet phantom input drop"),
            (Case { chain: "forward", action: "accept", family: 2, in_iface: "wg0",
                    out_iface: "eth0", ..Default::default() },
             "add rule inet phantom forward iifname \"wg0\" oifname \"eth0\" accept"),
            (Case { chain: "output", action: "drop", family: 2, proto: "tcp", dport: 53,
                    source: "192.168.1.0/24", destination: "8.8.8.8", ..Default::default() },
             "add rule inet phantom output ip saddr 192.168.1.0/24 ip daddr 8.8.8.8 tcp dport 53 drop"),
            (Case { chain: "input", action: "accept", family: 10, source: "2001:db8::/32",
                    destination: "2001:db8::1", ..Default::default() },
             "add rule inet phantom input ip6 saddr 2001:db8::/32 ip6 daddr 2001:db8::1 accept"),
            // Any family other than AF_INET6 (10) reads as IPv4.
            (Case { chain: "input", action: "accept", family: 0, source: "10.0.0.0/8",
                    ..Default::default() },
             "add rule inet phantom input ip saddr 10.0.0.0/8 accept"),
            (Case { chain: "forward", action: "accept", family: 2,
                    state_match: "ESTABLISHED,Related", ..Default::default() },
             "add rule inet phantom forward ct state established,related accept"),
            (Case { chain: "postrouting", action: "masquerade", family: 2,
                    source: "10.0.1.0/24", out_iface: "eth0", ..Default::default() },
             "add rule inet phantom postrouting oifname \"eth0\" ip saddr 10.0.1.0/24 masquerade"),
            (Case { chain: "prerouting", action: "dnat to 172.28.0.4:443", family: 2,
                    proto: "tcp", dport: 443, ..Default::default() },
             "add rule inet phantom prerouting tcp dport 443 dnat ip to 172.28.0.4:443"),
            (Case { chain: "prerouting", action: "dnat to [2001:db8::1]:443", family: 10,
                    proto: "tcp", dport: 443, ..Default::default() },
             "add rule inet phantom prerouting tcp dport 443 dnat ip6 to [2001:db8::1]:443"),
            // Only "dnat to " gets a family; other actions pass through.
            (Case { chain: "prerouting", action: "dnat", family: 2, ..Default::default() },
             "add rule inet phantom prerouting dnat"),
            (Case { chain: "input", action: "reject", family: 10, ..Default::default() },
             "add rule inet phantom input reject"),
            (Case { chain: "input", action: "accept", family: 2, proto: "udp", dport: 51820,
                    comment: "phantom-rule-42", ..Default::default() },
             "add rule inet phantom input udp dport 51820 accept comment \"phantom-rule-42\""),
            (Case { chain: "forward", action: "accept", family: 2, proto: "tcp", dport: 8080,
                    source: "10.0.0.0/24", destination: "10.0.1.5", in_iface: "wg0",
                    out_iface: "eth0", state_match: "NEW", comment: "c" },
             "add rule inet phantom forward iifname \"wg0\" oifname \"eth0\" ip saddr 10.0.0.0/24 \
              ip daddr 10.0.1.5 tcp dport 8080 ct state new accept comment \"c\""),
            // Nothing is validated here; schema.py checks the fields first.
            (Case::default(), "add rule inet phantom  "),
        ];
        for (i, (case, want)) in cases.iter().enumerate() {
            assert_eq!(build(case), *want, "case {i}");
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
    use std::sync::{Mutex, MutexGuard};

    /// Writing a script while another thread forks can leave the write end
    /// open in that child, and exec then fails with ETXTBSY. The tests that
    /// spawn take this lock for their whole body.
    static SPAWN: Mutex<()> = Mutex::new(());

    fn serial() -> MutexGuard<'static, ()> {
        SPAWN.lock().unwrap_or_else(|e| e.into_inner())
    }

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
    fn test_ensure_table_is_one_run() {
        let _serial = serial();
        let nft = fake_nft("ensure_table", "printf 'x\\n' >> \"$0.calls\"");
        let ctx = NftContext::with_binary(&nft).unwrap();
        ensure_table(&ctx).unwrap();
        assert_eq!(recorded(&nft, "calls"), "x\n");
        let args = recorded(&nft, "args");
        let lines: Vec<&str> = args.lines().collect();
        assert_eq!(lines[0], "--");
        assert_eq!(lines[1], "add table inet phantom");
        assert_eq!(lines.len(), 7, "got: {args}");
        for (line, chain) in lines[2..].iter()
            .zip(["input", "output", "forward", "prerouting", "postrouting"]) {
            assert!(line.starts_with(&format!("add chain inet phantom {chain} {{")), "got: {line}");
        }
    }

    #[test]
    fn test_add_rule_takes_the_handle_from_one_run() {
        let _serial = serial();
        let nft = fake_nft("add_rule", &format!(
            "printf 'x\\n' >> \"$0.calls\"\nprintf '%s' '{ECHO}'"));
        let ctx = NftContext::with_binary(&nft).unwrap();
        let handle = add_rule(&ctx, &RuleSpec {
            chain: "input", action: "accept", family: 2, proto: "tcp", dport: 443,
            ..Default::default()
        }).unwrap();
        assert_eq!(handle, 2);
        assert_eq!(recorded(&nft, "calls"), "x\n");
        assert_eq!(recorded(&nft, "args"),
                   "--echo\n--json\n--handle\n--\nadd rule inet phantom input tcp dport 443 accept\n");
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

    /// Processes whose parent is this one, as "pid state".
    fn children() -> Vec<String> {
        let me = std::process::id().to_string();
        std::fs::read_dir("/proc").unwrap()
            .filter_map(|e| std::fs::read_to_string(e.ok()?.path().join("stat")).ok())
            .filter_map(|stat| {
                // pid (comm) state ppid …; comm may hold spaces and parens.
                let (pid, rest) = stat.split_once(' ')?;
                let mut fields = rest.rsplit_once(')')?.1.split_whitespace();
                let state = fields.next()?;
                (fields.next()? == me).then(|| format!("{pid} {state}"))
            })
            .collect()
    }

    /// Every nft is waited for before the call returns, whether it
    /// succeeded, failed or was killed, so none is left behind as a zombie.
    /// The SPAWN lock keeps other tests from having children meanwhile.
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
