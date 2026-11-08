// Python's ipaddress module, the acceptance rules the daemon's exit config
// parser uses: IPv4Address, IPv6Address (with a scope id), and
// ip_interface / ip_network(strict=False), which accept the same strings.

import { isAscii, isDigit } from './pythonText';

const HEXTET = /^[0-9a-fA-F]{1,4}$/;
const ASCII_DIGITS = /^[0-9]+$/;
const HEXTET_COUNT = 8;
const IPV6_MAX_LENGTH = 45;

/** IPv4Address._ip_int_from_string; null where Python raises. */
function ipv4ToInt(text: string): number | null {
  if (!text) return null;
  const octets = text.split('.');
  if (octets.length !== 4) return null;
  let value = 0;
  for (const octet of octets) {
    if (!octet) return null;
    if (!(isAscii(octet) && isDigit(octet))) return null;
    if (octet.length > 3) return null;
    if (octet !== '0' && octet[0] === '0') return null;
    const number = parseInt(octet, 10);
    if (number > 255) return null;
    value = value * 256 + number;
  }
  return value;
}

/** IPv6Address._ip_int_from_string, as a yes or no. */
function isIPv6Integer(text: string): boolean {
  if (!text) return false;
  if (Array.from(text).length > IPV6_MAX_LENGTH) return false;

  const parts = text.split(':');
  if (parts.length < 3) return false;

  if (parts[parts.length - 1].includes('.')) {
    if (ipv4ToInt(parts.pop() ?? '') === null) return false;
    parts.push('0', '0');
  }
  if (parts.length > HEXTET_COUNT + 1) return false;

  let skipIndex: number | null = null;
  for (let i = 1; i < parts.length - 1; i++) {
    if (!parts[i]) {
      if (skipIndex !== null) return false;
      skipIndex = i;
    }
  }

  let partsHi: number;
  let partsLo: number;
  if (skipIndex !== null) {
    partsHi = skipIndex;
    partsLo = parts.length - skipIndex - 1;
    if (!parts[0]) {
      partsHi -= 1;
      if (partsHi) return false;
    }
    if (!parts[parts.length - 1]) {
      partsLo -= 1;
      if (partsLo) return false;
    }
    if (HEXTET_COUNT - (partsHi + partsLo) < 1) return false;
  } else {
    if (parts.length !== HEXTET_COUNT) return false;
    if (!parts[0] || !parts[parts.length - 1]) return false;
    partsHi = parts.length;
    partsLo = 0;
  }

  const hextets = [...parts.slice(0, partsHi), ...parts.slice(parts.length - partsLo)];
  return hextets.every((hextet) => HEXTET.test(hextet));
}

/** IPv4Address(text) */
export function isIPv4Address(text: string): boolean {
  return !text.includes('/') && ipv4ToInt(text) !== null;
}

/** IPv6Address(text), a scope id after '%' included. */
export function isIPv6Address(text: string): boolean {
  if (text.includes('/')) return false;
  const percent = text.indexOf('%');
  if (percent < 0) return isIPv6Integer(text);
  const scope = text.slice(percent + 1);
  if (!scope || scope.includes('%')) return false;
  return isIPv6Integer(text.slice(0, percent));
}

/** _prefix_from_ip_int: ones followed by zeros. */
function isPrefixMask(mask: number): boolean {
  if (mask === 0) return true;
  let trailingZeros = 0;
  while (trailingZeros < 32 && Math.floor(mask / 2 ** trailingZeros) % 2 === 0) trailingZeros++;
  const prefixLength = 32 - trailingZeros;
  return Math.floor(mask / 2 ** trailingZeros) === 2 ** prefixLength - 1;
}

/** IPv4 _make_netmask: a prefix length, a netmask or a hostmask. */
function isIPv4Prefix(prefix: string): boolean {
  if (isAscii(prefix) && isDigit(prefix)) return parseInt(prefix, 10) <= 32;
  const mask = ipv4ToInt(prefix);
  if (mask === null) return false;
  return isPrefixMask(mask) || isPrefixMask(0xffffffff - mask);
}

/** IPv6 _make_netmask: a prefix length only. */
function isIPv6Prefix(prefix: string): boolean {
  return ASCII_DIGITS.test(prefix) && parseInt(prefix, 10) <= 128;
}

/** ipaddress.ip_interface(text) and ipaddress.ip_network(text, strict=False) */
export function isIpInterface(text: string): boolean {
  const parts = text.split('/');
  if (parts.length > 2) return false;
  const [address, prefix] = parts;
  if (isIPv4Address(address) && (prefix === undefined || isIPv4Prefix(prefix))) return true;
  return isIPv6Address(address) && (prefix === undefined || isIPv6Prefix(prefix));
}
