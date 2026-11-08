import React, { useState, useEffect } from 'react';
import { Modal, Grid, Column, TextArea, InlineLoading } from '@carbon/react';
import FormError from '@shared/components/forms/FormError';
import { apiClient } from '@shared/api/client';
import { translate } from '@shared/translations';
import { validateExitConfig } from '../../utils/exitConfig';
import { formatExitConfigIssues } from '../../utils/exitConfigMessages';

type Phase = 'loading' | 'ready' | 'failed';

interface Props {
  open: boolean;
  exitName: string;
  t: ReturnType<typeof translate>;
  onClose: () => void;
  onSuccess: () => void;
}

const EditExitModal: React.FC<Props> = ({ open, exitName, t, onClose, onSuccess }) => {
  const [phase, setPhase] = useState<Phase>('loading');
  const [config, setConfig] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [details, setDetails] = useState<string[]>([]);

  const canSubmit = phase === 'ready' && config.trim().length > 0 && !saving;

  const apiError = (code: string | undefined) =>
    (t.daemon_api_codes as Record<string, string>)[code ?? ''] ?? t.settings.error.generic;

  // The stored config is read each time the modal opens. Saving stays off
  // until it arrives, so an empty editor never replaces a stored config.
  useEffect(() => {
    if (!open || !exitName) return;
    let cancelled = false;
    setPhase('loading');
    setConfig('');
    setSaving(false);
    setError(null);
    setDetails([]);

    void (async () => {
      const res = await apiClient.post<string>('/api/multihop/config', { name: exitName });
      if (cancelled) return;
      if (res.ok) {
        setConfig(res.data);
        setPhase('ready');
      } else {
        setError(apiError(res.code));
        setPhase('failed');
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [open, exitName]);

  const handleSubmit = async () => {
    if (!canSubmit) return;

    // Validated as sent: the daemon parses the same trimmed text.
    const payload = config.trim();
    const issues = validateExitConfig(payload);
    if (issues.length > 0) {
      setError(t.multihop.validation.title);
      setDetails(formatExitConfigIssues(issues, t));
      return;
    }

    setSaving(true);
    setError(null);
    setDetails([]);

    const res = await apiClient.post<unknown>('/api/multihop/update', {
      name: exitName,
      config: payload,
    });

    setSaving(false);

    if (res.ok) {
      onSuccess();
    } else {
      setError(apiError(res.code));
    }
  };

  return (
    <Modal
      open={open}
      modalHeading={`${t.multihop.editExit}: ${exitName}`}
      primaryButtonText={saving ? t.multihop.saving : t.multihop.save}
      secondaryButtonText={t.multihop.cancel}
      primaryButtonDisabled={!canSubmit}
      onRequestClose={onClose}
      onRequestSubmit={handleSubmit}
      className="multihop__modal"
      size="md"
      data-testid="vpn-mh-edit-modal"
    >
      <Grid>
        <Column lg={16} md={8} sm={4}>
          <FormError error={error} details={details} className="multihop__modal-error" />

          {phase === 'loading' && <InlineLoading description={t.loadingSpinner.loading} />}

          {phase === 'ready' && (
            <TextArea
              id="edit-exit-config"
              labelText={t.multihop.config}
              helperText={t.multihop.editHelperText}
              value={config}
              onChange={(e) => setConfig(e.target.value)}
              rows={12}
              className="multihop__config-input"
              data-testid="vpn-mh-edit-config"
            />
          )}
        </Column>
      </Grid>
    </Modal>
  );
};

export default EditExitModal;
