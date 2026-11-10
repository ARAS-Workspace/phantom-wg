import React from 'react';
import { useNavigate } from 'react-router-dom';
import { ClickableTile, Tile, Grid, Column, SkeletonText, Tag } from '@carbon/react';
import {
  Activity,
  UserMultiple,
  WirelessCheckout,
  NetworkOverlay,
  ServerDns,
  ConnectionTwoWay,
} from '@carbon/icons-react';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import { type PeerInfo } from '@shared/types/wireguard';
import { useDashboardData } from '../contexts/DashboardDataContext';
import './styles/DashboardStatus.scss';

const DashboardStatus: React.FC = () => {
  const { locale } = useLocale();
  const t = translate(locale);
  const navigate = useNavigate();

  const countOnlinePeers = (peers: PeerInfo[]): number => {
    const now = Math.floor(Date.now() / 1000);
    return peers.filter((p) => p.latest_handshake > 0 && now - p.latest_handshake < 180).length;
  };

  const { hello, network, wireguard, multihop, loading } = useDashboardData();

  return (
    <Grid className="dashboard-status" data-testid="dashboard-status">
      {/* Daemon Status */}
      <Column lg={5} md={4} sm={4}>
        <Tile className="dashboard-status__tile">
          <div className="dashboard-status__tile-icon">
            <Activity size={24} />
          </div>
          <div className="dashboard-status__tile-content">
            <p className="dashboard-status__tile-label">{t.dashboard.daemonStatus}</p>
            {loading ? (
              <SkeletonText width="60%" />
            ) : hello ? (
              <div className="dashboard-status__tile-value">
                <Tag type="green" size="sm">{t.dashboard.online}</Tag>
                <span className="dashboard-status__version">v{hello.version}</span>
              </div>
            ) : (
              <Tag type="red" size="sm">{t.dashboard.offline}</Tag>
            )}
          </div>
        </Tile>
      </Column>

      {/* Client Pool */}
      <Column lg={5} md={4} sm={4}>
        <ClickableTile
          className="dashboard-status__tile"
          onClick={() => navigate('/vpn/clients')}
        >
          <div className="dashboard-status__tile-icon">
            <UserMultiple size={24} />
          </div>
          <div className="dashboard-status__tile-content">
            <p className="dashboard-status__tile-label">{t.dashboard.clientPool}</p>
            {loading ? (
              <SkeletonText width="80%" />
            ) : network ? (
              <p className="dashboard-status__tile-value">
                <span className="dashboard-status__stat">
                  {network.pool.assigned} / {network.pool.total}
                </span>
                <span className="dashboard-status__stat-secondary">
                  {network.pool.free} {t.dashboard.free}
                </span>
              </p>
            ) : (
              <span className="dashboard-status__unavailable">—</span>
            )}
          </div>
        </ClickableTile>
      </Column>

      {/* WireGuard Peers */}
      <Column lg={6} md={4} sm={4}>
        <ClickableTile
          className="dashboard-status__tile"
          onClick={() => navigate('/vpn/wireguard')}
        >
          <div className="dashboard-status__tile-icon">
            <WirelessCheckout size={24} />
          </div>
          <div className="dashboard-status__tile-content">
            <p className="dashboard-status__tile-label">{t.dashboard.wireguardPeers}</p>
            {loading ? (
              <SkeletonText width="70%" />
            ) : wireguard ? (
              <p className="dashboard-status__tile-value">
                <span className="dashboard-status__stat" data-testid="dashboard-wg-total">
                  {wireguard.total_peers} {t.dashboard.total}
                </span>
                <span className="dashboard-status__stat-online">
                  {countOnlinePeers(wireguard.peers)} {t.dashboard.online}
                </span>
              </p>
            ) : (
              <span className="dashboard-status__unavailable">—</span>
            )}
          </div>
        </ClickableTile>
      </Column>

      {/* Network */}
      <Column lg={5} md={4} sm={4}>
        <ClickableTile
          className="dashboard-status__tile"
          onClick={() => navigate('/vpn/network')}
        >
          <div className="dashboard-status__tile-icon">
            <NetworkOverlay size={24} />
          </div>
          <div className="dashboard-status__tile-content">
            <p className="dashboard-status__tile-label">{t.dashboard.network}</p>
            {loading ? (
              <SkeletonText width="90%" />
            ) : network ? (
              <div className="dashboard-status__tile-value dashboard-status__tile-value--stacked">
                <span className="dashboard-status__subnet">{network.ipv4_subnet}</span>
                <span className="dashboard-status__subnet">{network.ipv6_subnet}</span>
              </div>
            ) : (
              <span className="dashboard-status__unavailable">—</span>
            )}
          </div>
        </ClickableTile>
      </Column>

      {/* DNS */}
      <Column lg={5} md={4} sm={4}>
        <ClickableTile
          className="dashboard-status__tile"
          onClick={() => navigate('/vpn/dns')}
        >
          <div className="dashboard-status__tile-icon">
            <ServerDns size={24} />
          </div>
          <div className="dashboard-status__tile-content">
            <p className="dashboard-status__tile-label">{t.dashboard.dns}</p>
            {loading ? (
              <SkeletonText width="75%" />
            ) : network ? (
              <div className="dashboard-status__tile-value dashboard-status__tile-value--stacked">
                <span className="dashboard-status__dns">v4: {network.dns_v4.primary}</span>
                <span className="dashboard-status__dns">v6: {network.dns_v6.primary}</span>
              </div>
            ) : (
              <span className="dashboard-status__unavailable">—</span>
            )}
          </div>
        </ClickableTile>
      </Column>

      {/* Multihop */}
      <Column lg={6} md={4} sm={4}>
        <ClickableTile
          className="dashboard-status__tile"
          onClick={() => navigate('/vpn/multihop')}
        >
          <div className="dashboard-status__tile-icon">
            <ConnectionTwoWay size={24} />
          </div>
          <div className="dashboard-status__tile-content">
            <p className="dashboard-status__tile-label">{t.dashboard.multihop}</p>
            {loading ? (
              <SkeletonText width="50%" />
            ) : multihop ? (
              <div className="dashboard-status__tile-value">
                <Tag type={multihop.enabled ? 'green' : 'gray'} size="sm">
                  {multihop.enabled ? t.dashboard.active : t.dashboard.inactive}
                </Tag>
                {multihop.active && (
                  <span className="dashboard-status__exit-name">{multihop.active}</span>
                )}
              </div>
            ) : (
              <span className="dashboard-status__unavailable">—</span>
            )}
          </div>
        </ClickableTile>
      </Column>
    </Grid>
  );
};

export default DashboardStatus;
