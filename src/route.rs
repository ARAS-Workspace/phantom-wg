//! Policy rules and routes over a NETLINK_ROUTE socket, and the table names
//! in /etc/iproute2/rt_tables.d/phantom.conf.

use std::io;
use std::mem;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::path::Path;
use std::str::FromStr;

use crate::error::ErrorCode;

// ---------------------------------------------------------------------------
// Netlink constants (from linux/netlink.h, linux/rtnetlink.h)
// ---------------------------------------------------------------------------

const NETLINK_ROUTE: libc::c_int = 0;

// Message types
const RTM_NEWROUTE: u16 = 24;
const RTM_DELROUTE: u16 = 25;
const RTM_NEWRULE: u16 = 32;
const RTM_DELRULE: u16 = 33;

// Flags
const NLM_F_REQUEST: u16 = 0x0001;
const NLM_F_ACK: u16 = 0x0004;
const NLM_F_CREATE: u16 = 0x0400;
const NLM_F_EXCL: u16 = 0x0200;

// Route/Rule attribute types
const RTA_DST: u16 = 1;
const RTA_OIF: u16 = 4;
const RTA_TABLE: u16 = 15;
const FRA_SRC: u16 = 2;
const FRA_DST: u16 = 1;
const FRA_TABLE: u16 = 15;
const FRA_PRIORITY: u16 = 6;

// Route types
const RTN_UNSPEC: u8 = 0;
const RTN_UNICAST: u8 = 1;

// Route protocols
const RTPROT_UNSPEC: u8 = 0;
const RTPROT_STATIC: u8 = 4;

// Route scope
const RT_SCOPE_LINK: u8 = 253;
const RT_SCOPE_NOWHERE: u8 = 255;

// FIB rule action
const FR_ACT_TO_TBL: u8 = 1;

// ---------------------------------------------------------------------------
// Netlink message structures
// ---------------------------------------------------------------------------

#[repr(C)]
struct NlMsgHdr {
    nlmsg_len: u32,
    nlmsg_type: u16,
    nlmsg_flags: u16,
    nlmsg_seq: u32,
    nlmsg_pid: u32,
}

#[repr(C)]
struct RtMsg {
    rtm_family: u8,
    rtm_dst_len: u8,
    rtm_src_len: u8,
    rtm_tos: u8,
    rtm_table: u8,
    rtm_protocol: u8,
    rtm_scope: u8,
    rtm_type: u8,
    rtm_flags: u32,
}

#[repr(C)]
struct FibRuleHdr {
    family: u8,
    dst_len: u8,
    src_len: u8,
    tos: u8,
    table: u8,
    res1: u8,
    res2: u8,
    action: u8,
    flags: u32,
}

#[repr(C)]
struct RtAttr {
    rta_len: u16,
    rta_type: u16,
}

const _: () = assert!(mem::size_of::<NlMsgHdr>() == 16);
const _: () = assert!(mem::size_of::<RtMsg>() == 12);
const _: () = assert!(mem::size_of::<FibRuleHdr>() == 12);
const _: () = assert!(mem::size_of::<RtAttr>() == 4);

impl NlMsgHdr {
    fn to_bytes(&self) -> [u8; 16] {
        let mut b = [0u8; 16];
        b[0..4].copy_from_slice(&self.nlmsg_len.to_ne_bytes());
        b[4..6].copy_from_slice(&self.nlmsg_type.to_ne_bytes());
        b[6..8].copy_from_slice(&self.nlmsg_flags.to_ne_bytes());
        b[8..12].copy_from_slice(&self.nlmsg_seq.to_ne_bytes());
        b[12..16].copy_from_slice(&self.nlmsg_pid.to_ne_bytes());
        b
    }
}

impl RtMsg {
    fn to_bytes(&self) -> [u8; 12] {
        let mut b = [0u8; 12];
        b[..8].copy_from_slice(&[self.rtm_family, self.rtm_dst_len, self.rtm_src_len,
                                 self.rtm_tos, self.rtm_table, self.rtm_protocol,
                                 self.rtm_scope, self.rtm_type]);
        b[8..].copy_from_slice(&self.rtm_flags.to_ne_bytes());
        b
    }
}

impl FibRuleHdr {
    fn to_bytes(&self) -> [u8; 12] {
        let mut b = [0u8; 12];
        b[..8].copy_from_slice(&[self.family, self.dst_len, self.src_len, self.tos,
                                 self.table, self.res1, self.res2, self.action]);
        b[8..].copy_from_slice(&self.flags.to_ne_bytes());
        b
    }
}

// ---------------------------------------------------------------------------
// Netlink socket helper
// ---------------------------------------------------------------------------

struct NetlinkSocket {
    fd: i32,
    seq: u32,
}

impl NetlinkSocket {
    fn open() -> Result<Self, ErrorCode> {
        // SAFETY: a plain syscall with constant arguments; the result is checked.
        let fd = unsafe {
            libc::socket(
                libc::AF_NETLINK,
                libc::SOCK_RAW | libc::SOCK_CLOEXEC,
                NETLINK_ROUTE,
            )
        };
        if fd < 0 {
            return Err(if io::Error::last_os_error().raw_os_error() == Some(libc::EPERM) {
                ErrorCode::PermissionDenied
            } else {
                ErrorCode::NetlinkFailed
            });
        }

        // Bind to kernel
        // SAFETY: sockaddr_nl holds only integers, for which all zeros is valid.
        let mut addr: libc::sockaddr_nl = unsafe { mem::zeroed() };
        addr.nl_family = libc::AF_NETLINK as u16;
        addr.nl_pid = 0; // let kernel assign

        // SAFETY: `addr` outlives the call and the length passed is its size.
        let rc = unsafe {
            libc::bind(
                fd,
                &addr as *const libc::sockaddr_nl as *const libc::sockaddr,
                mem::size_of::<libc::sockaddr_nl>() as u32,
            )
        };
        if rc < 0 {
            // SAFETY: `fd` is the socket opened above and is not used again.
            unsafe { libc::close(fd) };
            return Err(ErrorCode::NetlinkFailed);
        }

        Ok(Self { fd, seq: 1 })
    }

    fn next_seq(&mut self) -> u32 {
        let s = self.seq;
        self.seq += 1;
        s
    }

    /// Send a netlink message and wait for ACK.
    ///
    /// @witness kernel_tests::kernel_routing_tables_rules_and_routes
    fn send_and_ack(&mut self, buf: &[u8]) -> Result<(), String> {
        // SAFETY: the pointer and length describe `buf`, which outlives the call.
        let sent = unsafe {
            libc::send(self.fd, buf.as_ptr() as *const libc::c_void, buf.len(), 0)
        };
        if sent < 0 {
            return Err(format!("netlink send failed: {}", io::Error::last_os_error()));
        }

        // Read ACK
        let mut recv_buf = [0u8; 4096];
        // SAFETY: the pointer and length describe `recv_buf`, which outlives the call.
        let len = unsafe {
            libc::recv(self.fd, recv_buf.as_mut_ptr() as *mut libc::c_void, recv_buf.len(), 0)
        };
        if len < 0 {
            return Err(format!("netlink recv failed: {}", io::Error::last_os_error()));
        }

        check_ack(&recv_buf[..len as usize])
    }
}

/// The kernel's answer to a request sent with NLM_F_ACK.
///
/// @witness route::tests::ack_with_code_zero_is_accepted
/// @witness route::tests::ack_with_an_errno_is_an_error
/// @witness route::tests::ack_that_is_short_or_not_an_error_is_accepted
/// @witness kernel_tests::kernel_routing_tables_rules_and_routes
fn check_ack(reply: &[u8]) -> Result<(), String> {
    let hdr_len = mem::size_of::<NlMsgHdr>();
    // nlmsghdr: len u32 at 0, type u16 at 4.
    let Some(&[t0, t1]) = reply.get(4..6) else { return Ok(()) };
    if reply.len() < hdr_len || u16::from_ne_bytes([t0, t1]) != libc::NLMSG_ERROR as u16 {
        return Ok(());
    }
    let Some(&[e0, e1, e2, e3]) = reply.get(hdr_len..hdr_len + 4) else { return Ok(()) };
    match i32::from_ne_bytes([e0, e1, e2, e3]) {
        0 => Ok(()),
        err => Err(format!("netlink error: {}", io::Error::from_raw_os_error(-err))),
    }
}

impl Drop for NetlinkSocket {
    fn drop(&mut self) {
        if self.fd >= 0 {
            // SAFETY: `fd` belongs to this socket and is closed once; it is set to -1 next.
            unsafe { libc::close(self.fd) };
            self.fd = -1;
        }
    }
}

// ---------------------------------------------------------------------------
// Message builder helpers
// ---------------------------------------------------------------------------

/// @witness route::tests::attributes_pad_to_four_bytes
fn align4(len: usize) -> usize {
    (len + 3) & !3
}

/// @witness route::tests::attributes_pad_to_four_bytes
fn push_attr(buf: &mut Vec<u8>, rta_type: u16, data: &[u8]) {
    let rta_len = (mem::size_of::<RtAttr>() + data.len()) as u16;
    buf.extend_from_slice(&rta_len.to_ne_bytes());
    buf.extend_from_slice(&rta_type.to_ne_bytes());
    buf.extend_from_slice(data);
    // Pad to 4-byte alignment
    let padded = align4(rta_len as usize);
    for _ in 0..(padded - rta_len as usize) {
        buf.push(0);
    }
}

fn push_attr_u32(buf: &mut Vec<u8>, rta_type: u16, val: u32) {
    push_attr(buf, rta_type, &val.to_ne_bytes());
}

/// Parse "10.66.66.0/24" or "fd00:d0ce::/64" into (IpAddr, prefix_len, family).
///
/// @witness route::tests::parse_ipv4_network
/// @witness route::tests::parse_ipv6_network
/// @witness route::tests::parse_ipv6_full
/// @witness route::tests::parse_ipv4_host
/// @witness route::tests::parse_invalid_no_prefix
/// @witness route::tests::parse_invalid_addr
fn parse_network(network: &str) -> Result<(IpAddr, u8, u8), String> {
    let parts: Vec<&str> = network.split('/').collect();
    if parts.len() != 2 {
        return Err(format!("Invalid network format: {}", network));
    }
    let addr = IpAddr::from_str(parts[0])
        .map_err(|e| format!("Invalid IP address: {}", e))?;
    let prefix: u8 = parts[1].parse()
        .map_err(|e| format!("Invalid prefix length: {}", e))?;
    let family = match addr {
        IpAddr::V4(_) => libc::AF_INET as u8,
        IpAddr::V6(_) => libc::AF_INET6 as u8,
    };
    Ok((addr, prefix, family))
}

/// Get raw address bytes (4 for IPv4, 16 for IPv6).
///
/// @witness route::tests::addr_bytes_ipv4
/// @witness route::tests::addr_bytes_ipv6
/// @witness route::tests::addr_bytes_ipv6_unspecified
fn addr_bytes(addr: &IpAddr) -> Vec<u8> {
    match addr {
        IpAddr::V4(v4) => v4.octets().to_vec(),
        IpAddr::V6(v6) => v6.octets().to_vec(),
    }
}

/// Resolve interface name to ifindex.
///
/// @witness kernel_tests::kernel_routing_tables_rules_and_routes
fn if_nametoindex(name: &str) -> Result<u32, String> {
    let c_name = std::ffi::CString::new(name).map_err(|e| e.to_string())?;
    // SAFETY: `c_name` is a NUL-terminated string that outlives the call.
    let idx = unsafe { libc::if_nametoindex(c_name.as_ptr()) };
    if idx == 0 {
        Err(format!("Interface not found: {}", name))
    } else {
        Ok(idx)
    }
}

/// Resolve a routing table name to its id, from the files `ip` reads.
///
/// @witness kernel_tests::kernel_routing_tables_rules_and_routes
fn resolve_table(table_name: &str) -> Result<u32, String> {
    resolve_table_in(Path::new(IPROUTE2_ETC), Path::new(IPROUTE2_USR), table_name)
}

/// Built-in names and numbers first; then the name among the entries of
/// `table_files(etc, usr)`, where the entry with the lowest `id % 256`
/// wins and, within that, the one read last.
///
/// @witness route::tests::resolve_table_builtins_and_numbers_need_no_file
/// @witness route::tests::resolve_table_reads_the_files_ip_reads
/// @witness route::tests::resolve_table_picks_the_entry_ip_picks
/// @witness route::tests::resolve_table_reports_a_bad_id_and_a_missing_name
fn resolve_table_in(etc: &Path, usr: &Path, table_name: &str) -> Result<u32, String> {
    match table_name {
        "default" => return Ok(253),
        "main" => return Ok(254),
        "local" => return Ok(255),
        "unspec" => return Ok(0),
        _ => {}
    }
    if let Ok(n) = table_name.parse::<u32>() {
        return Ok(n);
    }

    let mut found: Option<u32> = None;
    for file in table_files(etc, usr) {
        let Ok(content) = std::fs::read_to_string(&file) else { continue };
        for (id, name) in table_entries(&content) {
            if name != table_name {
                continue;
            }
            let id = id.parse::<u32>()
                .map_err(|e| format!("Invalid table ID in {}: {}", file.display(), e))?;
            if found.is_none_or(|f| id % 256 <= f % 256) {
                found = Some(id);
            }
        }
    }
    found.ok_or_else(|| format!("Routing table not found: {}", table_name))
}

/// The files `ip` reads table names from, in the order it reads them:
/// `etc/rt_tables`, or `usr/rt_tables` when that is missing; then each
/// `usr/rt_tables.d/*.conf` with no namesake in `etc/rt_tables.d`; then
/// each `etc/rt_tables.d/*.conf`. Directory entries are taken in name order.
///
/// @witness route::tests::resolve_table_reads_the_files_ip_reads
fn table_files(etc: &Path, usr: &Path) -> Vec<std::path::PathBuf> {
    fn confs(dir: &Path) -> Vec<std::path::PathBuf> {
        let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
        let mut files: Vec<_> = entries.flatten()
            .map(|e| e.path())
            .filter(|p| p.file_name().and_then(|n| n.to_str())
                .is_some_and(|n| !n.starts_with('.') && n.len() > 5 && n.ends_with(".conf")))
            .collect();
        files.sort();
        files
    }
    let main = etc.join("rt_tables");
    let mut files = vec![if main.exists() { main } else { usr.join("rt_tables") }];
    let etc_d = etc.join("rt_tables.d");
    files.extend(confs(&usr.join("rt_tables.d")).into_iter()
        .filter(|p| p.file_name().is_none_or(|n| !etc_d.join(n).exists())));
    files.extend(confs(&etc_d));
    files
}

/// The `<id> <name>` pairs of an rt_tables file, comments and blank lines
/// skipped.
fn table_entries(content: &str) -> impl Iterator<Item = (&str, &str)> {
    content.lines().filter_map(|line| {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            return None;
        }
        let mut parts = line.split_whitespace();
        Some((parts.next()?, parts.next()?))
    })
}

// ---------------------------------------------------------------------------
// Netlink requests
// ---------------------------------------------------------------------------

/// What the netlink header carries besides the length.
#[derive(Clone, Copy)]
struct Request {
    kind: u16,
    flags: u16,
    seq: u32,
}

const CREATE_FLAGS: u16 = NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_EXCL;
const DELETE_FLAGS: u16 = NLM_F_REQUEST | NLM_F_ACK;

/// Fill the header reserved at the start of `buf` once the length is known.
fn write_header(buf: &mut [u8], req: Request) {
    let hdr = NlMsgHdr {
        nlmsg_len: buf.len() as u32,
        nlmsg_type: req.kind,
        nlmsg_flags: req.flags,
        nlmsg_seq: req.seq,
        nlmsg_pid: 0,
    };
    buf[..mem::size_of::<NlMsgHdr>()].copy_from_slice(&hdr.to_bytes());
}

/// RTM_NEWRULE / RTM_DELRULE: from <from> [to <to>] table <table> priority <prio>.
///
/// @witness route::tests::policy_message_v4_from_only
/// @witness route::tests::policy_message_v4_from_and_to_delete
/// @witness route::tests::policy_message_v6_table_above_255
/// @witness route::tests::policy_messages_refuse_an_address_of_another_family
/// @witness route::tests::messages_refuse_a_malformed_network
fn policy_msg(req: Request, from_network: &str, to_network: &str, table_id: u32,
              priority: u32, family: u8) -> Result<Vec<u8>, String> {
    known_family(family)?;
    let (from_addr, from_prefix, from_family) = parse_network(from_network)?;
    check_family(from_network, from_family, family)?;

    let mut buf = Vec::with_capacity(256);
    buf.extend_from_slice(&[0u8; mem::size_of::<NlMsgHdr>()]);

    let fib = FibRuleHdr {
        family,
        dst_len: 0,
        src_len: from_prefix,
        tos: 0,
        table: if table_id <= 255 { table_id as u8 } else { 0 },
        res1: 0,
        res2: 0,
        action: FR_ACT_TO_TBL,
        flags: 0,
    };
    buf.extend_from_slice(&fib.to_bytes());

    push_attr(&mut buf, FRA_SRC, &addr_bytes(&from_addr));

    if !to_network.is_empty() {
        let (to_addr, to_prefix, to_family) = parse_network(to_network)?;
        check_family(to_network, to_family, family)?;
        push_attr(&mut buf, FRA_DST, &addr_bytes(&to_addr));
        let dst_len_offset = mem::size_of::<NlMsgHdr>() + 1;
        buf[dst_len_offset] = to_prefix;
    }

    if table_id > 255 {
        push_attr_u32(&mut buf, FRA_TABLE, table_id);
    }

    push_attr_u32(&mut buf, FRA_PRIORITY, priority);

    write_header(&mut buf, req);
    Ok(buf)
}

/// RTM_NEWROUTE / RTM_DELROUTE: <destination> dev <ifindex> table <table>;
/// "default" is the default route of `family`. A new route has link scope,
/// a delete RT_SCOPE_NOWHERE.
///
/// @witness route::tests::route_message_v4_link_scope
/// @witness route::tests::route_message_v4_delete_has_no_scope
/// @witness route::tests::route_message_v6_default_delete
/// @witness kernel_tests::kernel_route_delete_takes_a_route_of_any_scope
/// @witness route::tests::route_message_v4_default_table_above_255
/// @witness route::tests::route_messages_refuse_an_address_of_another_family
/// @witness route::tests::messages_refuse_a_malformed_network
fn route_msg(req: Request, destination: &str, ifindex: u32, table_id: u32, family: u8)
    -> Result<Vec<u8>, String>
{
    known_family(family)?;
    let (dst_addr, dst_prefix) = if destination == "default" {
        if family == libc::AF_INET6 as u8 {
            (IpAddr::V6(Ipv6Addr::UNSPECIFIED), 0u8)
        } else {
            (IpAddr::V4(Ipv4Addr::new(0, 0, 0, 0)), 0u8)
        }
    } else {
        let (addr, prefix, dst_family) = parse_network(destination)?;
        check_family(destination, dst_family, family)?;
        (addr, prefix)
    };

    let any_device = req.kind == RTM_DELROUTE && ifindex == 0;
    let mut buf = Vec::with_capacity(256);
    buf.extend_from_slice(&[0u8; mem::size_of::<NlMsgHdr>()]);

    let rtm = RtMsg {
        rtm_family: family,
        rtm_dst_len: dst_prefix,
        rtm_src_len: 0,
        rtm_tos: 0,
        rtm_table: if table_id <= 255 { table_id as u8 } else { 0 },
        rtm_protocol: if any_device { RTPROT_UNSPEC } else { RTPROT_STATIC },
        rtm_scope: if req.kind == RTM_DELROUTE { RT_SCOPE_NOWHERE } else { RT_SCOPE_LINK },
        rtm_type: if any_device { RTN_UNSPEC } else { RTN_UNICAST },
        rtm_flags: 0,
    };
    buf.extend_from_slice(&rtm.to_bytes());

    if dst_prefix > 0 {
        push_attr(&mut buf, RTA_DST, &addr_bytes(&dst_addr));
    }

    if !any_device {
        push_attr_u32(&mut buf, RTA_OIF, ifindex);
    }

    if table_id > 255 {
        push_attr_u32(&mut buf, RTA_TABLE, table_id);
    }

    write_header(&mut buf, req);
    Ok(buf)
}

/// @witness route::tests::policy_messages_refuse_an_address_of_another_family
/// @witness route::tests::route_messages_refuse_an_address_of_another_family
fn known_family(family: u8) -> Result<(), String> {
    if family == libc::AF_INET as u8 || family == libc::AF_INET6 as u8 {
        Ok(())
    } else {
        Err(format!("Unknown address family: {family}"))
    }
}

/// @witness route::tests::policy_messages_refuse_an_address_of_another_family
/// @witness route::tests::route_messages_refuse_an_address_of_another_family
fn check_family(network: &str, network_family: u8, family: u8) -> Result<(), String> {
    if network_family == family {
        Ok(())
    } else {
        Err(format!("Address family {family} does not match {network}"))
    }
}

fn send_policy(kind: u16, flags: u16, from_network: &str, to_network: &str,
               table_name: &str, priority: u32, family: u8) -> Result<(), String> {
    let mut sock = NetlinkSocket::open().map_err(|e| e.to_string())?;
    let req = Request { kind, flags, seq: sock.next_seq() };
    let table_id = resolve_table(table_name)?;
    let msg = policy_msg(req, from_network, to_network, table_id, priority, family)?;
    sock.send_and_ack(&msg)
}

fn send_route(kind: u16, flags: u16, destination: &str, device: &str, table_name: &str,
              family: u8) -> Result<(), String> {
    let mut sock = NetlinkSocket::open().map_err(|e| e.to_string())?;
    let req = Request { kind, flags, seq: sock.next_seq() };
    let table_id = resolve_table(table_name)?;
    let ifindex = if kind == RTM_DELROUTE && device.is_empty() { 0 } else { if_nametoindex(device)? };
    let msg = route_msg(req, destination, ifindex, table_id, family)?;
    sock.send_and_ack(&msg)
}

// ---------------------------------------------------------------------------
// Public routing operations
// ---------------------------------------------------------------------------

/// Add a policy rule: ip rule add from <from> [to <to>] table <table> priority <prio>
///
/// @witness kernel_tests::kernel_routing_tables_rules_and_routes
pub fn policy_add(from_network: &str, to_network: &str, table_name: &str, priority: u32, family: u8) -> Result<(), String> {
    send_policy(RTM_NEWRULE, CREATE_FLAGS, from_network, to_network, table_name, priority, family)
}

/// Delete a policy rule.
///
/// @witness kernel_tests::kernel_routing_tables_rules_and_routes
pub fn policy_delete(from_network: &str, to_network: &str, table_name: &str, priority: u32, family: u8) -> Result<(), String> {
    send_policy(RTM_DELRULE, DELETE_FLAGS, from_network, to_network, table_name, priority, family)
}

/// Add a route: ip route add <destination> dev <device> table <table>;
/// "default" is the default route of `family`.
///
/// @witness kernel_tests::kernel_routing_tables_rules_and_routes
pub fn route_add(destination: &str, device: &str, table_name: &str, family: u8) -> Result<(), String> {
    send_route(RTM_NEWROUTE, CREATE_FLAGS, destination, device, table_name, family)
}

/// Delete a route. With an empty `device`, the route of `destination` in
/// the table, whatever its device, protocol and type.
///
/// @witness kernel_tests::kernel_routing_tables_rules_and_routes
/// @witness route::tests::route_message_v4_delete_of_any_device
/// @witness kernel_tests::kernel_route_delete_with_no_device_takes_any_route
pub fn route_delete(destination: &str, device: &str, table_name: &str, family: u8) -> Result<(), String> {
    send_route(RTM_DELROUTE, DELETE_FLAGS, destination, device, table_name, family)
}

/// Where `ip` looks for table names first.
///
/// @witness kernel_tests::kernel_routing_tables_rules_and_routes
const IPROUTE2_ETC: &str = "/etc/iproute2";

/// Where `ip` looks when `IPROUTE2_ETC` has no rt_tables.
const IPROUTE2_USR: &str = "/usr/share/iproute2";

/// The bridge's own file of table names, under `IPROUTE2_ETC`.
///
/// @witness kernel_tests::kernel_routing_tables_rules_and_routes
const DROP_IN: &str = "rt_tables.d/phantom.conf";

/// The longest `<id> <name>` line written to `DROP_IN`.
///
/// @witness kernel_tests::kernel_rt_tables_line_limit_matches_ip
const MAX_RT_TABLES_LINE: usize = 511;

/// Name table `table_id` `table_name` in `DROP_IN`.
///
/// @witness kernel_tests::kernel_routing_tables_rules_and_routes
/// @witness kernel_tests::kernel_rt_tables_line_limit_matches_ip
pub fn ensure_table(table_id: u32, table_name: &str) -> Result<(), String> {
    ensure_table_in(&Path::new(IPROUTE2_ETC).join(DROP_IN), table_id, table_name)
}

/// Writes `<table_id> <table_name>` to `path`, in place of any line there
/// with the same id or the same name. A file that holds the entry and no
/// such line is not written.
///
/// @witness route::tests::ensure_table_creates_the_file_and_its_directory
/// @witness route::tests::ensure_table_writes_an_entry_once
/// @witness route::tests::ensure_table_replaces_the_same_id_or_name
/// @witness route::tests::ensure_table_refuses_an_empty_spaced_or_numeric_name
/// @witness route::tests::ensure_table_refuses_an_entry_longer_than_iproute2_reads
fn ensure_table_in(path: &Path, table_id: u32, table_name: &str) -> Result<(), String> {
    if table_name.is_empty() || table_name.chars().any(char::is_whitespace)
        || table_name.bytes().all(|b| b.is_ascii_digit()) {
        return Err(format!("Invalid routing table name: {table_name:?}"));
    }
    let entry = format!("{} {}", table_id, table_name);
    if entry.len() > MAX_RT_TABLES_LINE {
        return Err(format!("Routing table entry longer than {MAX_RT_TABLES_LINE} characters"));
    }

    let content = match std::fs::read_to_string(path) {
        Ok(content) => content,
        Err(e) if e.kind() == io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(format!("Cannot read {}: {}", path.display(), e)),
    };
    let id = table_id.to_string();
    let other = |line: &str| match table_entries(line).next() {
        Some((i, n)) => i != id && n != table_name,
        None => true,
    };
    let (kept, matching): (Vec<&str>, Vec<&str>) = content.lines().partition(|l| other(l));
    if matching == [entry.as_str()] {
        return Ok(());
    }

    let mut written: String = kept.into_iter().map(|l| format!("{l}\n")).collect();
    written.push_str(&entry);
    written.push('\n');

    let dir = path.parent().unwrap_or(Path::new("."));
    std::fs::create_dir_all(dir)
        .map_err(|e| format!("Cannot create {}: {}", dir.display(), e))?;
    let temp = dir.join(".phantom.conf.tmp");
    std::fs::write(&temp, written)
        .and_then(|()| std::fs::rename(&temp, path))
        .map_err(|e| format!("Cannot write {}: {}", path.display(), e))
}

/// Flush the IPv4 route cache through /proc.
///
/// @witness kernel_tests::kernel_forwarding_and_route_cache
pub fn flush_cache() -> Result<(), String> {
    let _ = std::fs::write("/proc/sys/net/ipv4/route/flush", "1");
    Ok(())
}

/// Enable IP forwarding.
///
/// @witness kernel_tests::kernel_forwarding_and_route_cache
pub fn enable_ip_forward() -> Result<(), String> {
    std::fs::write("/proc/sys/net/ipv4/ip_forward", "1")
        .map_err(|e| format!("Cannot enable ip_forward: {}", e))
}

#[cfg(test)]
mod tests {
    //! Message bytes, reply parsing and the rt_tables file, without a socket.
    //! Whether the kernel takes the messages is kernel_tests' part.

    use super::*;

    // ── parse_network ────────────────────────────────────────────

    #[test]
    fn parse_ipv4_network() {
        let (addr, prefix, family) = parse_network("10.0.0.0/24").unwrap();
        assert_eq!(addr, IpAddr::V4(Ipv4Addr::new(10, 0, 0, 0)));
        assert_eq!(prefix, 24);
        assert_eq!(family, libc::AF_INET as u8);
    }

    #[test]
    fn parse_ipv6_network() {
        let (addr, prefix, family) = parse_network("fd00:70:68::/120").unwrap();
        assert!(addr.is_ipv6());
        assert_eq!(prefix, 120);
        assert_eq!(family, libc::AF_INET6 as u8);
    }

    #[test]
    fn parse_ipv6_full() {
        let (addr, prefix, family) = parse_network("2a03:b0c0:3:f0::2:309c:d000/128").unwrap();
        assert!(addr.is_ipv6());
        assert_eq!(prefix, 128);
        assert_eq!(family, libc::AF_INET6 as u8);
    }

    #[test]
    fn parse_ipv4_host() {
        let (addr, prefix, family) = parse_network("192.168.1.1/32").unwrap();
        assert_eq!(addr, IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1)));
        assert_eq!(prefix, 32);
        assert_eq!(family, libc::AF_INET as u8);
    }

    #[test]
    fn parse_invalid_no_prefix() {
        assert!(parse_network("10.0.0.0").is_err());
    }

    #[test]
    fn parse_invalid_addr() {
        assert!(parse_network("not-an-ip/24").is_err());
    }

    // ── addr_bytes ───────────────────────────────────────────────

    #[test]
    fn addr_bytes_ipv4() {
        let addr = IpAddr::V4(Ipv4Addr::new(10, 8, 0, 1));
        let bytes = addr_bytes(&addr);
        assert_eq!(bytes.len(), 4);
        assert_eq!(bytes, vec![10, 8, 0, 1]);
    }

    #[test]
    fn addr_bytes_ipv6() {
        let addr = IpAddr::V6(Ipv6Addr::LOCALHOST);
        let bytes = addr_bytes(&addr);
        assert_eq!(bytes.len(), 16);
        assert_eq!(bytes[15], 1); // ::1
    }

    #[test]
    fn addr_bytes_ipv6_unspecified() {
        let addr = IpAddr::V6(Ipv6Addr::UNSPECIFIED);
        let bytes = addr_bytes(&addr);
        assert_eq!(bytes.len(), 16);
        assert!(bytes.iter().all(|&b| b == 0));
    }

    // ── netlink messages ─────────────────────────────────────────
    //
    // Expected bytes are spelled out from the kernel's layouts and numbers
    // (linux/netlink.h, rtnetlink.h, fib_rules.h), not from this module's
    // constants. Netlink fields are in host byte order.

    fn cat(parts: &[&[u8]]) -> Vec<u8> {
        parts.concat()
    }

    /// nlmsghdr: len, type, flags, seq, pid.
    fn nlhdr(len: u32, kind: u16, flags: u16, seq: u32) -> Vec<u8> {
        cat(&[&len.to_ne_bytes(), &kind.to_ne_bytes(), &flags.to_ne_bytes(),
              &seq.to_ne_bytes(), &0u32.to_ne_bytes()])
    }

    /// rtattr: len, type, data, zero padding to 4 bytes.
    fn attr(kind: u16, data: &[u8]) -> Vec<u8> {
        let len = 4 + data.len();
        let mut out = cat(&[&(len as u16).to_ne_bytes(), &kind.to_ne_bytes(), data]);
        out.resize(len.div_ceil(4) * 4, 0);
        out
    }

    const REQUEST_ACK_CREATE_EXCL: u16 = 0x0001 | 0x0004 | 0x0400 | 0x0200;
    const REQUEST_ACK: u16 = 0x0001 | 0x0004;

    #[test]
    fn policy_message_v4_from_only() {
        let req = Request { kind: RTM_NEWRULE, flags: CREATE_FLAGS, seq: 7 };
        let msg = policy_msg(req, "10.0.1.0/24", "", 100, 1000, 2).unwrap();
        let body = cat(&[
            // fib_rule_hdr: family dst_len src_len tos table res1 res2 action, flags
            &[2, 0, 24, 0, 100, 0, 0, 1], &0u32.to_ne_bytes(),
            &attr(2, &[10, 0, 1, 0]),                    // FRA_SRC
            &attr(6, &1000u32.to_ne_bytes()),            // FRA_PRIORITY
        ]);
        assert_eq!(msg, cat(&[&nlhdr(16 + body.len() as u32, 32, REQUEST_ACK_CREATE_EXCL, 7), &body]));
    }

    #[test]
    fn policy_message_v4_from_and_to_delete() {
        let req = Request { kind: RTM_DELRULE, flags: DELETE_FLAGS, seq: 1 };
        let msg = policy_msg(req, "10.0.1.0/24", "10.0.2.0/23", 254, 99, 2).unwrap();
        let body = cat(&[
            &[2, 23, 24, 0, 254, 0, 0, 1], &0u32.to_ne_bytes(),
            &attr(2, &[10, 0, 1, 0]),                    // FRA_SRC
            &attr(1, &[10, 0, 2, 0]),                    // FRA_DST
            &attr(6, &99u32.to_ne_bytes()),              // FRA_PRIORITY
        ]);
        assert_eq!(msg, cat(&[&nlhdr(16 + body.len() as u32, 33, REQUEST_ACK, 1), &body]));
    }

    #[test]
    fn policy_message_v6_table_above_255() {
        let req = Request { kind: RTM_NEWRULE, flags: CREATE_FLAGS, seq: 3 };
        let msg = policy_msg(req, "fd00:70:68::/120", "", 1000, 100, 10).unwrap();
        let src = Ipv6Addr::from_str("fd00:70:68::").unwrap().octets();
        let body = cat(&[
            // A table id above 255 goes in FRA_TABLE; the header's byte is 0.
            &[10, 0, 120, 0, 0, 0, 0, 1], &0u32.to_ne_bytes(),
            &attr(2, &src),                              // FRA_SRC
            &attr(15, &1000u32.to_ne_bytes()),           // FRA_TABLE
            &attr(6, &100u32.to_ne_bytes()),             // FRA_PRIORITY
        ]);
        assert_eq!(msg, cat(&[&nlhdr(16 + body.len() as u32, 32, REQUEST_ACK_CREATE_EXCL, 3), &body]));
    }

    #[test]
    fn route_message_v4_link_scope() {
        let req = Request { kind: RTM_NEWROUTE, flags: CREATE_FLAGS, seq: 5 };
        let msg = route_msg(req, "10.98.0.0/16", 3, 100, 2).unwrap();
        let body = cat(&[
            // rtmsg: family dst_len src_len tos table protocol scope type, flags
            &[2, 16, 0, 0, 100, 4, 253, 1], &0u32.to_ne_bytes(),
            &attr(1, &[10, 98, 0, 0]),                   // RTA_DST
            &attr(4, &3u32.to_ne_bytes()),               // RTA_OIF
        ]);
        assert_eq!(msg, cat(&[&nlhdr(16 + body.len() as u32, 24, REQUEST_ACK_CREATE_EXCL, 5), &body]));
    }

    #[test]
    fn route_message_v4_delete_has_no_scope() {
        let req = Request { kind: RTM_DELROUTE, flags: DELETE_FLAGS, seq: 6 };
        let msg = route_msg(req, "10.98.0.0/16", 3, 100, 2).unwrap();
        let body = cat(&[
            &[2, 16, 0, 0, 100, 4, 255, 1], &0u32.to_ne_bytes(),
            &attr(1, &[10, 98, 0, 0]),                   // RTA_DST
            &attr(4, &3u32.to_ne_bytes()),               // RTA_OIF
        ]);
        assert_eq!(msg, cat(&[&nlhdr(16 + body.len() as u32, 25, REQUEST_ACK, 6), &body]));
    }

    #[test]
    fn route_message_v4_delete_of_any_device() {
        let req = Request { kind: RTM_DELROUTE, flags: DELETE_FLAGS, seq: 7 };
        let msg = route_msg(req, "10.98.0.0/16", 0, 100, 2).unwrap();
        let body = cat(&[
            // No protocol, no type and no RTA_OIF.
            &[2, 16, 0, 0, 100, 0, 255, 0], &0u32.to_ne_bytes(),
            &attr(1, &[10, 98, 0, 0]),                   // RTA_DST
        ]);
        assert_eq!(msg, cat(&[&nlhdr(16 + body.len() as u32, 25, REQUEST_ACK, 7), &body]));

        let req = Request { kind: RTM_NEWROUTE, flags: CREATE_FLAGS, seq: 8 };
        let add = route_msg(req, "10.98.0.0/16", 0, 100, 2).unwrap();
        assert_eq!(&add[16..24], &[2, 16, 0, 0, 100, 4, 253, 1]);
        assert!(add.ends_with(&attr(4, &0u32.to_ne_bytes())));
    }

    #[test]
    fn route_message_v6_default_delete() {
        for destination in ["default", "::/0"] {
            let req = Request { kind: RTM_DELROUTE, flags: DELETE_FLAGS, seq: 9 };
            let msg = route_msg(req, destination, 1, 201, 10).unwrap();
            let body = cat(&[
                // A default route has no RTA_DST.
                &[10, 0, 0, 0, 201, 4, 255, 1], &0u32.to_ne_bytes(),
                &attr(4, &1u32.to_ne_bytes()),           // RTA_OIF
            ]);
            assert_eq!(msg, cat(&[&nlhdr(16 + body.len() as u32, 25, REQUEST_ACK, 9), &body]),
                       "destination {destination}");
        }
    }

    #[test]
    fn route_message_v4_default_table_above_255() {
        let req = Request { kind: RTM_NEWROUTE, flags: CREATE_FLAGS, seq: 2 };
        let msg = route_msg(req, "0.0.0.0/0", 4, 300, 2).unwrap();
        let body = cat(&[
            &[2, 0, 0, 0, 0, 4, 253, 1], &0u32.to_ne_bytes(),
            &attr(4, &4u32.to_ne_bytes()),               // RTA_OIF
            &attr(15, &300u32.to_ne_bytes()),            // RTA_TABLE
        ]);
        assert_eq!(msg, cat(&[&nlhdr(16 + body.len() as u32, 24, REQUEST_ACK_CREATE_EXCL, 2), &body]));
    }

    /// An NLMSG_ERROR reply (type 2) carrying `code`, after one leading byte;
    /// the tests pass it from offset 1, so it is not 4-byte aligned.
    fn error_reply(code: i32) -> Vec<u8> {
        let mut out = vec![0xAA];
        out.extend(nlhdr(36, 2, 0, 1));
        out.extend(code.to_ne_bytes());
        out.extend([0u8; 16]); // the echoed request header
        out
    }

    #[test]
    fn ack_with_code_zero_is_accepted() {
        assert_eq!(check_ack(&error_reply(0)[1..]), Ok(()));
    }

    #[test]
    fn ack_with_an_errno_is_an_error() {
        for (errno, text) in [(libc::EEXIST, "File exists"), (libc::ENOENT, "No such file"),
                              (libc::EPERM, "Operation not permitted")] {
            let err = check_ack(&error_reply(-errno)[1..]).unwrap_err();
            assert!(err.starts_with("netlink error: ") && err.contains(text), "got: {err}");
        }
    }

    #[test]
    fn ack_that_is_short_or_not_an_error_is_accepted() {
        let reply = error_reply(-libc::EEXIST);
        // Too short for a header, or for the error code after it.
        for len in [0, 5, 15, 16, 19] {
            assert_eq!(check_ack(&reply[1..1 + len]), Ok(()), "len {len}");
        }
        // NLMSG_DONE (3) instead of NLMSG_ERROR.
        let mut done = reply[1..].to_vec();
        done[4..6].copy_from_slice(&3u16.to_ne_bytes());
        assert_eq!(check_ack(&done), Ok(()));
    }

    #[test]
    fn messages_refuse_a_malformed_network() {
        let req = Request { kind: RTM_NEWRULE, flags: CREATE_FLAGS, seq: 1 };
        assert!(policy_msg(req, "10.0.1.0", "", 100, 1, 2).is_err());
        assert!(policy_msg(req, "10.0.1.0/24", "nope/8", 100, 1, 2).is_err());
        assert!(route_msg(req, "10.0.0.0/x", 1, 100, 2).is_err());
    }

    #[test]
    fn policy_messages_refuse_an_address_of_another_family() {
        let req = Request { kind: RTM_NEWRULE, flags: CREATE_FLAGS, seq: 1 };
        for (from, to, family, want) in [
            ("fd00::/64", "", 2, "Address family 2 does not match fd00::/64"),
            ("10.0.0.0/24", "", 10, "Address family 10 does not match 10.0.0.0/24"),
            ("10.0.0.0/24", "fd00::/64", 2, "Address family 2 does not match fd00::/64"),
            ("10.0.0.0/24", "", 0, "Unknown address family: 0"),
        ] {
            assert_eq!(policy_msg(req, from, to, 100, 1, family), Err(want.into()),
                       "from {from} to {to} family {family}");
        }
    }

    #[test]
    fn route_messages_refuse_an_address_of_another_family() {
        let req = Request { kind: RTM_NEWROUTE, flags: CREATE_FLAGS, seq: 1 };
        for (destination, family, want) in [
            ("fd00::/64", 2, "Address family 2 does not match fd00::/64"),
            ("10.98.0.0/16", 10, "Address family 10 does not match 10.98.0.0/16"),
            ("0.0.0.0/0", 10, "Address family 10 does not match 0.0.0.0/0"),
            ("::/0", 2, "Address family 2 does not match ::/0"),
            ("default", 0, "Unknown address family: 0"),
        ] {
            assert_eq!(route_msg(req, destination, 1, 100, family), Err(want.into()),
                       "destination {destination} family {family}");
        }
        // "default" takes either family.
        assert!(route_msg(req, "default", 1, 100, 2).is_ok());
        assert!(route_msg(req, "default", 1, 100, 10).is_ok());
    }

    #[test]
    fn attributes_pad_to_four_bytes() {
        let mut buf = Vec::new();
        push_attr(&mut buf, 7, &[1, 2, 3]);
        assert_eq!(buf, cat(&[&7u16.to_ne_bytes(), &7u16.to_ne_bytes(), &[1, 2, 3, 0]]));
        for (len, aligned) in [(0, 0), (1, 4), (4, 4), (5, 8), (16, 16), (17, 20)] {
            assert_eq!(align4(len), aligned, "len {len}");
        }
    }

    // ── table names ──────────────────────────────────────────────

    /// A fresh directory under target/ for one test.
    fn rt_dir(name: &str) -> std::path::PathBuf {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("target/rt-tests").join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write(path: &Path, content: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, content).unwrap();
    }

    #[test]
    fn resolve_table_builtins_and_numbers_need_no_file() {
        let missing = Path::new("/nonexistent");
        for (name, id) in [("default", 253), ("main", 254), ("local", 255), ("unspec", 0),
                           ("100", 100), ("4294967295", u32::MAX)] {
            assert_eq!(resolve_table_in(missing, missing, name), Ok(id), "name {name}");
        }
    }

    #[test]
    fn resolve_table_reads_the_files_ip_reads() {
        let dir = rt_dir("resolve-files");
        let (etc, usr) = (dir.join("etc"), dir.join("usr"));
        write(&usr.join("rt_tables"), "# comment\n\n255\tlocal\n  100 inusr  \n");
        write(&usr.join("rt_tables.d/a.conf"), "101 usrdropin\n");
        write(&usr.join("rt_tables.d/b.conf"), "102 shadowed\n");
        write(&usr.join("rt_tables.d/b.txt"), "103 notconf\n");
        write(&etc.join("rt_tables.d/b.conf"), "104 inetc\n");
        write(&etc.join("rt_tables.d/.c.conf"), "105 hidden\n");
        // etc/rt_tables is missing: usr/rt_tables is read.
        assert_eq!(resolve_table_in(&etc, &usr, "inusr"), Ok(100));
        assert_eq!(resolve_table_in(&etc, &usr, "usrdropin"), Ok(101));
        assert_eq!(resolve_table_in(&etc, &usr, "inetc"), Ok(104));
        for name in ["shadowed", "notconf", "hidden", "comment"] {
            assert_eq!(resolve_table_in(&etc, &usr, name),
                       Err(format!("Routing table not found: {name}")), "name {name}");
        }
        // With etc/rt_tables present, usr/rt_tables is not read.
        write(&etc.join("rt_tables"), "200 inetcmain\n");
        assert_eq!(resolve_table_in(&etc, &usr, "inetcmain"), Ok(200));
        assert_eq!(resolve_table_in(&etc, &usr, "inusr"),
                   Err("Routing table not found: inusr".into()));
    }

    #[test]
    fn resolve_table_picks_the_entry_ip_picks() {
        let dir = rt_dir("resolve-pick");
        let (etc, usr) = (dir.join("etc"), dir.join("usr"));
        // Lowest id % 256 first: 300 (44) over 200; within 300 and 44, the
        // one read last.
        write(&etc.join("rt_tables"), "200 t\n300 t\n");
        write(&etc.join("rt_tables.d/x.conf"), "44 t\n");
        assert_eq!(resolve_table_in(&etc, &usr, "t"), Ok(44));
        write(&etc.join("rt_tables.d/x.conf"), "556 t\n");
        assert_eq!(resolve_table_in(&etc, &usr, "t"), Ok(556));
    }

    #[test]
    fn resolve_table_reports_a_bad_id_and_a_missing_name() {
        let dir = rt_dir("resolve-bad");
        let (etc, usr) = (dir.join("etc"), dir.join("usr"));
        write(&etc.join("rt_tables"), "x1 broken\n");
        let err = resolve_table_in(&etc, &usr, "broken").unwrap_err();
        assert!(err.starts_with(&format!("Invalid table ID in {}: ", etc.join("rt_tables").display())),
                "got: {err}");
        assert_eq!(resolve_table_in(&dir.join("none"), &dir.join("none"), "mh"),
                   Err("Routing table not found: mh".into()));
    }

    #[test]
    fn ensure_table_creates_the_file_and_its_directory() {
        let path = rt_dir("create").join("etc/rt_tables.d/phantom.conf");
        ensure_table_in(&path, 100, "mh").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "100 mh\n");
        assert!(!path.with_file_name(".phantom.conf.tmp").exists());
    }

    #[test]
    fn ensure_table_writes_an_entry_once() {
        let path = rt_dir("once").join("phantom.conf");
        write(&path, "# kept\n100 mh\n201 mh6\n");
        let before = std::fs::metadata(&path).unwrap().modified().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        ensure_table_in(&path, 100, "mh").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "# kept\n100 mh\n201 mh6\n");
        assert_eq!(std::fs::metadata(&path).unwrap().modified().unwrap(), before);
    }

    #[test]
    fn ensure_table_replaces_the_same_id_or_name() {
        let path = rt_dir("replace").join("phantom.conf");
        write(&path, "# kept\n100 mh\n201 mh6\n300 other\n");
        ensure_table_in(&path, 101, "mh").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(),
                   "# kept\n201 mh6\n300 other\n101 mh\n");
        ensure_table_in(&path, 300, "renamed").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(),
                   "# kept\n201 mh6\n101 mh\n300 renamed\n");
        // One entry can clash with two lines: one by id, one by name.
        ensure_table_in(&path, 201, "mh").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(),
                   "# kept\n300 renamed\n201 mh\n");
    }

    #[test]
    fn ensure_table_refuses_an_empty_spaced_or_numeric_name() {
        let path = rt_dir("bad-name").join("etc/rt_tables.d/phantom.conf");
        // A name of digits only reads back as a table number, not as this id.
        for name in ["", "a b", "tab\tname", " lead", "trail\n", "100", "007"] {
            assert_eq!(ensure_table_in(&path, 101, name),
                       Err(format!("Invalid routing table name: {name:?}")), "name {name:?}");
        }
        assert!(!path.exists(), "a refused name created the file");
    }

    #[test]
    fn ensure_table_refuses_an_entry_longer_than_iproute2_reads() {
        let path = rt_dir("long-name").join("phantom.conf");
        // "7 " and the name: 511 characters fit, 512 do not.
        let fits = "a".repeat(MAX_RT_TABLES_LINE - 2);
        let over = "a".repeat(MAX_RT_TABLES_LINE - 1);
        assert_eq!(ensure_table_in(&path, 7, &over),
                   Err("Routing table entry longer than 511 characters".into()));
        assert!(!path.exists(), "a refused entry created the file");
        assert_eq!(ensure_table_in(&path, 7, &fits), Ok(()));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), format!("7 {fits}\n"));
    }
}

