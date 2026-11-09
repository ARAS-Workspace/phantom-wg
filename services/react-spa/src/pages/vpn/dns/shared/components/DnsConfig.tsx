import React, { useState, useCallback, useEffect } from 'react';
import {
  Grid,
  Column,
  Tile,
  Button,
  InlineNotification,
  SkeletonText,
} from '@carbon/react';
import { Edit, Renew } from '@carbon/icons-react';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import { apiClient } from '@shared/api/client';
import { useUser } from '@shared/contexts/UserContext';
import EditDnsModal from './modals/EditDnsModal';
import './styles/DnsConfig.scss';

// ── Types ─────────────────────────────────────────────────────────

interface DnsRecord {
  family: string;
  primary: string;
  secondary: string;
}

type DnsFamily = 'v4' | 'v6';

// ── Component ─────────────────────────────────────────────────────

const DnsConfig: React.FC = () => {
  const { locale } = useLocale();
  const t = translate(locale);
  const { can } = useUser();
  const canOperate = can('operate');

  const [v4, setV4] = useState<DnsRecord | null>(null);
  const [v6, setV6] = useState<DnsRecord | null>(null);
  const [loading, setLoading] = useState(true);
  const [editFamily, setEditFamily] = useState<DnsFamily | null>(null);
  const [successMsg, setSuccessMsg] = useState<string | null>(null);

  // ── Fetch ─────────────────────────────────────────────────────
  const fetchDns = useCallback(async () => {
    setLoading(true);
    const [r4, r6] = await Promise.all([
      apiClient.post<DnsRecord>('/api/dns/get', { family: 'v4' }),
      apiClient.post<DnsRecord>('/api/dns/get', { family: 'v6' }),
    ]);
    if (r4.ok) setV4(r4.data);
    if (r6.ok) setV6(r6.data);
    setLoading(false);
  }, []);

  useEffect(() => {
    void fetchDns();
  }, [fetchDns]);

  // ── Save callback (modal handles API + errors internally) ────
  const handleSaved = (record: DnsRecord) => {
    if (record.family === 'v4') setV4(record);
    else setV6(record);
    setEditFamily(null);
    setSuccessMsg(t.dns.saved);
  };

  // ── Loading skeleton ──────────────────────────────────────────
  if (loading && !v4 && !v6) {
    return (
      <Grid>
        <Column lg={8} md={4} sm={4}>
          <Tile className="dns__tile">
            <SkeletonText heading width="30%" />
            <div className="dns__kv-grid">
              <div className="dns__kv"><SkeletonText width="80%" /><SkeletonText width="60%" /></div>
              <div className="dns__kv"><SkeletonText width="80%" /><SkeletonText width="60%" /></div>
            </div>
          </Tile>
        </Column>
        <Column lg={8} md={4} sm={4}>
          <Tile className="dns__tile">
            <SkeletonText heading width="30%" />
            <div className="dns__kv-grid">
              <div className="dns__kv"><SkeletonText width="80%" /><SkeletonText width="60%" /></div>
              <div className="dns__kv"><SkeletonText width="80%" /><SkeletonText width="60%" /></div>
            </div>
          </Tile>
        </Column>
      </Grid>
    );
  }

  const editRecord = editFamily === 'v4' ? v4 : editFamily === 'v6' ? v6 : null;

  return (
    <>
      {successMsg && (
        <Grid>
          <Column lg={16} md={8} sm={4}>
            <InlineNotification
              kind="success"
              title={successMsg}
              onCloseButtonClick={() => setSuccessMsg(null)}
              className="dns__notification"
              data-testid="vpn-dns-notification"
            />
          </Column>
        </Grid>
      )}

      <Grid>
        {/* IPv4 card */}
        <Column lg={8} md={4} sm={4}>
          <Tile className="dns__tile" data-testid="vpn-dns-card-v4">
            <div className="dns__tile-header">
              <p className="dns__tile-title">IPv4</p>
              <div className="dns__tile-actions">
                <Button
                  renderIcon={Renew}
                  size="sm"
                  kind="ghost"
                  iconDescription={t.dns.refresh}
                  hasIconOnly
                  onClick={() => void fetchDns()}
                  disabled={loading}
                  data-testid="vpn-dns-refresh-v4"
                />
                {canOperate && (
                  <Button
                    renderIcon={Edit}
                    size="sm"
                    kind="ghost"
                    iconDescription={t.dns.edit}
                    hasIconOnly
                    onClick={() => setEditFamily('v4')}
                    data-testid="vpn-dns-edit-v4"
                  />
                )}
              </div>
            </div>
            <div className="dns__kv-grid">
              <div className="dns__kv">
                <span className="dns__kv-label">{t.dns.primary}</span>
                <span className="dns__kv-value" data-testid="vpn-dns-v4-primary">
                  {v4?.primary || '—'}
                </span>
              </div>
              <div className="dns__kv">
                <span className="dns__kv-label">{t.dns.secondary}</span>
                <span className="dns__kv-value" data-testid="vpn-dns-v4-secondary">
                  {v4?.secondary || '—'}
                </span>
              </div>
            </div>
          </Tile>
        </Column>

        {/* IPv6 card */}
        <Column lg={8} md={4} sm={4}>
          <Tile className="dns__tile" data-testid="vpn-dns-card-v6">
            <div className="dns__tile-header">
              <p className="dns__tile-title">IPv6</p>
              <div className="dns__tile-actions">
                <Button
                  renderIcon={Renew}
                  size="sm"
                  kind="ghost"
                  iconDescription={t.dns.refresh}
                  hasIconOnly
                  onClick={() => void fetchDns()}
                  disabled={loading}
                  data-testid="vpn-dns-refresh-v6"
                />
                {canOperate && (
                  <Button
                    renderIcon={Edit}
                    size="sm"
                    kind="ghost"
                    iconDescription={t.dns.edit}
                    hasIconOnly
                    onClick={() => setEditFamily('v6')}
                    data-testid="vpn-dns-edit-v6"
                  />
                )}
              </div>
            </div>
            <div className="dns__kv-grid">
              <div className="dns__kv">
                <span className="dns__kv-label">{t.dns.primary}</span>
                <span className="dns__kv-value" data-testid="vpn-dns-v6-primary">
                  {v6?.primary || '—'}
                </span>
              </div>
              <div className="dns__kv">
                <span className="dns__kv-label">{t.dns.secondary}</span>
                <span className="dns__kv-value" data-testid="vpn-dns-v6-secondary">
                  {v6?.secondary || '—'}
                </span>
              </div>
            </div>
          </Tile>
        </Column>
      </Grid>

      {canOperate && (
        <EditDnsModal
          family={editFamily}
          record={editRecord}
          onClose={() => setEditFamily(null)}
          onSaved={handleSaved}
        />
      )}
    </>
  );
};

export default DnsConfig;
