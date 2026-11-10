import React, { useState, useEffect } from 'react';
import { Modal, CodeSnippet } from '@carbon/react';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import { apiClient } from '@shared/api/client';

interface RawTableModalProps {
  open: boolean;
  onClose: () => void;
}

const RawTableModal: React.FC<RawTableModalProps> = ({ open, onClose }) => {
  const { locale } = useLocale();
  const t = translate(locale);

  const [tableData, setTableData] = useState<Record<string, unknown> | null>(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (!open) {
      setTableData(null);
      return;
    }

    const fetchTable = async () => {
      setLoading(true);
      const res = await apiClient.get<Record<string, unknown>>('/api/core/firewall/table');
      if (res.ok) setTableData(res.data);
      setLoading(false);
    };

    void fetchTable();
  }, [open]);

  return (
    <Modal
      open={open}
      modalHeading={t.firewall.rawTable}
      primaryButtonText={t.firewall.close}
      onRequestClose={onClose}
      onRequestSubmit={onClose}
      size="lg"
      className="firewall__modal"
      data-testid="vpn-fw-raw-modal"
    >
      {loading ? (
        <p className="firewall__loading">{t.firewall.loading}</p>
      ) : (
        <CodeSnippet type="multi" align="bottom-end" data-testid="vpn-fw-raw-snippet">
          {tableData ? JSON.stringify(tableData, null, 2) : '{}'}
        </CodeSnippet>
      )}
    </Modal>
  );
};

export default RawTableModal;
