//! Routing operations via raw netlink sockets.
//!
//! Handles policy rules (ip rule add/del) and routes (ip route add/del)
//! without any subprocess calls — direct kernel communication.

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
const RTN_UNICAST: u8 = 1;

// Route protocols
const RTPROT_STATIC: u8 = 4;

// Route scope
const RT_SCOPE_UNIVERSE: u8 = 0;
const RT_SCOPE_LINK: u8 = 253;

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

// The byte forms below have the kernel's sizes; offsets elsewhere use size_of.
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

/// Read the kernel's answer to a request sent with NLM_F_ACK. An
/// NLMSG_ERROR whose code (the i32 after the header) is not 0 is an error;
/// anything else, a short reply included, counts as accepted.
///
/// The fields are read from bytes, so the buffer's alignment does not matter.
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

fn align4(len: usize) -> usize {
    (len + 3) & !3
}

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
fn addr_bytes(addr: &IpAddr) -> Vec<u8> {
    match addr {
        IpAddr::V4(v4) => v4.octets().to_vec(),
        IpAddr::V6(v6) => v6.octets().to_vec(),
    }
}

/// Resolve interface name to ifindex.
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

/// Resolve named routing table to numeric ID.
/// Reads /etc/iproute2/rt_tables for name→id mapping.
fn resolve_table(table_name: &str) -> Result<u32, String> {
    resolve_table_in(Path::new(RT_TABLES), table_name)
}

fn resolve_table_in(path: &Path, table_name: &str) -> Result<u32, String> {
    // Built-in tables
    match table_name {
        "default" => return Ok(253),
        "main" => return Ok(254),
        "local" => return Ok(255),
        "unspec" => return Ok(0),
        _ => {}
    }

    // Try numeric
    if let Ok(n) = table_name.parse::<u32>() {
        return Ok(n);
    }

    // Read rt_tables file
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("Cannot read rt_tables: {}", e))?;

    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 2 && parts[1] == table_name {
            return parts[0].parse::<u32>()
                .map_err(|e| format!("Invalid table ID in rt_tables: {}", e));
        }
    }

    Err(format!("Routing table not found: {}", table_name))
}

// ---------------------------------------------------------------------------
// Netlink requests — built apart from the socket so the bytes can be tested
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
fn policy_msg(req: Request, from_network: &str, to_network: &str, table_id: u32,
              priority: u32, family: u8) -> Result<Vec<u8>, String> {
    let (from_addr, from_prefix, _) = parse_network(from_network)?;

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
        let (to_addr, to_prefix, _) = parse_network(to_network)?;
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

/// RTM_NEWROUTE / RTM_DELROUTE: <destination> dev <ifindex> table <table>.
/// "default", "0.0.0.0/0" and "::/0" mean the default route of `family`.
fn route_msg(req: Request, destination: &str, ifindex: u32, table_id: u32, family: u8)
    -> Result<Vec<u8>, String>
{
    let (dst_addr, dst_prefix) = if destination == "default" || destination == "0.0.0.0/0" || destination == "::/0" {
        if family == libc::AF_INET6 as u8 {
            (IpAddr::V6(Ipv6Addr::UNSPECIFIED), 0u8)
        } else {
            (IpAddr::V4(Ipv4Addr::new(0, 0, 0, 0)), 0u8)
        }
    } else {
        let (addr, prefix, _) = parse_network(destination)?;
        (addr, prefix)
    };

    let mut buf = Vec::with_capacity(256);
    buf.extend_from_slice(&[0u8; mem::size_of::<NlMsgHdr>()]);

    let rtm = RtMsg {
        rtm_family: family,
        rtm_dst_len: dst_prefix,
        rtm_src_len: 0,
        rtm_tos: 0,
        rtm_table: if table_id <= 255 { table_id as u8 } else { 0 },
        rtm_protocol: RTPROT_STATIC,
        rtm_scope: if dst_prefix == 0 { RT_SCOPE_UNIVERSE } else { RT_SCOPE_LINK },
        rtm_type: RTN_UNICAST,
        rtm_flags: 0,
    };
    buf.extend_from_slice(&rtm.to_bytes());

    if dst_prefix > 0 {
        push_attr(&mut buf, RTA_DST, &addr_bytes(&dst_addr));
    }

    push_attr_u32(&mut buf, RTA_OIF, ifindex);

    if table_id > 255 {
        push_attr_u32(&mut buf, RTA_TABLE, table_id);
    }

    write_header(&mut buf, req);
    Ok(buf)
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
    let ifindex = if_nametoindex(device)?;
    let msg = route_msg(req, destination, ifindex, table_id, family)?;
    sock.send_and_ack(&msg)
}

// ---------------------------------------------------------------------------
// Public routing operations
// ---------------------------------------------------------------------------

/// Add a policy rule: ip rule add from <from> [to <to>] table <table> priority <prio>
pub fn policy_add(from_network: &str, to_network: &str, table_name: &str, priority: u32, family: u8) -> Result<(), String> {
    send_policy(RTM_NEWRULE, CREATE_FLAGS, from_network, to_network, table_name, priority, family)
}

/// Delete a policy rule.
pub fn policy_delete(from_network: &str, to_network: &str, table_name: &str, priority: u32, family: u8) -> Result<(), String> {
    send_policy(RTM_DELRULE, DELETE_FLAGS, from_network, to_network, table_name, priority, family)
}

/// Add a route: ip route add <destination> dev <device> table <table>
/// Use "default" as destination for default route (0.0.0.0/0).
pub fn route_add(destination: &str, device: &str, table_name: &str, family: u8) -> Result<(), String> {
    send_route(RTM_NEWROUTE, CREATE_FLAGS, destination, device, table_name, family)
}

/// Delete a route.
pub fn route_delete(destination: &str, device: &str, table_name: &str, family: u8) -> Result<(), String> {
    send_route(RTM_DELROUTE, DELETE_FLAGS, destination, device, table_name, family)
}

/// The file `ip` reads table names from. iproute2 6.x ships its defaults in
/// `RT_TABLES_DEFAULTS` and stops reading them once this file exists.
const RT_TABLES: &str = "/etc/iproute2/rt_tables";
const RT_TABLES_DEFAULTS: &str = "/usr/share/iproute2/rt_tables";

/// Ensure a routing table entry exists in /etc/iproute2/rt_tables.
pub fn ensure_table(table_id: u32, table_name: &str) -> Result<(), String> {
    ensure_table_in(Path::new(RT_TABLES), Path::new(RT_TABLES_DEFAULTS),
                    table_id, table_name)
}

fn ensure_table_in(path: &Path, defaults: &Path, table_id: u32, table_name: &str)
    -> Result<(), String>
{
    // An entry is `<id> <name>`; an empty name or one with whitespace would
    // write a line that reads back as another name, or as none.
    if table_name.is_empty() || table_name.chars().any(char::is_whitespace) {
        return Err(format!("Invalid routing table name: {table_name:?}"));
    }
    seed_rt_tables(path, defaults)?;
    let entry = format!("{} {}", table_id, table_name);

    let content = std::fs::read_to_string(path)
        .unwrap_or_default();

    // Check if entry already exists
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 2 && parts[0] == table_id.to_string() && parts[1] == table_name {
            return Ok(()); // Already exists
        }
    }

    // Append entry
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|e| format!("Cannot write {}: {}", path.display(), e))?;

    writeln!(file, "{}", entry)
        .map_err(|e| format!("Cannot write to {}: {}", path.display(), e))
}

/// A missing file starts as a copy of the defaults, so creating it keeps
/// `unspec` and any name added there visible to `ip`. With no defaults it
/// starts empty, as before.
fn seed_rt_tables(path: &Path, defaults: &Path) -> Result<(), String> {
    use std::io::Write;
    if path.exists() {
        return Ok(());
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)
            .map_err(|e| format!("Cannot create {}: {}", dir.display(), e))?;
    }
    let mut seed = std::fs::read(defaults).unwrap_or_default();
    if !seed.is_empty() && !seed.ends_with(b"\n") {
        seed.push(b'\n');
    }
    // create_new: if another caller created the file meanwhile, theirs stands.
    match std::fs::OpenOptions::new().write(true).create_new(true).open(path) {
        Ok(mut file) => file.write_all(&seed)
            .map_err(|e| format!("Cannot write {}: {}", path.display(), e)),
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => Ok(()),
        Err(e) => Err(format!("Cannot write {}: {}", path.display(), e)),
    }
}

/// Flush route cache (no-op on Linux >= 3.6, included for compatibility).
pub fn flush_cache() -> Result<(), String> {
    // Modern kernels removed the route cache. Write to proc for older kernels.
    let _ = std::fs::write("/proc/sys/net/ipv4/route/flush", "1");
    Ok(())
}

/// Enable IP forwarding.
pub fn enable_ip_forward() -> Result<(), String> {
    std::fs::write("/proc/sys/net/ipv4/ip_forward", "1")
        .map_err(|e| format!("Cannot enable ip_forward: {}", e))
}

#[cfg(test)]
mod tests {
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
    fn route_message_v6_default_delete() {
        for destination in ["default", "::/0"] {
            let req = Request { kind: RTM_DELROUTE, flags: DELETE_FLAGS, seq: 9 };
            let msg = route_msg(req, destination, 1, 201, 10).unwrap();
            let body = cat(&[
                // A default route has no RTA_DST and universe scope.
                &[10, 0, 0, 0, 201, 4, 0, 1], &0u32.to_ne_bytes(),
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
            &[2, 0, 0, 0, 0, 4, 0, 1], &0u32.to_ne_bytes(),
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
    fn attributes_pad_to_four_bytes() {
        let mut buf = Vec::new();
        push_attr(&mut buf, 7, &[1, 2, 3]);
        assert_eq!(buf, cat(&[&7u16.to_ne_bytes(), &7u16.to_ne_bytes(), &[1, 2, 3, 0]]));
        for (len, aligned) in [(0, 0), (1, 4), (4, 4), (5, 8), (16, 16), (17, 20)] {
            assert_eq!(align4(len), aligned, "len {len}");
        }
    }

    // ── ensure_table ─────────────────────────────────────────────

    /// A fresh directory under target/ for one test.
    fn rt_dir(name: &str) -> std::path::PathBuf {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("target/rt-tests").join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    const DEFAULTS: &str = "255\tlocal\n254\tmain\n253\tdefault\n0\tunspec\n";

    // ── resolve_table ────────────────────────────────────────────

    #[test]
    fn resolve_table_builtins_and_numbers_need_no_file() {
        let missing = Path::new("/nonexistent/rt_tables");
        for (name, id) in [("default", 253), ("main", 254), ("local", 255), ("unspec", 0),
                           ("100", 100), ("4294967295", u32::MAX)] {
            assert_eq!(resolve_table_in(missing, name), Ok(id), "name {name}");
        }
    }

    #[test]
    fn resolve_table_reads_names_from_the_file() {
        let dir = rt_dir("resolve");
        let path = dir.join("rt_tables");
        std::fs::write(&path, "# comment\n\n255\tlocal\n  100 mh  \n201\tmh6\n300 big # note\n").unwrap();
        assert_eq!(resolve_table_in(&path, "mh"), Ok(100));
        assert_eq!(resolve_table_in(&path, "mh6"), Ok(201));
        assert_eq!(resolve_table_in(&path, "big"), Ok(300));
        assert_eq!(resolve_table_in(&path, "comment"), Err("Routing table not found: comment".into()));
        assert_eq!(resolve_table_in(&path, "absent"), Err("Routing table not found: absent".into()));
    }

    #[test]
    fn resolve_table_reports_a_bad_id_and_a_missing_file() {
        let dir = rt_dir("resolve-bad");
        let path = dir.join("rt_tables");
        std::fs::write(&path, "x1 broken\n").unwrap();
        let err = resolve_table_in(&path, "broken").unwrap_err();
        assert!(err.starts_with("Invalid table ID in rt_tables: "), "got: {err}");
        let err = resolve_table_in(&dir.join("absent"), "mh").unwrap_err();
        assert!(err.starts_with("Cannot read rt_tables: "), "got: {err}");
    }

    #[test]
    fn ensure_table_seeds_a_missing_file_from_the_defaults() {
        let dir = rt_dir("seed");
        let defaults = dir.join("defaults");
        std::fs::write(&defaults, DEFAULTS).unwrap();
        let path = dir.join("etc/iproute2/rt_tables");
        ensure_table_in(&path, &defaults, 100, "mh").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), format!("{DEFAULTS}100 mh\n"));
    }

    #[test]
    fn ensure_table_leaves_an_existing_file_unseeded() {
        let dir = rt_dir("existing");
        let defaults = dir.join("defaults");
        std::fs::write(&defaults, DEFAULTS).unwrap();
        let path = dir.join("rt_tables");
        std::fs::write(&path, "100 mh\n").unwrap();
        ensure_table_in(&path, &defaults, 101, "mh6").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "100 mh\n101 mh6\n");
    }

    #[test]
    fn ensure_table_adds_an_entry_once() {
        let dir = rt_dir("once");
        let path = dir.join("rt_tables");
        let defaults = dir.join("no-defaults");
        ensure_table_in(&path, &defaults, 100, "mh").unwrap();
        ensure_table_in(&path, &defaults, 100, "mh").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "100 mh\n");
    }

    #[test]
    fn ensure_table_refuses_a_name_that_is_empty_or_has_whitespace() {
        let dir = rt_dir("bad-name");
        let path = dir.join("etc/iproute2/rt_tables");
        let defaults = dir.join("defaults");
        std::fs::write(&defaults, DEFAULTS).unwrap();
        for name in ["", "a b", "tab\tname", " lead", "trail\n"] {
            assert_eq!(ensure_table_in(&path, &defaults, 101, name),
                       Err(format!("Invalid routing table name: {name:?}")), "name {name:?}");
        }
        assert!(!path.exists(), "a refused name created the file");
    }

    #[test]
    fn ensure_table_ends_defaults_without_a_newline() {
        let dir = rt_dir("no-newline");
        let defaults = dir.join("defaults");
        std::fs::write(&defaults, "0\tunspec").unwrap();
        let path = dir.join("rt_tables");
        ensure_table_in(&path, &defaults, 100, "mh").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "0\tunspec\n100 mh\n");
    }
}

