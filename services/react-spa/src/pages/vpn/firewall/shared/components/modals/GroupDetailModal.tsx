import React, { useState, useEffect } from 'react';
import { Modal, CodeSnippet } from '@carbon/react';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import { apiClient } from '@shared/api/client';

// ── Types ─────────────────────────────────────────────────────────

interface GroupRecord {
  id: number;
  name: string;
  group_type: string;
  enabled: boolean;
  priority: number;
  metadata: Record<string, unknown>;
  created_at: number;
  updated_at: number;
}

interface FirewallRuleRecord {
  id: number;
  group_id: number;
  chain: string;
  action: string;
  family: number;
  proto: string;
  dport: number;
  source: string;
  destination: string;
  in_iface: string;
  out_iface: string;
  state_match: string;
  comment: string;
  position: number;
  applied: boolean;
  nft_handle: number;
  created_at: number;
}

interface RoutingRuleRecord {
  id: number;
  group_id: number;
  rule_type: string;
  from_network: string;
  to_network: string;
  table_name: string;
  table_id: number;
  priority: number;
  destination: string;
  device: string;
  applied: boolean;
  created_at: number;
}

interface GroupDetailModalProps {
  groupName: string | null;
  onClose: () => void;
}

// ── Component ─────────────────────────────────────────────────────

const GroupDetailModal: React.FC<GroupDetailModalProps> = ({ groupName, onClose }) => {
  const { locale } = useLocale();
  const t = translate(locale);

  const [group, setGroup] = useState<GroupRecord | null>(null);
  const [rules, setRules] = useState<FirewallRuleRecord[]>([]);
  const [routing, setRouting] = useState<RoutingRuleRecord[]>([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (!groupName) {
      setGroup(null);
      setRules([]);
      setRouting([]);
      return;
    }

    const fetchDetail = async () => {
      setLoading(true);

      const [groupRes, rulesRes, routingRes] = await Promise.all([
        apiClient.post<GroupRecord>('/api/core/firewall/groups/get', { name: groupName }),
        apiClient.post<FirewallRuleRecord[]>('/api/core/firewall/rules/list', { group: groupName }),
        apiClient.post<RoutingRuleRecord[]>('/api/core/firewall/routing/list', { group: groupName }),
      ]);

      if (groupRes.ok) setGroup(groupRes.data);
      if (rulesRes.ok) setRules(rulesRes.data);
      if (routingRes.ok) setRouting(routingRes.data);

      setLoading(false);
    };

    void fetchDetail();
  }, [groupName]);

  const formatJson = (data: unknown): string => JSON.stringify(data, null, 2);

  return (
    <Modal
      open={!!groupName}
      modalHeading={groupName ? `${t.firewall.groupDetails}: ${groupName}` : ''}
      primaryButtonText={t.firewall.close}
      onRequestClose={onClose}
      onRequestSubmit={onClose}
      size="lg"
      className="firewall__modal"
      data-testid="vpn-fw-detail-modal"
    >
      {loading ? (
        <p className="firewall__loading">{t.firewall.loading}</p>
      ) : (
        <div className="firewall__detail-sections">
          {group && (
            <div className="firewall__detail-section">
              <h5 className="firewall__detail-heading">{t.firewall.group}</h5>
              <CodeSnippet type="multi" align="bottom-end" data-testid="vpn-fw-detail-group">
                {formatJson(group)}
              </CodeSnippet>
            </div>
          )}

          <div className="firewall__detail-section">
            <h5 className="firewall__detail-heading">
              {t.firewall.rules} ({rules.length})
            </h5>
            <CodeSnippet type="multi" align="bottom-end" data-testid="vpn-fw-detail-rules">
              {rules.length > 0 ? formatJson(rules) : '[]'}
            </CodeSnippet>
          </div>

          <div className="firewall__detail-section">
            <h5 className="firewall__detail-heading">
              {t.firewall.routing} ({routing.length})
            </h5>
            <CodeSnippet type="multi" align="bottom-end" data-testid="vpn-fw-detail-routing">
              {routing.length > 0 ? formatJson(routing) : '[]'}
            </CodeSnippet>
          </div>
        </div>
      )}
    </Modal>
  );
};

export default GroupDetailModal;
