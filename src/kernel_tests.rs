//! Tests against the kernel: the real nft program and netlink. They call the
//! exported C functions, as the Python package does, and read the result
//! back with nft and ip.
//!
//! Each test first moves its own thread into a new network and mount
//! namespace (`isolate`), so it starts from an empty ruleset and an empty
//! /etc/iproute2 and leaves the namespace it was started in as it was. That
//! needs CAP_SYS_ADMIN and CAP_NET_ADMIN: the privileged container
//! dev/cargo.sh starts has both, and nft and ip installed.
//!
//! They show the nft and iproute2 of the image they run in (the dev image:
//! nft 1.1.3, iproute2 6.15), not other versions, and a root process, not
//! one whose capability comes from `setcap`.

use std::ffi::{CStr, CString};
use std::io;
use std::process::Command;

use super::*;
use crate::test_support::{children, last_error, serial};

/// Runs a program; returns whether it succeeded, and its stdout.
fn run(program: &str, args: &[&str]) -> (bool, String) {
    let out = Command::new(program)
        .args(args)
        .output()
        .unwrap_or_else(|e| panic!("{program} could not be started: {e}"));
    (out.status.success(), String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Like `run`, and the test fails if the program does.
fn read(program: &str, args: &[&str]) -> String {
    let (ok, out) = run(program, args);
    assert!(ok, "{program} {args:?} failed");
    out
}

fn c(s: &str) -> CString {
    CString::new(s).unwrap()
}

/// Puts the calling thread in a new network and mount namespace, with lo up
/// and an empty tmpfs on /etc/iproute2. libtest runs each test on a thread
/// of its own, so the namespaces end with the test. Programs the test
/// starts, nft included, are born in them.
fn isolate() {
    // SAFETY: unshare takes constant flags and changes only this thread.
    let rc = unsafe { libc::unshare(libc::CLONE_NEWNS | libc::CLONE_NEWNET) };
    assert_eq!(rc, 0, "unshare: {}", io::Error::last_os_error());
    read("mount", &["--make-rprivate", "/"]);
    read("mount", &["-t", "tmpfs", "fwb-test", "/etc/iproute2"]);
    read("ip", &["link", "set", "lo", "up"]);
}

// ---------------------------------------------------------------------------
// nftables
// ---------------------------------------------------------------------------

/// nft_init on entry; nft_close on the way out, panic or not, so the tests
/// that expect no context find none. NFT_CTX is process-wide, unlike the
/// namespaces.
struct Nft;

impl Nft {
    fn init() -> Self {
        assert_eq!(nft_init(), ErrorCode::Ok as i32, "nft_init: {}", last_error());
        Nft
    }
}

impl Drop for Nft {
    fn drop(&mut self) {
        nft_close();
    }
}

fn table() -> String {
    read("nft", &["list", "table", "inet", "phantom"])
}

fn chain(name: &str) -> String {
    read("nft", &["-a", "list", "chain", "inet", "phantom", name])
}

/// `tcp dport <port> accept` with `comment` on input, through the C ABI.
fn add_input_rule(port: i32, comment: &str) -> i64 {
    let (empty, comment) = (c(""), c(comment));
    // SAFETY: NUL-terminated strings that outlive the call.
    unsafe {
        nft_add_rule(c"input".as_ptr(), c"accept".as_ptr(), 2, c"tcp".as_ptr(), port,
                     empty.as_ptr(), empty.as_ptr(), empty.as_ptr(), empty.as_ptr(),
                     empty.as_ptr(), comment.as_ptr())
    }
}

#[test]
fn kernel_nft_table_rules_and_handles() {
    let _serial = serial();
    isolate();
    let _nft = Nft::init();

    let empty_table = table();
    for hook in ["input", "output", "forward", "prerouting", "postrouting"] {
        assert!(empty_table.contains(&format!("chain {hook} {{")), "no {hook}:\n{empty_table}");
    }
    // A second init finds the table and changes nothing.
    assert_eq!(nft_init(), ErrorCode::Ok as i32);
    assert_eq!(table(), empty_table);

    let ports = [22, 80, 443];
    let handles: Vec<i64> = ports.iter().zip(["kural-ğüş", "", "phantom-rule-9"])
        .map(|(&port, comment)| add_input_rule(port, comment))
        .collect();
    let listing = chain("input");
    for (&handle, port) in handles.iter().zip(ports) {
        assert!(handle > 0, "add_rule {port}: {}", last_error());
        let line = listing.lines().find(|l| l.contains(&format!("dport {port} ")))
            .unwrap_or_else(|| panic!("no rule for {port}:\n{listing}"));
        assert!(line.ends_with(&format!("# handle {handle}")), "port {port}: {line}");
    }
    assert!(listing.contains("comment \"kural-ğüş\""), "{listing}");

    // list_table is nft's JSON, with the same handles.
    let raw = nft_list_table();
    assert!(!raw.is_null(), "list_table: {}", last_error());
    // SAFETY: a string nft_list_table returned, read before it is freed.
    let json = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned();
    // SAFETY: returned by nft_list_table and freed once.
    unsafe { firewall_bridge_free_string(raw) };
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
    let listed: Vec<i64> = parsed["nftables"].as_array().unwrap().iter()
        .filter_map(|item| item.get("rule")?.get("handle")?.as_i64())
        .collect();
    assert_eq!(listed, handles);

    // Remove the middle rule by its handle.
    // SAFETY: a NUL-terminated literal.
    assert_eq!(unsafe { nft_remove_rule(c"input".as_ptr(), handles[1] as u64) },
               ErrorCode::Ok as i32);
    let listing = chain("input");
    assert!(!listing.contains("dport 80 "), "{listing}");
    assert!(listing.contains("dport 22 ") && listing.contains("dport 443 "), "{listing}");

    // Flush drops the rules and keeps the chains.
    assert_eq!(nft_flush_table(), ErrorCode::Ok as i32);
    assert_eq!(table(), empty_table);
}

#[test]
fn kernel_nft_errors_reach_the_caller() {
    let _serial = serial();
    isolate();
    let _nft = Nft::init();
    let empty_table = table();
    let empty = c("");

    // SAFETY: NUL-terminated strings that outlive the call.
    let rc = unsafe {
        nft_add_rule(c"nochain".as_ptr(), c"accept".as_ptr(), 2, empty.as_ptr(), 0,
                     empty.as_ptr(), empty.as_ptr(), empty.as_ptr(), empty.as_ptr(),
                     empty.as_ptr(), empty.as_ptr())
    };
    // nft names JSON input "internal" and gives no position in it.
    let refused = "internal:0:0-0: Error: Could not process rule: No such file or directory\n";
    assert_eq!(rc, ErrorCode::NftablesFailed as i64);
    assert!(last_error().starts_with(refused), "{}", last_error());

    // SAFETY: a NUL-terminated literal.
    assert_eq!(unsafe { nft_remove_rule(c"input".as_ptr(), 999_999) },
               ErrorCode::NftablesFailed as i32);
    assert!(last_error().starts_with(refused), "{}", last_error());

    assert_eq!(table(), empty_table, "a failed call changed the table");
}

/// The rule `handle` of inet `table` as nft lists it in JSON, without the
/// fields that name where it is.
fn rule_body(table: &str, handle: u64) -> serde_json::Value {
    let listing: serde_json::Value =
        serde_json::from_str(&read("nft", &["-j", "list", "table", "inet", table])).unwrap();
    let mut rule = listing["nftables"].as_array().unwrap().iter()
        .filter_map(|item| item.get("rule"))
        .find(|rule| rule["handle"] == handle)
        .unwrap_or_else(|| panic!("no rule {handle} in {table}"))
        .clone();
    for key in ["family", "table", "handle"] {
        rule.as_object_mut().unwrap().remove(key);
    }
    rule
}

/// Every rule of nft::tests::rule_cases, through the C ABI. One that
/// build_rule refuses comes back as InvalidParam with its error. One that
/// it builds is taken by nft, and where the case has a text form, nft lists
/// it as it lists that text added to a table of the same chains.
#[test]
fn kernel_nft_builds_what_nft_builds_from_text() {
    let _serial = serial();
    isolate();
    let _nft = Nft::init();
    read("nft", &["add table inet reference"]);
    for chain in ["input { type filter hook input priority 0; policy accept; }",
                  "output { type filter hook output priority 0; policy accept; }",
                  "forward { type filter hook forward priority 0; policy accept; }",
                  "prerouting { type nat hook prerouting priority -100; policy accept; }",
                  "postrouting { type nat hook postrouting priority 100; policy accept; }"] {
        read("nft", &[&format!("add chain inet reference {chain}")]);
    }
    let (mut compared, mut refused) = (0, 0);
    for (i, (rule, built, text)) in crate::nft::tests::rule_cases().into_iter().enumerate() {
        let fields = [rule.chain, rule.action, rule.proto, rule.source, rule.destination,
                      rule.in_iface, rule.out_iface, rule.state_match, rule.comment].map(c);
        let [chain_c, action, proto, source, destination, in_iface, out_iface, state_match, comment] =
            &fields;
        // SAFETY: NUL-terminated strings that outlive the call.
        let handle = unsafe {
            nft_add_rule(chain_c.as_ptr(), action.as_ptr(), rule.family, proto.as_ptr(), rule.dport,
                         source.as_ptr(), destination.as_ptr(), in_iface.as_ptr(),
                         out_iface.as_ptr(), state_match.as_ptr(), comment.as_ptr())
        };
        if let Err(msg) = built {
            assert_eq!(handle, ErrorCode::InvalidParam as i64, "case {i}");
            assert_eq!(last_error(), msg, "case {i}");
            refused += 1;
            continue;
        }
        assert!(handle > 0, "case {i}: nft refused it: {}", last_error());
        let Some(text) = text else { continue };
        let echo = read("nft", &["--echo", "--json", "--handle",
                                 &format!("add rule inet reference {text}")]);
        let echoed: serde_json::Value = serde_json::from_str(&echo).unwrap();
        let reference = echoed["nftables"][0]["add"]["rule"]["handle"].as_u64().unwrap();
        assert_eq!(rule_body("phantom", handle as u64), rule_body("reference", reference),
                   "case {i}: {text}");
        compared += 1;
    }
    let cases = crate::nft::tests::rule_cases();
    assert_eq!(refused, cases.iter().filter(|(_, built, _)| built.is_err()).count());
    assert_eq!(compared, cases.iter().filter(|(_, built, text)| built.is_ok() && text.is_some()).count());
    let tables = read("nft", &["list", "tables"]);
    assert_eq!(tables, "table inet phantom\ntable inet reference\n");
}

/// A table that already holds `output` with another priority: the batch
/// fails as a whole, and nft's caret points at the `output` command.
#[test]
fn kernel_nft_ensure_table_is_all_or_nothing() {
    let _serial = serial();
    isolate();
    read("nft", &["add", "table", "inet", "phantom"]);
    read("nft", &["add chain inet phantom output { type filter hook output priority 10; policy accept; }"]);
    let before = table();

    assert_eq!(nft_init(), ErrorCode::NftablesFailed as i32);
    let err = last_error();
    let lines: Vec<&str> = err.lines().collect();
    assert!(lines[0].starts_with("Error: Chain \"output\" already exists"), "{err}");
    let start = lines[1].find("add chain inet phantom output").expect("command line");
    let end = lines[1].find("; add chain inet phantom forward").expect("command line");
    let caret = lines[2].find('^').expect("caret line");
    assert!((start..end).contains(&caret), "caret {caret} outside {start}..{end}:\n{err}");

    assert_eq!(table(), before, "the failed batch created something");
}

/// Rules added, removed, refused and flushed with the real nft: every nft
/// is waited for, so this process has no child left afterwards.
#[test]
fn kernel_nft_leaves_no_child_behind() {
    let _serial = serial();
    isolate();
    let _nft = Nft::init();
    for port in 1..=20 {
        let handle = add_input_rule(port, "");
        assert!(handle > 0, "{}", last_error());
        // SAFETY: NUL-terminated literals.
        unsafe {
            assert_eq!(nft_remove_rule(c"input".as_ptr(), handle as u64), ErrorCode::Ok as i32);
            assert_eq!(nft_remove_rule(c"input".as_ptr(), handle as u64),
                       ErrorCode::NftablesFailed as i32);
        }
    }
    assert_eq!(nft_flush_table(), ErrorCode::Ok as i32);
    assert_eq!(children(), Vec::<String>::new());
}

/// SIGCHLD set to SIG_IGN while it lives, back to SIG_DFL when dropped. The
/// disposition is process-wide; the serial lock keeps every other test that
/// starts a process out meanwhile.
struct SigchldIgnored;

impl SigchldIgnored {
    fn set() -> Self {
        // SAFETY: signal with a constant disposition and no handler code.
        unsafe { libc::signal(libc::SIGCHLD, libc::SIG_IGN) };
        SigchldIgnored
    }
}

impl Drop for SigchldIgnored {
    fn drop(&mut self) {
        // SAFETY: signal with a constant disposition and no handler code.
        unsafe { libc::signal(libc::SIGCHLD, libc::SIG_DFL) };
    }
}

/// With SIGCHLD ignored the kernel reaps nft before the bridge waits for it:
/// the call returns an error, the rule is in the kernel all the same, and
/// no child is left.
#[test]
fn kernel_nft_with_sigchld_ignored() {
    let _serial = serial();
    isolate();
    let _nft = Nft::init();
    {
        let _ignored = SigchldIgnored::set();
        assert_eq!(add_input_rule(5353, ""), ErrorCode::NftablesFailed as i64);
        assert_eq!(last_error(), "nft did not finish: No child processes (os error 10)");
    }
    assert!(chain("input").contains("tcp dport 5353 accept"), "the rule was not applied");
    assert_eq!(children(), Vec::<String>::new());
}

#[test]
fn kernel_nft_close_ends_the_context() {
    let _serial = serial();
    isolate();
    {
        let _nft = Nft::init();
        assert_eq!(nft_flush_table(), ErrorCode::Ok as i32);
    }
    assert_eq!(nft_flush_table(), ErrorCode::NotInitialized as i32);
}

// ---------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------

const DROP_IN: &str = "/etc/iproute2/rt_tables.d/phantom.conf";

#[test]
fn kernel_routing_tables_rules_and_routes() {
    let _serial = serial();
    isolate();
    let ok = ErrorCode::Ok as i32;
    let failed = ErrorCode::NetlinkFailed as i32;

    // SAFETY: every pointer passed below is a NUL-terminated literal.
    unsafe {
        // The names go to the bridge's own file; iproute2's stay where they are.
        assert_eq!(rt_table_ensure(100, c"fwbtest".as_ptr()), ok, "{}", last_error());
        assert_eq!(rt_table_ensure(1000, c"fwbbig".as_ptr()), ok, "{}", last_error());
        assert_eq!(rt_table_ensure(100, c"fwbtest".as_ptr()), ok);
        assert_eq!(std::fs::read_to_string(DROP_IN).unwrap(), "100 fwbtest\n1000 fwbbig\n");
        assert!(!std::path::Path::new("/etc/iproute2/rt_tables").exists());
        assert!(run("ip", &["route", "show", "table", "unspec"]).0, "ip lost the default names");

        // Policy rules, v4 and v6, a table id above 255 among them.
        assert_eq!(rt_policy_add(c"10.123.0.0/24".as_ptr(), c"".as_ptr(), c"fwbtest".as_ptr(), 3333, 2),
                   ok, "{}", last_error());
        assert_eq!(rt_policy_add(c"fd00:123::/64".as_ptr(), c"fd00:124::/64".as_ptr(),
                                 c"fwbtest".as_ptr(), 3334, 10), ok, "{}", last_error());
        assert_eq!(rt_policy_add(c"10.125.0.0/24".as_ptr(), c"".as_ptr(), c"fwbbig".as_ptr(), 3336, 2),
                   ok, "{}", last_error());
        let rules = read("ip", &["rule", "show"]);
        assert!(rules.contains("3333:\tfrom 10.123.0.0/24 lookup fwbtest"), "{rules}");
        assert!(rules.contains("3336:\tfrom 10.125.0.0/24 lookup fwbbig"), "{rules}");
        let rules6 = read("ip", &["-6", "rule", "show"]);
        assert!(rules6.contains("3334:\tfrom fd00:123::/64 to fd00:124::/64 lookup fwbtest"), "{rules6}");

        assert_eq!(rt_policy_add(c"10.123.0.0/24".as_ptr(), c"".as_ptr(), c"fwbtest".as_ptr(), 3333, 2),
                   failed);
        assert_eq!(last_error(), "netlink error: File exists (os error 17)");

        // Routes over lo, v4 and v6, one in a table above 255.
        assert_eq!(rt_route_add(c"10.124.0.0/16".as_ptr(), c"lo".as_ptr(), c"fwbtest".as_ptr(), 2),
                   ok, "{}", last_error());
        assert_eq!(rt_route_add(c"default".as_ptr(), c"lo".as_ptr(), c"fwbtest".as_ptr(), 10),
                   ok, "{}", last_error());
        assert_eq!(rt_route_add(c"10.126.0.0/16".as_ptr(), c"lo".as_ptr(), c"fwbbig".as_ptr(), 2),
                   ok, "{}", last_error());
        let routes = read("ip", &["route", "show", "table", "fwbtest"]);
        assert!(routes.contains("10.124.0.0/16 dev lo proto static scope link"), "{routes}");
        let routes6 = read("ip", &["-6", "route", "show", "table", "fwbtest"]);
        assert!(routes6.starts_with("default dev lo proto static"), "{routes6}");
        let big = read("ip", &["route", "show", "table", "fwbbig"]);
        assert!(big.contains("10.126.0.0/16 dev lo proto static scope link"), "{big}");

        assert_eq!(rt_route_add(c"10.124.0.0/16".as_ptr(), c"lo".as_ptr(), c"fwbtest".as_ptr(), 2),
                   failed);
        assert_eq!(last_error(), "netlink error: File exists (os error 17)");
        assert_eq!(rt_route_add(c"10.124.0.0/16".as_ptr(), c"nosuch0".as_ptr(), c"fwbtest".as_ptr(), 2),
                   failed);
        assert_eq!(last_error(), "Interface not found: nosuch0");
        assert_eq!(rt_policy_add(c"10.123.0.0/24".as_ptr(), c"".as_ptr(), c"nosuch".as_ptr(), 3335, 2),
                   failed);
        assert_eq!(last_error(), "Routing table not found: nosuch");

        // Deletes, and deleting what is gone.
        assert_eq!(rt_route_delete(c"10.124.0.0/16".as_ptr(), c"lo".as_ptr(), c"fwbtest".as_ptr(), 2),
                   ok, "{}", last_error());
        assert!(!read("ip", &["route", "show", "table", "fwbtest"]).contains("10.124.0.0/16"));
        assert_eq!(rt_route_delete(c"10.124.0.0/16".as_ptr(), c"lo".as_ptr(), c"fwbtest".as_ptr(), 2),
                   failed);
        assert_eq!(last_error(), "netlink error: No such process (os error 3)");

        assert_eq!(rt_policy_delete(c"10.123.0.0/24".as_ptr(), c"".as_ptr(), c"fwbtest".as_ptr(), 3333, 2),
                   ok, "{}", last_error());
        assert_eq!(rt_policy_delete(c"fd00:123::/64".as_ptr(), c"fd00:124::/64".as_ptr(),
                                    c"fwbtest".as_ptr(), 3334, 10), ok, "{}", last_error());
        assert!(!read("ip", &["rule", "show"]).contains("3333:"));
        assert!(!read("ip", &["-6", "rule", "show"]).contains("3334:"));
        assert_eq!(rt_policy_delete(c"10.123.0.0/24".as_ptr(), c"".as_ptr(), c"fwbtest".as_ptr(), 3333, 2),
                   failed);
        assert_eq!(last_error(), "netlink error: No such file or directory (os error 2)");
    }
}

/// The bridge's limit on an rt_tables line is the one ip reads: an entry of
/// 511 characters resolves, and the same entry one character longer, put
/// there by hand, makes ip refuse the file.
#[test]
fn kernel_rt_tables_line_limit_matches_ip() {
    let _serial = serial();
    isolate();
    let fits = "a".repeat(509); // "7 " + 509 = 511 characters
    let (fits_c, over_c) = (c(&fits), c(&format!("{fits}a")));

    // SAFETY: NUL-terminated strings that outlive the calls.
    unsafe {
        assert_eq!(rt_table_ensure(7, over_c.as_ptr()), ErrorCode::NetlinkFailed as i32);
        assert_eq!(last_error(), "Routing table entry longer than 511 characters");
        assert_eq!(rt_table_ensure(7, fits_c.as_ptr()), ErrorCode::Ok as i32, "{}", last_error());
    }
    assert!(run("ip", &["rule", "add", "from", "10.40.0.0/24", "lookup", &fits]).0,
            "ip did not resolve a 511-character entry");

    std::fs::write(DROP_IN, format!("7 {fits}a\n8 after\n")).unwrap();
    assert!(!run("ip", &["rule", "add", "from", "10.41.0.0/24", "lookup", "after"]).0,
            "ip read a 512-character entry");
}

/// A name given twice, in rt_tables and in a drop-in, with ids in different
/// and in the same `id % 256`: a route the bridge adds by that name lands in
/// the table `ip` picks for it.
#[test]
fn kernel_table_names_resolve_as_ip_resolves() {
    let _serial = serial();
    isolate();
    std::fs::write("/etc/iproute2/rt_tables", "200 fwbdup\n300 fwbdup\n").unwrap();
    std::fs::create_dir_all("/etc/iproute2/rt_tables.d").unwrap();
    for (drop_in, picked) in [("44 fwbdup\n", "44"), ("556 fwbdup\n", "556")] {
        std::fs::write("/etc/iproute2/rt_tables.d/x.conf", drop_in).unwrap();
        read("ip", &["route", "add", "10.51.0.0/16", "dev", "lo", "table", "fwbdup"]);
        // SAFETY: NUL-terminated literals.
        let rc = unsafe {
            rt_route_add(c"10.50.0.0/16".as_ptr(), c"lo".as_ptr(), c"fwbdup".as_ptr(), 2)
        };
        assert_eq!(rc, ErrorCode::Ok as i32, "{}", last_error());
        let routes = read("ip", &["route", "show", "table", picked]);
        assert!(routes.contains("10.50.0.0/16") && routes.contains("10.51.0.0/16"),
                "table {picked}: {routes}");
        read("ip", &["route", "flush", "table", picked]);
    }
}

const IP_FORWARD: &str = "/proc/sys/net/ipv4/ip_forward";

#[test]
fn kernel_forwarding_and_route_cache() {
    let _serial = serial();
    isolate();
    // Off first: a container may start with forwarding on.
    std::fs::write(IP_FORWARD, "0").unwrap();
    assert_eq!(std::fs::read_to_string(IP_FORWARD).unwrap().trim(), "0");
    assert_eq!(rt_enable_ip_forward(), ErrorCode::Ok as i32, "{}", last_error());
    assert_eq!(std::fs::read_to_string(IP_FORWARD).unwrap().trim(), "1");
    assert_eq!(rt_flush_cache(), ErrorCode::Ok as i32);
}
