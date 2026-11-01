//! Tests against the kernel: the real nft program and netlink, in the
//! network namespace of the container dev/cargo.sh starts (privileged, nft
//! installed). They call the exported C functions, as the Python package
//! does, and read the result back with nft and ip.

use std::ffi::{CStr, CString};
use std::process::Command;

use super::*;
use crate::test_support::{last_error, serial};

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

// ---------------------------------------------------------------------------
// nftables
// ---------------------------------------------------------------------------

/// nft_init on entry; nft_close and no table on the way out, panic or not,
/// so the next test, and the ones that expect no context, find none.
struct Nft;

impl Nft {
    fn init() -> Self {
        let _ = run("nft", &["delete", "table", "inet", "phantom"]);
        assert_eq!(nft_init(), ErrorCode::Ok as i32, "nft_init: {}", last_error());
        Nft
    }
}

impl Drop for Nft {
    fn drop(&mut self) {
        nft_close();
        let _ = run("nft", &["delete", "table", "inet", "phantom"]);
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
    let _nft = Nft::init();
    let empty_table = table();
    let empty = c("");

    // SAFETY: NUL-terminated strings that outlive the call.
    let rc = unsafe {
        nft_add_rule(c"nochain".as_ptr(), c"accept".as_ptr(), 2, empty.as_ptr(), 0,
                     empty.as_ptr(), empty.as_ptr(), empty.as_ptr(), empty.as_ptr(),
                     empty.as_ptr(), empty.as_ptr())
    };
    assert_eq!(rc, ErrorCode::NftablesFailed as i64);
    assert!(last_error().starts_with(
        "Error: Could not process rule: No such file or directory\nadd rule inet phantom nochain accept"),
        "{}", last_error());

    // SAFETY: a NUL-terminated literal.
    assert_eq!(unsafe { nft_remove_rule(c"input".as_ptr(), 999_999) },
               ErrorCode::NftablesFailed as i32);
    assert!(last_error().starts_with("Error: Could not process rule: No such file or directory"),
            "{}", last_error());

    assert_eq!(table(), empty_table, "a failed call changed the table");
}

#[test]
fn kernel_nft_close_ends_the_context() {
    let _serial = serial();
    {
        let _nft = Nft::init();
        assert_eq!(nft_flush_table(), ErrorCode::Ok as i32);
    }
    assert_eq!(nft_flush_table(), ErrorCode::NotInitialized as i32);
}

// ---------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------

const RT_TABLES: &str = "/etc/iproute2/rt_tables";

/// Starts without /etc/iproute2/rt_tables; on the way out, panic or not,
/// removes the test's rules and routes and puts the file back as it was.
struct Routing {
    saved: Option<Vec<u8>>,
}

impl Routing {
    fn start() -> Self {
        let saved = std::fs::read(RT_TABLES).ok();
        let _ = std::fs::remove_file(RT_TABLES);
        Routing { saved }
    }
}

impl Drop for Routing {
    fn drop(&mut self) {
        for priority in ["3333", "3334", "3336"] {
            let _ = run("ip", &["rule", "del", "priority", priority]);
            let _ = run("ip", &["-6", "rule", "del", "priority", priority]);
        }
        for table in ["100", "1000"] {
            let _ = run("ip", &["route", "flush", "table", table]);
            let _ = run("ip", &["-6", "route", "flush", "table", table]);
        }
        let _ = match &self.saved {
            Some(content) => std::fs::write(RT_TABLES, content),
            None => std::fs::remove_file(RT_TABLES),
        };
    }
}

#[test]
fn kernel_routing_tables_rules_and_routes() {
    let _serial = serial();
    let _routing = Routing::start();
    let ok = ErrorCode::Ok as i32;
    let failed = ErrorCode::NetlinkFailed as i32;

    // SAFETY: every pointer passed below is a NUL-terminated literal.
    unsafe {
        // The first entry starts the file from iproute2's defaults.
        assert_eq!(rt_table_ensure(100, c"fwbtest".as_ptr()), ok, "{}", last_error());
        assert_eq!(rt_table_ensure(1000, c"fwbbig".as_ptr()), ok, "{}", last_error());
        assert_eq!(rt_table_ensure(100, c"fwbtest".as_ptr()), ok);
        let file = std::fs::read_to_string(RT_TABLES).unwrap();
        assert!(file.lines().any(|l| l.split_whitespace().eq(["0", "unspec"])), "{file}");
        assert!(file.ends_with("100 fwbtest\n1000 fwbbig\n"), "{file}");
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

#[test]
fn kernel_forwarding_and_route_cache() {
    let _serial = serial();
    assert_eq!(rt_enable_ip_forward(), ErrorCode::Ok as i32, "{}", last_error());
    assert_eq!(std::fs::read_to_string("/proc/sys/net/ipv4/ip_forward").unwrap().trim(), "1");
    assert_eq!(rt_flush_cache(), ErrorCode::Ok as i32);
}
