import React from 'react';
import {
  Modal,
  Grid,
  Column,
  StructuredListWrapper,
  StructuredListBody,
  StructuredListRow,
  StructuredListCell,
  Tag,
  CodeSnippet,
} from '@carbon/react';
import { translate } from '@shared/translations';

// ── Types ─────────────────────────────────────────────────────────

interface AuditEntry {
  id: number;
  user_id: string | null;
  username: string | null;
  action: string;
  detail: Record<string, unknown>;
  ip_address: string;
  timestamp: string;
}

interface Props {
  open: boolean;
  entry: AuditEntry | null;
  t: ReturnType<typeof translate>;
  actionTagType: string;
  onClose: () => void;
}

// ── Component ─────────────────────────────────────────────────────

const AuditDetailModal: React.FC<Props> = ({ open, entry, t, actionTagType, onClose }) => {
  if (!entry) return null;

  const detail = entry.detail;
  const hasDetail = Object.keys(detail).length > 0;

  return (
    <Modal
      open={open}
      modalHeading={t.audit.detailTitle}
      primaryButtonText={t.settings.account.totp.close}
      onRequestClose={onClose}
      onRequestSubmit={onClose}
      className="audit-log__modal"
      size="sm"
      data-testid="audit-detail-modal"
    >
      <Grid>
        <Column lg={16} md={8} sm={4}>
          <StructuredListWrapper isCondensed>
            <StructuredListBody>
              <StructuredListRow>
                <StructuredListCell>ID</StructuredListCell>
                <StructuredListCell>{entry.id}</StructuredListCell>
              </StructuredListRow>
              <StructuredListRow>
                <StructuredListCell>{t.audit.timestamp}</StructuredListCell>
                <StructuredListCell>{entry.timestamp}</StructuredListCell>
              </StructuredListRow>
              <StructuredListRow>
                <StructuredListCell>{t.audit.username}</StructuredListCell>
                <StructuredListCell>{entry.username ?? '—'}</StructuredListCell>
              </StructuredListRow>
              <StructuredListRow>
                <StructuredListCell>{t.audit.userId}</StructuredListCell>
                <StructuredListCell>
                  <span className="audit-log__detail-mono">{entry.user_id ?? '—'}</span>
                </StructuredListCell>
              </StructuredListRow>
              <StructuredListRow>
                <StructuredListCell>{t.audit.action}</StructuredListCell>
                <StructuredListCell>
                  <Tag type={actionTagType as never} size="sm">
                    {entry.action}
                  </Tag>
                </StructuredListCell>
              </StructuredListRow>
              <StructuredListRow>
                <StructuredListCell>{t.audit.ipAddress}</StructuredListCell>
                <StructuredListCell>{entry.ip_address || '—'}</StructuredListCell>
              </StructuredListRow>
            </StructuredListBody>
          </StructuredListWrapper>

          {hasDetail && (
            <div className="audit-log__detail-section">
              <p className="audit-log__detail-label">{t.audit.detail}</p>
              <CodeSnippet type="multi" align="bottom-end" feedback="Copied">
                {JSON.stringify(detail, null, 2)}
              </CodeSnippet>
            </div>
          )}
        </Column>
      </Grid>
    </Modal>
  );
};

export default AuditDetailModal;
