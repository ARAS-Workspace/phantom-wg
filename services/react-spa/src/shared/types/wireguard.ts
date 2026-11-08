export interface InterfaceInfo {
  public_key: string;
  listen_port: number;
  fwmark: number;
}

export interface PeerInfo {
  public_key: string;
  name: string | null;
  endpoint: string;
  allowed_ips: string[];
  latest_handshake: number;
  rx_bytes: number;
  tx_bytes: number;
  keepalive: number;
}

export interface WireGuardStatusData {
  interface: InterfaceInfo;
  peers: PeerInfo[];
  total_peers: number;
}

export type PeerStatus = 'online' | 'offline' | 'never';

const ONLINE_THRESHOLD_SECS = 180;

export function getPeerStatus(latestHandshake: number): PeerStatus {
  if (latestHandshake === 0) return 'never';
  return Date.now() / 1000 - latestHandshake < ONLINE_THRESHOLD_SECS ? 'online' : 'offline';
}

export type PeerSortKey = 'name' | 'last_handshake' | 'rx' | 'tx';

export type SortDirection = 'ASC' | 'DESC';

const NAME_ORDER = new Intl.Collator('en', { numeric: true });

const NUMERIC_FIELD: Record<Exclude<PeerSortKey, 'name'>, keyof PeerInfo> = {
  last_handshake: 'latest_handshake',
  rx: 'rx_bytes',
  tx: 'tx_bytes',
};

function compareByName(a: PeerInfo, b: PeerInfo): number {
  if (a.name !== null && b.name !== null) return NAME_ORDER.compare(a.name, b.name);
  if (a.name !== null) return -1;
  if (b.name !== null) return 1;
  return a.public_key < b.public_key ? -1 : a.public_key > b.public_key ? 1 : 0;
}

export function sortPeers(
  peers: PeerInfo[],
  key: PeerSortKey,
  direction: SortDirection
): PeerInfo[] {
  const sign = direction === 'ASC' ? 1 : -1;
  if (key === 'name') {
    return [...peers].sort((a, b) => sign * compareByName(a, b));
  }
  const field = NUMERIC_FIELD[key];
  return [...peers].sort(
    (a, b) => sign * ((a[field] as number) - (b[field] as number)) || compareByName(a, b)
  );
}
