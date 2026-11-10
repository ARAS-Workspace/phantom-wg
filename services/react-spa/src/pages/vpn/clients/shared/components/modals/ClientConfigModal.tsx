import React, { useState, useEffect } from 'react';
import {
  Modal,
  Grid,
  Column,
  Stack,
  Select,
  SelectItem,
  CodeSnippet,
  InlineLoading,
  Toggle,
} from '@carbon/react';
import { QRCodeSVG } from 'qrcode.react';
import FormError from '@shared/components/forms/FormError';
import { apiClient } from '@shared/api/client';
import { translate } from '@shared/translations';

type ConfigVersion = 'v4' | 'v6' | 'hybrid';
type Phase = 'select' | 'loading' | 'loaded';

interface Props {
  open: boolean;
  clientName: string;
  t: ReturnType<typeof translate>;
  onClose: () => void;
}

const ClientConfigModal: React.FC<Props> = ({ open, clientName, t, onClose }) => {
  const [version, setVersion] = useState<ConfigVersion>('v4');
  const [phase, setPhase] = useState<Phase>('select');
  const [config, setConfig] = useState('');
  const [showQr, setShowQr] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const reset = () => {
    setVersion('v4');
    setPhase('select');
    setConfig('');
    setShowQr(false);
    setError(null);
  };

  // Reset state after modal close animation completes (~240ms Carbon transition)
  // so primary button text doesn't flicker before modal fully disappears
  useEffect(() => {
    if (!open) {
      const timer = setTimeout(reset, 300);
      return () => clearTimeout(timer);
    }
  }, [open]);

  const handleClose = () => onClose();

  const handleGenerate = async () => {
    setPhase('loading');
    setError(null);
    const res = await apiClient.post<string>('/api/core/clients/config', {
      name: clientName,
      version,
    });
    if (res.ok) {
      try {
        setConfig(atob(res.data));
        setPhase('loaded');
      } catch {
        setError(t.settings.error.generic);
        setPhase('select');
      }
    } else {
      setError(
        (t.daemon_api_codes as Record<string, string>)[res.code ?? ''] ?? t.settings.error.generic
      );
      setPhase('select');
    }
  };

  const primaryText =
    phase === 'loading'
      ? t.loadingSpinner.loading
      : phase === 'loaded'
        ? t.settings.account.totp.close
        : t.clients.getConfig;

  const handleSubmit = () => {
    if (phase === 'select') void handleGenerate();
    else handleClose();
  };

  return (
    <Modal
      open={open}
      modalHeading={`${t.clients.configExport}: ${clientName}`}
      primaryButtonText={primaryText}
      secondaryButtonText={t.settings.users.cancel}
      primaryButtonDisabled={phase === 'loading'}
      onRequestClose={handleClose}
      onRequestSubmit={handleSubmit}
      className="clients__modal"
      size="sm"
      data-testid="vpn-cl-config-modal"
    >
      <Grid>
        <Column lg={16} md={8} sm={4}>
          <FormError error={error} className="clients__modal-error" />

          {/* Version select + loading — Stack içinde */}
          <Stack gap={5}>
            <Select
              id="config-version"
              labelText={t.clients.configVersion}
              value={version}
              disabled={phase === 'loading' || phase === 'loaded'}
              data-testid="vpn-cl-config-version"
              onChange={(e) => {
                setVersion(e.target.value as ConfigVersion);
                if (phase === 'loaded') {
                  setPhase('select');
                  setConfig('');
                  setShowQr(false);
                }
              }}
            >
              <SelectItem value="v4" text={t.clients.v4} />
              <SelectItem value="v6" text={t.clients.v6} />
              <SelectItem value="hybrid" text={t.clients.hybrid} />
            </Select>

            {phase === 'loading' && <InlineLoading description={t.loadingSpinner.loading} />}
          </Stack>

          {/* Config içeriği — Stack dışında, serbest akış */}
          {phase === 'loaded' && config && (
            <div className="clients__config-content">
              <p className="clients__config-hint">{t.clients.configHint}</p>

              <Toggle
                id="config-qr-toggle"
                labelText={t.clients.showQr}
                toggled={showQr}
                onToggle={(checked) => setShowQr(checked)}
                size="sm"
              />

              {showQr && (
                <div className="clients__qr-wrap">
                  <QRCodeSVG value={config} size={200} className="clients__qr" />
                </div>
              )}

              <CodeSnippet
                type="multi"
                align="bottom-end"
                feedback="Copied!"
                data-testid="vpn-cl-config-snippet"
              >
                {config}
              </CodeSnippet>
            </div>
          )}
        </Column>
      </Grid>
    </Modal>
  );
};

export default ClientConfigModal;
