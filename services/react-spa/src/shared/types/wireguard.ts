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
