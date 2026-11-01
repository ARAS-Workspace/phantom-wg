//! firewall-bridge-linux: the kernel side of firewall-bridge, behind a C ABI.
//! nftables goes through the nft program, routing through netlink.
//!
//! ─── HOW TO READ THIS CRATE ──────────────────────────────────────────
//!
//! A comment names what an item is, or what a caller has to hold. It does
//! not explain, argue or promise what the code does: the code is the only
//! authority on its own behaviour. Where a behaviour is claimed, the
//! comment points at the test that asserts it:
//!
//!     /// @witness nft::tests::test_ensure_table_is_one_run
//!
//! The path is the test's path in `cargo test` output, so
//! `dev/cargo.sh test --lib -- --exact <path>` runs exactly that test, and
//! grepping the name finds its assertions. An item with several markers is
//! asserted from several angles. `tests::witness_markers_name_tests` fails
//! when a marker names a test that does not exist.
//!
//! Rust asks for two kinds of prose, and they stay: a `# Safety` section on
//! every `unsafe fn`, saying what its caller has to hold, and a
//! `// SAFETY:` comment on every `unsafe` block, saying why that holds
//! there.
//!
//! The markers are not exhaustive. An item without one is not annotated;
//! that does not make it untested.
//!
//! Test modules open with a header naming what they drive and, where it
//! matters, what they cannot show.
//!
//! ──────────────────────────────────────────────────────────────────────

mod error;
mod nft;
mod route;

#[cfg(test)]
mod test_support {
    use std::sync::{Mutex, MutexGuard};

    /// One lock for every test that starts a process or touches the
    /// process-wide state (NFT_CTX, LAST_ERROR, the network namespace).
    /// Writing a script while another thread forks can leave the write end
    /// open in that child, and exec then fails with ETXTBSY; the globals
    /// would otherwise be read by one test while another writes them.
    static SERIAL: Mutex<()> = Mutex::new(());

    pub fn serial() -> MutexGuard<'static, ()> {
        SERIAL.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Processes whose parent is this one, as "pid state".
    pub fn children() -> Vec<String> {
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

    /// The last recorded error, read the way a C caller reads it.
    pub fn last_error() -> String {
        use std::ffi::{c_char, CStr};
        let mut buf = [0 as c_char; 1024];
        // SAFETY: `buf` holds the length passed.
        let n = unsafe { super::firewall_bridge_get_last_error_copy(buf.as_mut_ptr(), buf.len() as i32) };
        if n <= 0 {
            return String::new();
        }
        // SAFETY: the copy NUL-terminated `buf`.
        unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned()
    }
}

#[cfg(test)]
mod kernel_tests;

use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::sync::Mutex;

use error::ErrorCode;
use nft::NftContext;

/// The crate version as a C string.
///
/// @witness tests::version_is_the_crate_version_at_one_address
static VERSION: &CStr = match CStr::from_bytes_with_nul(
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_bytes()
) {
    Ok(v) => v,
    Err(_) => panic!("CARGO_PKG_VERSION holds a NUL byte"),
};

// ---------------------------------------------------------------------------
// Global nft context
// ---------------------------------------------------------------------------

static NFT_CTX: Mutex<Option<NftContext>> = Mutex::new(None);
static LAST_ERROR: Mutex<Option<CString>> = Mutex::new(None);

/// Run `f` against the initialized nft context, or return `uninit`.
///
/// @witness tests::uninitialized_context_returns_code_not_panic
/// @witness kernel_tests::kernel_nft_close_ends_the_context
fn with_nft<F, R>(uninit: R, f: F) -> R
where
    F: FnOnce(&NftContext) -> R,
{
    let guard = NFT_CTX.lock().unwrap_or_else(|e| e.into_inner());
    match guard.as_ref() {
        Some(ctx) => f(ctx),
        None => {
            set_last_error("nft context not initialized: call nft_init first");
            uninit
        }
    }
}

fn set_last_error(msg: &str) {
    if let Ok(mut guard) = LAST_ERROR.lock() {
        *guard = CString::new(msg).ok();
    }
}

/// A routing family from the C ABI, as the u8 the routing code takes.
///
/// @witness tests::routing_family_outside_u8_is_refused
/// @witness tests::routing_family_outside_u8_is_refused_at_the_boundary
fn family_arg(family: i32) -> Result<u8, String> {
    u8::try_from(family).map_err(|_| format!("Unknown address family: {family}"))
}

fn to_heap_cstring(s: &str) -> *mut c_char {
    CString::new(s).map(|c| c.into_raw()).unwrap_or(ptr::null_mut())
}

/// Borrow a C string as `&str`.
///
/// @witness tests::cstr_to_str_reads_null_and_invalid_utf8_as_empty
///
/// # Safety
///
/// `ptr` is null or points to a NUL-terminated string that stays valid and
/// unchanged for `'a`.
unsafe fn cstr_to_str<'a>(ptr: *const c_char) -> &'a str {
    if ptr.is_null() { "" }
    // SAFETY: `ptr` is not null; the rest is this function's contract.
    else { unsafe { CStr::from_ptr(ptr) }.to_str().unwrap_or("") }
}

// ---------------------------------------------------------------------------
// nftables FFI
// ---------------------------------------------------------------------------

/// Initialize nft context and ensure phantom table + chains exist.
/// Must be called before any other nft_* function.
///
/// @witness kernel_tests::kernel_nft_table_rules_and_handles
/// @witness kernel_tests::kernel_nft_ensure_table_is_all_or_nothing
/// @witness tests::uninitialized_context_returns_code_not_panic
#[unsafe(no_mangle)]
pub extern "C" fn nft_init() -> i32 {
    let ctx = match NftContext::new() {
        Ok(c) => c,
        Err(msg) => {
            set_last_error(msg);
            return ErrorCode::NftablesFailed as i32;
        }
    };

    if let Err(msg) = nft::ensure_table(&ctx) {
        set_last_error(&msg);
        return ErrorCode::NftablesFailed as i32;
    }

    let mut guard = NFT_CTX.lock().unwrap_or_else(|e| e.into_inner());
    *guard = Some(ctx);
    ErrorCode::Ok as i32
}

/// Close nft context and release resources.
///
/// @witness kernel_tests::kernel_nft_close_ends_the_context
#[unsafe(no_mangle)]
pub extern "C" fn nft_close() {
    let mut guard = NFT_CTX.lock().unwrap_or_else(|e| e.into_inner());
    *guard = None;
}

/// Add a firewall rule to the phantom table. Returns nft handle (>0) or negative error.
///
/// @witness kernel_tests::kernel_nft_table_rules_and_handles
/// @witness kernel_tests::kernel_nft_builds_what_nft_builds_from_text
/// @witness kernel_tests::kernel_nft_errors_reach_the_caller
/// @witness tests::null_pointers_give_error_codes
///
/// # Safety
///
/// Each string pointer is null or a NUL-terminated string that stays valid
/// and unchanged for the call. Null reads as an empty string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nft_add_rule(
    chain: *const c_char,
    action: *const c_char,
    family: i32,
    proto: *const c_char,
    dport: i32,
    source: *const c_char,
    destination: *const c_char,
    in_iface: *const c_char,
    out_iface: *const c_char,
    state_match: *const c_char,
    comment: *const c_char,
) -> i64 {
    // SAFETY: every pointer meets this function's contract.
    let rule = unsafe {
        nft::RuleSpec {
            chain: cstr_to_str(chain),
            action: cstr_to_str(action),
            family,
            proto: cstr_to_str(proto),
            dport,
            source: cstr_to_str(source),
            destination: cstr_to_str(destination),
            in_iface: cstr_to_str(in_iface),
            out_iface: cstr_to_str(out_iface),
            state_match: cstr_to_str(state_match),
            comment: cstr_to_str(comment),
        }
    };

    with_nft(ErrorCode::NotInitialized as i64, |ctx| {
        let cmd = match nft::build_rule(&rule) {
            Ok(cmd) => cmd,
            Err(msg) => { set_last_error(&msg); return ErrorCode::InvalidParam as i64; }
        };
        match nft::add_rule(ctx, &cmd) {
            Ok(handle) => handle as i64,
            Err(msg) => { set_last_error(&msg); ErrorCode::NftablesFailed as i64 }
        }
    })
}

/// Remove a firewall rule by chain + nft handle.
///
/// @witness kernel_tests::kernel_nft_table_rules_and_handles
/// @witness kernel_tests::kernel_nft_errors_reach_the_caller
///
/// # Safety
///
/// `chain` is null or a NUL-terminated string that stays valid and
/// unchanged for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nft_remove_rule(chain: *const c_char, handle: u64) -> i32 {
    // SAFETY: `chain` meets this function's contract.
    let ch = unsafe { cstr_to_str(chain) };
    with_nft(ErrorCode::NotInitialized as i32, |ctx| {
        match nft::remove_rule(ctx, ch, handle) {
            Ok(()) => ErrorCode::Ok as i32,
            Err(msg) => { set_last_error(&msg); ErrorCode::NftablesFailed as i32 }
        }
    })
}

/// One rule for `nft_replace_rules`, field for field as `nft_add_rule`
/// takes it.
#[repr(C)]
pub struct NftRule {
    pub chain: *const c_char,
    pub action: *const c_char,
    pub family: i32,
    pub proto: *const c_char,
    pub dport: i32,
    pub source: *const c_char,
    pub destination: *const c_char,
    pub in_iface: *const c_char,
    pub out_iface: *const c_char,
    pub state_match: *const c_char,
    pub comment: *const c_char,
}

/// Flush the phantom table and add `rules`, in one nft transaction; on
/// success writes each rule's handle to `handles`, in order. On an error
/// the table is as it was and `handles` is not written.
///
/// @witness kernel_tests::kernel_nft_replace_rules_is_one_transaction
/// @witness tests::null_pointers_give_error_codes
///
/// # Safety
///
/// When `count` is above 0, `rules` points to `count` NftRule values and
/// `handles` to room for `count` u64 values, both valid for the call; each
/// string pointer in a rule is null or a NUL-terminated string that stays
/// valid and unchanged for the call. Null reads as an empty string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nft_replace_rules(rules: *const NftRule, count: i32, handles: *mut u64)
    -> i32
{
    let Ok(count) = usize::try_from(count) else {
        set_last_error("Rule count is negative");
        return ErrorCode::InvalidParam as i32;
    };
    if count > 0 && (rules.is_null() || handles.is_null()) {
        set_last_error("Rules or handles is null");
        return ErrorCode::InvalidParam as i32;
    }
    let rules: &[NftRule] = if count == 0 { &[] } else {
        // SAFETY: `rules` is not null and points to `count` values, per the contract.
        unsafe { std::slice::from_raw_parts(rules, count) }
    };
    // SAFETY: every string pointer meets this function's contract.
    let specs: Vec<nft::RuleSpec> = rules.iter().map(|r| unsafe {
        nft::RuleSpec {
            chain: cstr_to_str(r.chain),
            action: cstr_to_str(r.action),
            family: r.family,
            proto: cstr_to_str(r.proto),
            dport: r.dport,
            source: cstr_to_str(r.source),
            destination: cstr_to_str(r.destination),
            in_iface: cstr_to_str(r.in_iface),
            out_iface: cstr_to_str(r.out_iface),
            state_match: cstr_to_str(r.state_match),
            comment: cstr_to_str(r.comment),
        }
    }).collect();

    with_nft(ErrorCode::NotInitialized as i32, |ctx| {
        let commands = match specs.iter().map(nft::rule_command).collect::<Result<Vec<_>, _>>() {
            Ok(commands) => commands,
            Err(msg) => { set_last_error(&msg); return ErrorCode::InvalidParam as i32; }
        };
        match nft::replace_rules(ctx, commands) {
            Ok(added) => {
                // SAFETY: `handles` has room for `count` values, per the contract, and
                // `added` holds exactly `count`.
                unsafe { std::ptr::copy_nonoverlapping(added.as_ptr(), handles, added.len()) };
                ErrorCode::Ok as i32
            }
            Err(msg) => { set_last_error(&msg); ErrorCode::NftablesFailed as i32 }
        }
    })
}

/// Flush all rules in the phantom table.
///
/// @witness kernel_tests::kernel_nft_table_rules_and_handles
#[unsafe(no_mangle)]
pub extern "C" fn nft_flush_table() -> i32 {
    with_nft(ErrorCode::NotInitialized as i32, |ctx| {
        match nft::flush_table(ctx) {
            Ok(()) => ErrorCode::Ok as i32,
            Err(msg) => { set_last_error(&msg); ErrorCode::NftablesFailed as i32 }
        }
    })
}

/// List phantom table as JSON. Caller must free with firewall_bridge_free_string.
///
/// @witness kernel_tests::kernel_nft_table_rules_and_handles
#[unsafe(no_mangle)]
pub extern "C" fn nft_list_table() -> *mut c_char {
    with_nft(ptr::null_mut(), |ctx| {
        match nft::list_table(ctx) {
            Ok(json) => to_heap_cstring(&json),
            Err(msg) => { set_last_error(&msg); ptr::null_mut() }
        }
    })
}

// ---------------------------------------------------------------------------
// Routing FFI
// ---------------------------------------------------------------------------

/// Name a routing table in /etc/iproute2/rt_tables.d/phantom.conf.
///
/// @witness kernel_tests::kernel_routing_tables_rules_and_routes
/// @witness kernel_tests::kernel_rt_tables_line_limit_matches_ip
/// @witness tests::null_pointers_give_error_codes
/// @witness tests::invalid_utf8_reads_as_empty_at_the_boundary
///
/// # Safety
///
/// `table_name` is null or a NUL-terminated string that stays valid and
/// unchanged for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_table_ensure(table_id: u32, table_name: *const c_char) -> i32 {
    // SAFETY: `table_name` meets this function's contract.
    let name = unsafe { cstr_to_str(table_name) };
    match route::ensure_table(table_id, name) {
        Ok(()) => ErrorCode::Ok as i32,
        Err(msg) => { set_last_error(&msg); ErrorCode::NetlinkFailed as i32 }
    }
}

/// Add a policy rule (ip rule add from ... table ... priority ...).
/// family: 2 = AF_INET, 10 = AF_INET6.
///
/// @witness kernel_tests::kernel_routing_tables_rules_and_routes
/// @witness tests::null_pointers_give_error_codes
/// @witness tests::routing_family_outside_u8_is_refused_at_the_boundary
///
/// # Safety
///
/// Each string pointer is null or a NUL-terminated string that stays valid
/// and unchanged for the call. Null reads as an empty string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_policy_add(
    from_network: *const c_char,
    to_network: *const c_char,
    table_name: *const c_char,
    priority: u32,
    family: i32,
) -> i32 {
    // SAFETY: every pointer meets this function's contract.
    let (frm, to, tn) = unsafe {
        (cstr_to_str(from_network), cstr_to_str(to_network), cstr_to_str(table_name))
    };

    match family_arg(family).and_then(|f| route::policy_add(frm, to, tn, priority, f)) {
        Ok(()) => ErrorCode::Ok as i32,
        Err(msg) => { set_last_error(&msg); ErrorCode::NetlinkFailed as i32 }
    }
}

/// Delete a policy rule.
///
/// @witness kernel_tests::kernel_routing_tables_rules_and_routes
/// @witness tests::null_pointers_give_error_codes
/// @witness tests::routing_family_outside_u8_is_refused_at_the_boundary
///
/// # Safety
///
/// Each string pointer is null or a NUL-terminated string that stays valid
/// and unchanged for the call. Null reads as an empty string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_policy_delete(
    from_network: *const c_char,
    to_network: *const c_char,
    table_name: *const c_char,
    priority: u32,
    family: i32,
) -> i32 {
    // SAFETY: every pointer meets this function's contract.
    let (frm, to, tn) = unsafe {
        (cstr_to_str(from_network), cstr_to_str(to_network), cstr_to_str(table_name))
    };

    match family_arg(family).and_then(|f| route::policy_delete(frm, to, tn, priority, f)) {
        Ok(()) => ErrorCode::Ok as i32,
        Err(msg) => { set_last_error(&msg); ErrorCode::NetlinkFailed as i32 }
    }
}

/// Add a route (ip route add ... dev ... table ...).
/// family: 2 = AF_INET, 10 = AF_INET6.
///
/// @witness kernel_tests::kernel_routing_tables_rules_and_routes
/// @witness kernel_tests::kernel_route_delete_takes_a_route_of_any_scope
/// @witness tests::null_pointers_give_error_codes
/// @witness tests::routing_family_outside_u8_is_refused_at_the_boundary
///
/// # Safety
///
/// Each string pointer is null or a NUL-terminated string that stays valid
/// and unchanged for the call. Null reads as an empty string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_route_add(
    destination: *const c_char,
    device: *const c_char,
    table_name: *const c_char,
    family: i32,
) -> i32 {
    // SAFETY: every pointer meets this function's contract.
    let (dst, dev, tn) = unsafe {
        (cstr_to_str(destination), cstr_to_str(device), cstr_to_str(table_name))
    };

    match family_arg(family).and_then(|f| route::route_add(dst, dev, tn, f)) {
        Ok(()) => ErrorCode::Ok as i32,
        Err(msg) => { set_last_error(&msg); ErrorCode::NetlinkFailed as i32 }
    }
}

/// Delete a route.
///
/// @witness kernel_tests::kernel_routing_tables_rules_and_routes
/// @witness kernel_tests::kernel_route_delete_takes_a_route_of_any_scope
/// @witness tests::null_pointers_give_error_codes
/// @witness tests::routing_family_outside_u8_is_refused_at_the_boundary
///
/// # Safety
///
/// Each string pointer is null or a NUL-terminated string that stays valid
/// and unchanged for the call. Null reads as an empty string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rt_route_delete(
    destination: *const c_char,
    device: *const c_char,
    table_name: *const c_char,
    family: i32,
) -> i32 {
    // SAFETY: every pointer meets this function's contract.
    let (dst, dev, tn) = unsafe {
        (cstr_to_str(destination), cstr_to_str(device), cstr_to_str(table_name))
    };

    match family_arg(family).and_then(|f| route::route_delete(dst, dev, tn, f)) {
        Ok(()) => ErrorCode::Ok as i32,
        Err(msg) => { set_last_error(&msg); ErrorCode::NetlinkFailed as i32 }
    }
}

/// Enable IPv4 forwarding.
///
/// @witness kernel_tests::kernel_forwarding_and_route_cache
#[unsafe(no_mangle)]
pub extern "C" fn rt_enable_ip_forward() -> i32 {
    match route::enable_ip_forward() {
        Ok(()) => ErrorCode::Ok as i32,
        Err(msg) => { set_last_error(&msg); ErrorCode::IoError as i32 }
    }
}

/// Flush route cache.
///
/// @witness kernel_tests::kernel_forwarding_and_route_cache
#[unsafe(no_mangle)]
pub extern "C" fn rt_flush_cache() -> i32 {
    match route::flush_cache() {
        Ok(()) => ErrorCode::Ok as i32,
        Err(msg) => { set_last_error(&msg); ErrorCode::IoError as i32 }
    }
}

// ---------------------------------------------------------------------------
// Utility FFI
// ---------------------------------------------------------------------------

/// Return version string (static, do NOT free).
///
/// @witness tests::version_is_the_crate_version_at_one_address
#[unsafe(no_mangle)]
pub extern "C" fn firewall_bridge_get_version() -> *const c_char {
    VERSION.as_ptr()
}

/// Return last error message (do NOT free).
///
/// Deprecated: the pointer is invalidated by the next recorded error.
/// Prefer firewall_bridge_get_last_error_copy.
#[unsafe(no_mangle)]
pub extern "C" fn firewall_bridge_get_last_error() -> *const c_char {
    if let Ok(guard) = LAST_ERROR.lock() {
        guard.as_ref().map(|c| c.as_ptr()).unwrap_or(ptr::null())
    } else {
        ptr::null()
    }
}

/// Copy the last error message into a caller-provided buffer.
///
/// Copies at most len-1 bytes plus a NUL terminator, under the error lock.
/// Returns the number of bytes copied, or FW_ERR_INVALID_PARAM for a null
/// buffer / non-positive len. 0 means nothing was copied: no error is
/// recorded, or `len` is 1 and holds the NUL alone.
///
/// @witness tests::last_error_copy_roundtrip_truncation_and_guards
/// @witness tests::uninitialized_context_returns_code_not_panic
///
/// # Safety
///
/// `buf` is null or valid for writes of `len` bytes, and does not point into
/// the string `firewall_bridge_get_last_error` returned.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn firewall_bridge_get_last_error_copy(buf: *mut c_char, len: i32) -> i32 {
    if buf.is_null() || len <= 0 {
        return ErrorCode::InvalidParam as i32;
    }
    let guard = match LAST_ERROR.lock() {
        Ok(g) => g,
        Err(e) => e.into_inner(),
    };
    let msg = match guard.as_ref() {
        Some(c) => c.as_bytes(),
        None => {
            // SAFETY: `buf` is not null and `len` > 0, so its first byte is writable.
            unsafe { *buf = 0 };
            return 0;
        }
    };
    let n = msg.len().min(len as usize - 1);
    // SAFETY: n + 1 <= len bytes go into `buf`, which holds `len`; `msg` is
    // the CString's own allocation, so the two ranges do not overlap.
    unsafe {
        std::ptr::copy_nonoverlapping(msg.as_ptr() as *const c_char, buf, n);
        *buf.add(n) = 0;
    }
    n as i32
}

/// Free a heap-allocated string returned by nft_list_table.
///
/// @witness kernel_tests::kernel_nft_table_rules_and_handles
/// @witness tests::null_pointers_give_error_codes
///
/// # Safety
///
/// `ptr` is null or a pointer `nft_list_table` returned that has not been
/// freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn firewall_bridge_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        // SAFETY: `ptr` came from `CString::into_raw` in `to_heap_cstring`
        // and is freed once, per this function's contract.
        unsafe { drop(CString::from_raw(ptr)); }
    }
}

// ---------------------------------------------------------------------------
// Tests — FFI boundary behavior (no kernel required)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::last_error;

    /// Uninitialized context must surface as an error code, never a panic:
    /// this crate sits behind an FFI boundary and a panic aborts the daemon.
    #[test]
    fn uninitialized_context_returns_code_not_panic() {
        let _serial = test_support::serial();
        // The kernel tests close the context they open, and the serial lock
        // keeps them apart from this test, so it finds none.
        assert_eq!(nft_flush_table(), ErrorCode::NotInitialized as i32);
        // SAFETY: a null chain is allowed.
        assert_eq!(unsafe { nft_remove_rule(ptr::null(), 1) }, ErrorCode::NotInitialized as i32);
        assert!(nft_list_table().is_null());

        let mut buf = [0 as c_char; 128];
        // SAFETY: `buf` holds the length passed.
        let n = unsafe { firewall_bridge_get_last_error_copy(buf.as_mut_ptr(), buf.len() as i32) };
        assert!(n > 0);
        // SAFETY: the copy NUL-terminated `buf`.
        let msg = unsafe { CStr::from_ptr(buf.as_ptr()) }.to_str().unwrap();
        assert!(msg.contains("not initialized"), "{msg}");
    }

    #[test]
    fn cstr_to_str_reads_null_and_invalid_utf8_as_empty() {
        // SAFETY: null, and NUL-terminated literals.
        unsafe {
            assert_eq!(cstr_to_str(ptr::null()), "");
            assert_eq!(cstr_to_str(c"".as_ptr()), "");
            assert_eq!(cstr_to_str(c"inet phantom".as_ptr()), "inet phantom");
            assert_eq!(cstr_to_str(c"kural-\xc4\x9f".as_ptr()), "kural-ğ");
            assert_eq!(cstr_to_str(c"\xff\xfe".as_ptr()), "");
        }
    }

    /// Every pointer argument takes null; the call returns a code and
    /// records why, without a panic.
    #[test]
    fn null_pointers_give_error_codes() {
        let _serial = test_support::serial();
        let null = ptr::null();
        // SAFETY: null is allowed for every pointer argument.
        unsafe {
            assert_eq!(nft_add_rule(null, null, 2, null, 0, null, null, null, null, null, null),
                       ErrorCode::NotInitialized as i64);
            assert_eq!(nft_replace_rules(ptr::null(), 0, ptr::null_mut()),
                       ErrorCode::NotInitialized as i32);
            assert_eq!(nft_replace_rules(ptr::null(), 1, ptr::null_mut()),
                       ErrorCode::InvalidParam as i32);
            assert_eq!(last_error(), "Rules or handles is null");
            assert_eq!(nft_replace_rules(ptr::null(), -1, ptr::null_mut()),
                       ErrorCode::InvalidParam as i32);
            assert_eq!(last_error(), "Rule count is negative");
            assert_eq!(rt_table_ensure(101, null), ErrorCode::NetlinkFailed as i32);
            assert_eq!(last_error(), "Invalid routing table name: \"\"");
            type NamedCall = (&'static str, fn() -> i32);
            let calls: [NamedCall; 4] = [
                ("rt_policy_add", || rt_policy_add(ptr::null(), ptr::null(), ptr::null(), 1, 2)),
                ("rt_policy_delete", || rt_policy_delete(ptr::null(), ptr::null(), ptr::null(), 1, 2)),
                ("rt_route_add", || rt_route_add(ptr::null(), ptr::null(), ptr::null(), 2)),
                ("rt_route_delete", || rt_route_delete(ptr::null(), ptr::null(), ptr::null(), 2)),
            ];
            for (name, call) in calls {
                // A message left by the call before would pass for this one's.
                set_last_error("sentinel");
                assert_eq!(call(), ErrorCode::NetlinkFailed as i32, "{name}");
                let msg = last_error();
                assert!(!msg.is_empty() && msg != "sentinel", "{name} recorded no error: {msg:?}");
            }
            firewall_bridge_free_string(ptr::null_mut());
        }
    }

    #[test]
    fn invalid_utf8_reads_as_empty_at_the_boundary() {
        let _serial = test_support::serial();
        // SAFETY: a NUL-terminated literal.
        assert_eq!(unsafe { rt_table_ensure(101, c"\xff".as_ptr()) }, ErrorCode::NetlinkFailed as i32);
        assert_eq!(last_error(), "Invalid routing table name: \"\"");
    }

    /// The family is checked before any socket is opened.
    #[test]
    fn routing_family_outside_u8_is_refused_at_the_boundary() {
        let _serial = test_support::serial();
        let (net, empty, table, dev) = (c"10.0.0.0/24".as_ptr(), c"".as_ptr(), c"main".as_ptr(), c"lo".as_ptr());
        // SAFETY: NUL-terminated literals.
        let codes = unsafe {
            [rt_policy_add(net, empty, table, 1, 266), rt_policy_delete(net, empty, table, 1, 266),
             rt_route_add(net, dev, table, 266), rt_route_delete(net, dev, table, 266)]
        };
        for rc in codes {
            assert_eq!(rc, ErrorCode::NetlinkFailed as i32);
        }
        assert_eq!(last_error(), "Unknown address family: 266");
    }

    #[test]
    fn routing_family_outside_u8_is_refused() {
        assert_eq!(family_arg(10), Ok(10));
        assert_eq!(family_arg(266), Err("Unknown address family: 266".into()));
        assert_eq!(family_arg(-1), Err("Unknown address family: -1".into()));
    }

    /// Every `@witness` marker in the sources names a test that exists: the
    /// path's module picks the file, and its last segment has to be a
    /// function right under `#[test]` in that file.
    #[test]
    fn witness_markers_name_tests() {
        let sources = [
            ("tests", include_str!("lib.rs")),
            ("nft::tests", include_str!("nft.rs")),
            ("route::tests", include_str!("route.rs")),
            ("kernel_tests", include_str!("kernel_tests.rs")),
        ];
        let mut markers = 0;
        for (_, text) in sources {
            for path in text.lines().filter_map(|l| l.trim().strip_prefix("/// @witness ")) {
                markers += 1;
                let (module, name) = path.rsplit_once("::")
                    .unwrap_or_else(|| panic!("@witness {path}: no module"));
                let (_, file) = sources.iter().find(|(m, _)| *m == module)
                    .unwrap_or_else(|| panic!("@witness {path}: unknown module {module}"));
                let lines: Vec<&str> = file.lines().map(str::trim).collect();
                let test = format!("fn {name}() {{");
                assert!(lines.windows(2).any(|w| w[0] == "#[test]" && w[1] == test),
                        "@witness {path} names no test");
            }
        }
        assert!(markers >= MARKERS_AT_LEAST, "only {markers} markers found");
    }

    /// The markers counted when this check was written; fewer means the
    /// check stopped seeing them.
    const MARKERS_AT_LEAST: usize = 132;

    #[test]
    fn version_is_the_crate_version_at_one_address() {
        let p = firewall_bridge_get_version();
        assert_eq!(p, firewall_bridge_get_version());
        // SAFETY: the pointer is a static NUL-terminated string.
        let v = unsafe { CStr::from_ptr(p) }.to_str().unwrap();
        assert_eq!(v, env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn last_error_copy_roundtrip_truncation_and_guards() {
        let _serial = test_support::serial();
        set_last_error("boundary test message");

        // Full copy
        let mut buf = [0 as c_char; 64];
        // SAFETY: `buf` holds the length passed.
        let n = unsafe { firewall_bridge_get_last_error_copy(buf.as_mut_ptr(), 64) };
        assert_eq!(n as usize, "boundary test message".len());
        // SAFETY: the copy NUL-terminated `buf`.
        let msg = unsafe { CStr::from_ptr(buf.as_ptr()) }.to_str().unwrap();
        assert_eq!(msg, "boundary test message");

        // Truncation: len-1 bytes + NUL, never past the buffer
        let mut small = [0x7f as c_char; 9];
        // SAFETY: `small` holds 9 bytes, more than the 8 passed.
        let n = unsafe { firewall_bridge_get_last_error_copy(small.as_mut_ptr(), 8) };
        assert_eq!(n, 7);
        // SAFETY: the copy NUL-terminated `small`.
        let msg = unsafe { CStr::from_ptr(small.as_ptr()) }.to_str().unwrap();
        assert_eq!(msg, "boundar");
        assert_eq!(small[8], 0x7f as c_char, "wrote past len");

        // A len of 1 holds the NUL alone: 0 copied although an error is recorded.
        let mut one = [0x7f as c_char; 2];
        // SAFETY: `one` holds 2 bytes, more than the 1 passed.
        assert_eq!(unsafe { firewall_bridge_get_last_error_copy(one.as_mut_ptr(), 1) }, 0);
        assert_eq!(one, [0, 0x7f as c_char]);

        // Guards
        assert_eq!(
            // SAFETY: a null buffer is allowed and refused.
            unsafe { firewall_bridge_get_last_error_copy(ptr::null_mut(), 64) },
            ErrorCode::InvalidParam as i32
        );
        assert_eq!(
            // SAFETY: a zero length writes nothing.
            unsafe { firewall_bridge_get_last_error_copy(buf.as_mut_ptr(), 0) },
            ErrorCode::InvalidParam as i32
        );
    }
}
