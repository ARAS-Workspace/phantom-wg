import React, { useState, useCallback, useEffect } from 'react';
import {
  Grid,
  Column,
  Tile,
  Button,
  InlineNotification,
  ProgressBar,
  Tag,
  SkeletonText,
} from '@carbon/react';
import { Renew, Edit } from '@carbon/icons-react';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import { apiClient } from '@shared/api/client';
import { useUser } from '@shared/contexts/UserContext';
import ChangeCidrModal from './modals/ChangeCidrModal';
import './styles/NetworkConfig.scss';

// ── Types ─────────────────────────────────────────────────────────

interface PoolStats {
  total: number;
  assigned: number;
  free: number;
}

interface DnsDetail {
  primary: string;
  secondary: string;
}

interface NetworkStatus {
  ipv4_subnet: string;
  ipv6_subnet: string;
  dns_v4: DnsDetail;
  dns_v6: DnsDetail;
  pool: PoolStats;
}

interface ValidateResult {
  valid: boolean;
  errors: string[];
}

// ── Component ─────────────────────────────────────────────────────

const NetworkConfig: React.FC = () => {
  const { locale } = useLocale();
  const t = translate(locale);
  const { can } = useUser();
  const canOperate = can('operate');

  const [data, setData] = useState<NetworkStatus | null>(null);
  const [loading, setLoading] = useState(true);
  const [editOpen, setEditOpen] = useState(false);
  const [successMsg, setSuccessMsg] = useState<string | null>(null);

  // Validation
  const [validating, setValidating] = useState(false);
  const [validation, setValidation] = useState<ValidateResult | null>(null);

  // ── Fetch ─────────────────────────────────────────────────────
  const fetchNetwork = useCallback(async () => {
    setLoading(true);
    const res = await apiClient.get<NetworkStatus>('/api/core/network');
    if (res.ok) setData(res.data);
    setLoading(false);
  }, []);

  useEffect(() => {
    void fetchNetwork();
  }, [fetchNetwork]);

  // ── Validate ──────────────────────────────────────────────────
  const handleValidate = async () => {
    setValidating(true);
    setValidation(null);
    const res = await apiClient.get<ValidateResult>('/api/core/network/validate');
    if (res.ok) setValidation(res.data);
    setValidating(false);
  };

  // ── CIDR saved callback ───────────────────────────────────────
  const handleCidrSaved = (updated: {
    ipv4_subnet: string;
    ipv6_subnet: string;
    pool: PoolStats;
  }) => {
    if (data) {
      setData({ ...data, ipv4_subnet: updated.ipv4_subnet, ipv6_subnet: updated.ipv6_subnet, pool: updated.pool });
    }
    setEditOpen(false);
    setSuccessMsg(t.network.cidrSaved);
    setValidation(null);
  };

  // ── Loading skeleton ──────────────────────────────────────────
  if (loading && !data) {
    return (
      <>
        <Grid>
          <Column lg={8} md={4} sm={4}>
            <Tile className="network__tile">
              <SkeletonText heading width="30%" />
              <div className="network__kv-grid">
                <div className="network__kv"><SkeletonText width="80%" /><SkeletonText width="60%" /></div>
                <div className="network__kv"><SkeletonText width="80%" /><SkeletonText width="60%" /></div>
              </div>
            </Tile>
          </Column>
          <Column lg={8} md={4} sm={4}>
            <Tile className="network__tile">
              <SkeletonText heading width="30%" />
              <div className="network__kv-grid">
                <div className="network__kv"><SkeletonText width="80%" /><SkeletonText width="60%" /></div>
                <div className="network__kv"><SkeletonText width="80%" /><SkeletonText width="60%" /></div>
              </div>
            </Tile>
          </Column>
        </Grid>
        <Grid>
          <Column lg={16} md={8} sm={4}>
            <Tile className="network__tile">
              <SkeletonText heading width="20%" />
              <SkeletonText width="100%" />
              <div className="network__kv-grid network__kv-grid--pool">
                <div className="network__kv"><SkeletonText width="60%" /><SkeletonText width="40%" /></div>
                <div className="network__kv"><SkeletonText width="60%" /><SkeletonText width="40%" /></div>
                <div className="network__kv"><SkeletonText width="60%" /><SkeletonText width="40%" /></div>
              </div>
            </Tile>
          </Column>
        </Grid>
      </>
    );
  }

  if (!data) return null;

  const pool = data.pool;
  const usagePercent = pool.total > 0 ? Math.round((pool.assigned / pool.total) * 100) : 0;
  const poolTagKind = usagePercent >= 90 ? 'red' : usagePercent >= 70 ? 'warm-gray' : 'green';

  return (
    <>
      {/* ── Notifications ─────────────────────────────────────── */}
      {successMsg && (
        <Grid>
          <Column lg={16} md={8} sm={4}>
            <InlineNotification
              kind="success"
              title={successMsg}
              onCloseButtonClick={() => setSuccessMsg(null)}
              className="network__notification"
              data-testid="vpn-net-notification"
            />
          </Column>
        </Grid>
      )}

      {validation && (
        <Grid>
          <Column lg={16} md={8} sm={4}>
            <InlineNotification
              kind={validation.valid ? 'success' : 'error'}
              title={validation.valid ? t.network.poolValid : t.network.poolInvalid}
              subtitle={
                validation.errors.length > 0
                  ? validation.errors.join(' | ')
                  : undefined
              }
              lowContrast
              onCloseButtonClick={() => setValidation(null)}
              className="network__notification"
              data-testid="vpn-net-validate-result"
            />
          </Column>
        </Grid>
      )}

      {/* ── Subnet tiles ──────────────────────────────────────── */}
      <Grid>
        <Column lg={8} md={4} sm={4}>
          <Tile className="network__tile" data-testid="vpn-net-card-v4">
            <div className="network__tile-header">
              <p className="network__tile-title">IPv4</p>
              <div className="network__tile-actions">
                <Button
                  renderIcon={Renew}
                  size="sm"
                  kind="ghost"
                  iconDescription={t.network.refresh}
                  hasIconOnly
                  onClick={() => void fetchNetwork()}
                  disabled={loading}
                  data-testid="vpn-net-refresh"
                />
                {canOperate && (
                  <Button
                    renderIcon={Edit}
                    size="sm"
                    kind="ghost"
                    iconDescription={t.network.changeCidr}
                    hasIconOnly
                    onClick={() => setEditOpen(true)}
                    data-testid="vpn-net-edit-cidr"
                  />
                )}
              </div>
            </div>
            <div className="network__kv-grid">
              <div className="network__kv">
                <span className="network__kv-label">{t.network.subnet}</span>
                <span className="network__kv-value" data-testid="vpn-net-v4-subnet">
                  {data.ipv4_subnet}
                </span>
              </div>
              <div className="network__kv">
                <span className="network__kv-label">{t.network.dns}</span>
                <span className="network__kv-value" data-testid="vpn-net-v4-dns">
                  {data.dns_v4.primary}{data.dns_v4.secondary ? ` / ${data.dns_v4.secondary}` : ''}
                </span>
              </div>
            </div>
          </Tile>
        </Column>

        <Column lg={8} md={4} sm={4}>
          <Tile className="network__tile" data-testid="vpn-net-card-v6">
            <div className="network__tile-header">
              <p className="network__tile-title">IPv6</p>
            </div>
            <div className="network__kv-grid">
              <div className="network__kv">
                <span className="network__kv-label">{t.network.subnet}</span>
                <span className="network__kv-value" data-testid="vpn-net-v6-subnet">
                  {data.ipv6_subnet}
                </span>
              </div>
              <div className="network__kv">
                <span className="network__kv-label">{t.network.dns}</span>
                <span className="network__kv-value" data-testid="vpn-net-v6-dns">
                  {data.dns_v6.primary}{data.dns_v6.secondary ? ` / ${data.dns_v6.secondary}` : ''}
                </span>
              </div>
            </div>
          </Tile>
        </Column>
      </Grid>

      {/* ── Pool tile ─────────────────────────────────────────── */}
      <Grid>
        <Column lg={16} md={8} sm={4}>
          <Tile className="network__tile" data-testid="vpn-net-pool">
            <div className="network__tile-header">
              <p className="network__tile-title">{t.network.pool}</p>
              <Tag type={poolTagKind} size="sm" data-testid="vpn-net-pool-tag">
                {usagePercent}%
              </Tag>
            </div>

            <ProgressBar
              value={usagePercent}
              max={100}
              size="small"
              label={`${pool.assigned} / ${pool.total}`}
              helperText={`${pool.free} ${t.network.free}`}
              className="network__progress"
              data-testid="vpn-net-pool-bar"
            />

            <div className="network__kv-grid network__kv-grid--pool">
              <div className="network__kv">
                <span className="network__kv-label">{t.network.total}</span>
                <span className="network__kv-value" data-testid="vpn-net-pool-total">
                  {pool.total}
                </span>
              </div>
              <div className="network__kv">
                <span className="network__kv-label">{t.network.assigned}</span>
                <span className="network__kv-value" data-testid="vpn-net-pool-assigned">
                  {pool.assigned}
                </span>
              </div>
              <div className="network__kv">
                <span className="network__kv-label">{t.network.free}</span>
                <span className="network__kv-value" data-testid="vpn-net-pool-free">
                  {pool.free}
                </span>
              </div>
            </div>
          </Tile>
        </Column>
      </Grid>

      {/* ── Validate ──────────────────────────────────────────── */}
      <Grid>
        <Column lg={16} md={8} sm={4}>
          <Button
            size="sm"
            kind="tertiary"
            onClick={() => void handleValidate()}
            disabled={validating}
            data-testid="vpn-net-validate-btn"
          >
            {validating ? t.network.validating : t.network.validate}
          </Button>
        </Column>
      </Grid>

      {canOperate && (
        <ChangeCidrModal
          open={editOpen}
          currentPrefix={parseInt(data.ipv4_subnet.split('/')[1], 10)}
          assignedCount={pool.assigned}
          onClose={() => setEditOpen(false)}
          onSaved={handleCidrSaved}
        />
      )}
    </>
  );
};

export default NetworkConfig;
