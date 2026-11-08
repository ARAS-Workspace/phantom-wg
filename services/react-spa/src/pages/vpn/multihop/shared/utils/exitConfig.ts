// Client copy of parse_wireguard_config (phantom_daemon/base/exit_store/
// parser.py). The rules, their order and their edge cases are the daemon's:
// a text this module accepts is a text the daemon accepts, and the other way
// round. The daemon stops at its first error; this module lists every
// problem, the layout first in line order, then the fields in the order of
// the config, as the mac and iOS editors do.

import { isIpInterface, isIPv4Address, isIPv6Address } from './ipAddress';
import { isDigit, isOneWord, splitLines, strip, toInt } from './pythonText';

type SectionName = 'interface' | 'peer';

export type ExitConfigKeyField =
  | 'privateKey'
  | 'address'
  | 'publicKey'
  | 'presharedKey'
  | 'endpoint'
  | 'allowedIps'
  | 'keepalive';

/** A key, a whole section, or a line of the text. */
export type ExitConfigField = ExitConfigKeyField | SectionName | 'line';

export type ExitConfigProblem =
  | 'duplicateSection'
  | 'unknownSection'
  | 'malformedLine'
  | 'outsideSection'
  | 'duplicateKey'
  | 'missing'
  | 'notBase64'
  | 'keyLength'
  | 'empty'
  | 'notCidr'
  | 'endpointIpv6Format'
  | 'endpointIpv6Host'
  | 'endpointHostPort'
  | 'endpointColons'
  | 'endpointIpv4Host'
  | 'portNotNumber'
  | 'portRange'
  | 'notNumber'
  | 'keepaliveRange';

export interface ExitConfigIssue {
  field: ExitConfigField;
  problem: ExitConfigProblem;
  /** The offending part of the value, shown beside the message. */
  value?: string;
  /** The line of the text, for problems of the layout. */
  line?: number;
}

/** The keys and sections as they are written in the config. */
export const EXIT_CONFIG_FIELD_LABELS: Record<Exclude<ExitConfigField, 'line'>, string> = {
  interface: '[Interface]',
  peer: '[Peer]',
  privateKey: '[Interface] PrivateKey',
  address: '[Interface] Address',
  publicKey: '[Peer] PublicKey',
  presharedKey: '[Peer] PresharedKey',
  endpoint: '[Peer] Endpoint',
  allowedIps: '[Peer] AllowedIPs',
  keepalive: '[Peer] PersistentKeepalive',
};

// Section → its keys the daemon uses (lower case → field). Every other key
// in a section is not used and is skipped.
const SECTION_KEYS: Record<SectionName, ReadonlyMap<string, ExitConfigKeyField>> = {
  interface: new Map([
    ['privatekey', 'privateKey'],
    ['address', 'address'],
  ]),
  peer: new Map([
    ['publickey', 'publicKey'],
    ['presharedkey', 'presharedKey'],
    ['endpoint', 'endpoint'],
    ['allowedips', 'allowedIps'],
    ['persistentkeepalive', 'keepalive'],
  ]),
};

// Keys WireGuard allows on more than one line; the lines are joined.
const LIST_KEYS = new Set(['address', 'allowedips']);

const DEFAULT_ALLOWED_IPS = '0.0.0.0/0, ::/0';
const DEFAULT_KEEPALIVE = '5';
const KEY_BYTES = 32;
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/;

interface Sections {
  iface: Map<string, string>;
  peer: Map<string, string>;
  issues: ExitConfigIssue[];
}

function isSectionName(name: string): name is SectionName {
  return name === 'interface' || name === 'peer';
}

/**
 * _read_sections: one [Interface], one [Peer], every other line a comment,
 * a blank line or a key = value inside one of them. Where the daemon raises,
 * this records the problem and goes on; the lines of a refused section are
 * not read, as the daemon never reaches them.
 */
function readSections(text: string): Sections {
  const values: Record<SectionName, Map<string, string>> = {
    interface: new Map(),
    peer: new Map(),
  };
  const seen = new Set<SectionName>();
  const issues: ExitConfigIssue[] = [];
  let section: SectionName | null = null;
  let skipping = false;

  splitLines(text).forEach((rawLine, index) => {
    const number = index + 1;
    const line = strip(rawLine);
    if (!line || line.startsWith('#')) return;

    if (line.startsWith('[')) {
      if (!line.endsWith(']')) {
        issues.push({ field: 'line', problem: 'malformedLine', line: number });
        return;
      }
      const name = strip(line.slice(1, -1));
      const lower = name.toLowerCase();
      section = null;
      skipping = true;
      if (!isSectionName(lower)) {
        issues.push({ field: 'line', problem: 'unknownSection', line: number, value: `[${name}]` });
      } else if (seen.has(lower)) {
        issues.push({ field: lower, problem: 'duplicateSection', line: number });
      } else {
        seen.add(lower);
        section = lower;
        skipping = false;
      }
      return;
    }
    if (skipping) return;

    const equals = line.indexOf('=');
    if (equals < 0) {
      issues.push({ field: 'line', problem: 'malformedLine', line: number });
      return;
    }
    if (section === null) {
      issues.push({ field: 'line', problem: 'outsideSection', line: number });
      return;
    }
    const key = strip(line.slice(0, equals)).toLowerCase();
    if (!isOneWord(key)) {
      issues.push({ field: 'line', problem: 'malformedLine', line: number });
      return;
    }

    const field = SECTION_KEYS[section].get(key);
    if (field === undefined) return;
    const current = values[section];
    const value = strip(line.slice(equals + 1));
    const previous = current.get(key);
    if (previous === undefined) {
      current.set(key, value);
    } else if (LIST_KEYS.has(key)) {
      current.set(key, `${previous}, ${value}`);
    } else {
      issues.push({ field, problem: 'duplicateKey', line: number });
    }
  });

  return { iface: values.interface, peer: values.peer, issues };
}

/** base64.b64decode(value, validate=True) must give 32 bytes. */
function keyIssue(field: ExitConfigField, value: string): ExitConfigIssue | null {
  if (!BASE64.test(value) || value.length % 4 !== 0) return { field, problem: 'notBase64' };
  const padding = value.endsWith('==') ? 2 : value.endsWith('=') ? 1 : 0;
  const bytes = (value.length / 4) * 3 - padding;
  if (bytes !== KEY_BYTES) return { field, problem: 'keyLength', value: String(bytes) };
  return null;
}

/** _split_csv */
function splitCsv(value: string): string[] {
  return value
    .split(',')
    .map((part) => strip(part))
    .filter((part) => part !== '');
}

/** _validate_address and _validate_allowed_ips: one or more CIDRs. */
function cidrListIssue(field: ExitConfigField, value: string): ExitConfigIssue | null {
  const parts = splitCsv(value);
  if (parts.length === 0) return { field, problem: 'empty' };
  const invalid = parts.find((part) => !isIpInterface(part));
  return invalid === undefined ? null : { field, problem: 'notCidr', value: invalid };
}

/** _looks_like_ipv4: four dot-separated all-numeric labels. */
function looksLikeIpv4(host: string): boolean {
  const labels = host.split('.');
  return labels.length === 4 && labels.every((label) => isDigit(label));
}

/** _validate_endpoint */
function endpointIssue(endpoint: string): ExitConfigIssue | null {
  const field: ExitConfigField = 'endpoint';
  let portText: string;

  if (endpoint.startsWith('[')) {
    const close = endpoint.indexOf(']:');
    if (close < 0) return { field, problem: 'endpointIpv6Format', value: endpoint };
    const host = endpoint.slice(0, close);
    portText = endpoint.slice(close + 2);
    if (!isIPv6Address(host.slice(1))) {
      return { field, problem: 'endpointIpv6Host', value: `${host}]` };
    }
  } else {
    const colon = endpoint.indexOf(':');
    const host = colon < 0 ? '' : endpoint.slice(0, colon);
    if (colon < 0 || !host) return { field, problem: 'endpointHostPort', value: endpoint };
    portText = endpoint.slice(colon + 1);
    if (portText.includes(':')) return { field, problem: 'endpointColons', value: endpoint };
    if (looksLikeIpv4(host) && !isIPv4Address(host)) {
      return { field, problem: 'endpointIpv4Host', value: host };
    }
  }

  const port = toInt(portText);
  if (port === null) return { field, problem: 'portNotNumber', value: portText };
  if (port < 1n || port > 65535n) return { field, problem: 'portRange', value: String(port) };
  return null;
}

/** _validate_keepalive */
function keepaliveIssue(value: string): ExitConfigIssue | null {
  const seconds = toInt(value);
  if (seconds === null) return { field: 'keepalive', problem: 'notNumber', value };
  if (seconds < 0n || seconds > 65535n) {
    return { field: 'keepalive', problem: 'keepaliveRange', value: String(seconds) };
  }
  return null;
}

/**
 * Every problem parse_wireguard_config would raise for this text: the layout
 * in line order, then the fields in the order of the config. An empty list
 * means the daemon accepts the text.
 */
export function validateExitConfig(text: string): ExitConfigIssue[] {
  const { iface, peer, issues } = readSections(text);
  const add = (issue: ExitConfigIssue | null) => {
    if (issue) issues.push(issue);
  };
  const required = (
    field: ExitConfigField,
    value: string | undefined,
    check: (present: string) => ExitConfigIssue | null
  ) => add(value === undefined ? { field, problem: 'missing' } : check(value));

  required('privateKey', iface.get('privatekey'), (v) => keyIssue('privateKey', v));
  required('address', iface.get('address'), (v) => cidrListIssue('address', v));
  required('publicKey', peer.get('publickey'), (v) => keyIssue('publicKey', v));
  const presharedKey = peer.get('presharedkey');
  if (presharedKey !== undefined) add(keyIssue('presharedKey', presharedKey));
  required('endpoint', peer.get('endpoint'), endpointIssue);
  add(cidrListIssue('allowedIps', peer.get('allowedips') ?? DEFAULT_ALLOWED_IPS));
  add(keepaliveIssue(peer.get('persistentkeepalive') ?? DEFAULT_KEEPALIVE));
  return issues;
}
