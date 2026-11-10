import React, { createContext, useContext, useEffect, useState, ReactNode } from 'react';
import { apiClient } from '@shared/api/client';
import { type WireGuardStatusData } from '@shared/types/wireguard';

export interface HelloData {
  message: string;
  version: string;
}

interface PoolStats {
  total: number;
  assigned: number;
  free: number;
}

interface DnsDetail {
  primary: string;
  secondary: string;
}

export interface NetworkData {
  ipv4_subnet: string;
  ipv6_subnet: string;
  dns_v4: DnsDetail;
  dns_v6: DnsDetail;
  pool: PoolStats;
}

export interface MultihopData {
  enabled: boolean;
  active: string;
}

export interface DashboardData {
  hello: HelloData | null;
  network: NetworkData | null;
  wireguard: WireGuardStatusData | null;
  multihop: MultihopData | null;
  loading: boolean;
}

const DashboardDataContext = createContext<DashboardData | undefined>(undefined);

// The reads of the dashboard, once per mount: the status tiles and the peers
// table show the same answers.
export const DashboardDataProvider: React.FC<{ children: ReactNode }> = ({ children }) => {
  const [data, setData] = useState<DashboardData>({
    hello: null,
    network: null,
    wireguard: null,
    multihop: null,
    loading: true,
  });

  useEffect(() => {
    void Promise.all([
      apiClient.get<HelloData>('/api/core/hello'),
      apiClient.get<NetworkData>('/api/core/network'),
      apiClient.get<WireGuardStatusData>('/api/core/wireguard'),
      apiClient.get<MultihopData>('/api/multihop/status'),
    ]).then(([helloRes, networkRes, wireguardRes, multihopRes]) => {
      setData({
        hello: helloRes.ok ? helloRes.data : null,
        network: networkRes.ok ? networkRes.data : null,
        wireguard: wireguardRes.ok ? wireguardRes.data : null,
        multihop: multihopRes.ok ? multihopRes.data : null,
        loading: false,
      });
    });
  }, []);

  return <DashboardDataContext.Provider value={data}>{children}</DashboardDataContext.Provider>;
};

export const useDashboardData = (): DashboardData => {
  const context = useContext(DashboardDataContext);
  if (!context) {
    throw new Error('useDashboardData must be used within DashboardDataProvider');
  }
  return context;
};
