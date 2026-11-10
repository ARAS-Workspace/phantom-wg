import React, { useState, useEffect, useCallback } from 'react';
import { Modal, Grid, Column, Stack, PasswordInput, InlineLoading } from '@carbon/react';
import FormError from '@shared/components/forms/FormError';
import { apiClient } from '@shared/api/client';
import { translate } from '@shared/translations';

// ── Types ─────────────────────────────────────────────────────────

interface ClientRecord {
  id: string;
  name: string;
  public_key_hex: string;
  private_key_hex: string;
  preshared_key_hex: string;
}

interface Props {
  open: boolean;
  clientName: string;
  t: ReturnType<typeof translate>;
  onClose: () => void;
}

// ── Component ─────────────────────────────────────────────────────

const ClientKeysModal: React.FC<Props> = ({ open, clientName, t, onClose }) => {
  const [detail, setDetail] = useState<ClientRecord | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchKeys = useCallback(async () => {
    if (!clientName) return;
    setLoading(true);
    setError(null);
    const res = await apiClient.post<ClientRecord>('/api/core/clients/get', { name: clientName });
    setLoading(false);
    if (res.ok) setDetail(res.data);
    else
      setError(
        (t.daemon_api_codes as Record<string, string>)[res.code ?? ''] ?? t.settings.error.generic
      );
  }, [clientName]);

  // Fetch when opened, reset after close animation
  useEffect(() => {
    if (open) {
      void fetchKeys();
    } else {
      const timer = setTimeout(() => {
        setDetail(null);
        setError(null);
      }, 300);
      return () => clearTimeout(timer);
    }
  }, [open, fetchKeys]);

  const keys = detail
    ? [
        { id: 'key-public', label: t.clients.publicKey, value: detail.public_key_hex },
        { id: 'key-private', label: t.clients.privateKey, value: detail.private_key_hex },
        { id: 'key-preshared', label: t.clients.presharedKey, value: detail.preshared_key_hex },
      ]
    : [];

  return (
    <Modal
      open={open}
      modalHeading={`${t.clients.keysTitle}: ${clientName}`}
      primaryButtonText={t.settings.account.totp.close}
      onRequestClose={onClose}
      onRequestSubmit={onClose}
      className="clients__modal"
      size="sm"
      data-testid="vpn-cl-keys-modal"
    >
      <Grid>
        <Column lg={16} md={8} sm={4}>
          <FormError error={error} className="clients__modal-error" />
          {loading && <InlineLoading description={t.loadingSpinner.loading} />}
          {!loading && detail && (
            <Stack gap={5}>
              {keys.map(({ id, label, value }) => (
                <PasswordInput
                  key={id}
                  id={id}
                  labelText={label}
                  value={value}
                  readOnly
                  hidePasswordLabel={t.clients.hideKey}
                  showPasswordLabel={t.clients.showKey}
                  tooltipAlignment="end"
                />
              ))}
            </Stack>
          )}
        </Column>
      </Grid>
    </Modal>
  );
};

export default ClientKeysModal;
