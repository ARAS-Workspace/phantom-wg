import React, { useState, useEffect } from 'react';
import { Modal, Grid, Column, TextInput, TextArea } from '@carbon/react';
import FormError from '@shared/components/forms/FormError';
import { apiClient } from '@shared/api/client';
import { translate } from '@shared/translations';
import { validateExitConfig } from '../../utils/exitConfig';
import { formatExitConfigIssues } from '../../utils/exitConfigMessages';

const NAME_PATTERN = /^[a-zA-Z0-9_-]{1,64}$/;

interface Props {
  open: boolean;
  t: ReturnType<typeof translate>;
  onClose: () => void;
  onSuccess: () => void;
}

const ImportExitModal: React.FC<Props> = ({ open, t, onClose, onSuccess }) => {
  const [name, setName] = useState('');
  const [config, setConfig] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [details, setDetails] = useState<string[]>([]);

  const nameValid = NAME_PATTERN.test(name);
  const configValid = config.trim().length > 0;
  const canSubmit = nameValid && configValid && !loading;

  // Reset state when modal opens
  useEffect(() => {
    if (open) {
      setName('');
      setConfig('');
      setError(null);
      setDetails([]);
    }
  }, [open]);

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

    setLoading(true);
    setError(null);
    setDetails([]);

    const res = await apiClient.post<unknown>('/api/multihop/import', {
      name,
      config: payload,
    });

    setLoading(false);

    if (res.ok) {
      onSuccess();
    } else {
      setError(
        (t.daemon_api_codes as Record<string, string>)[res.code ?? ''] ??
          t.settings.error.generic
      );
    }
  };

  return (
    <Modal
      open={open}
      modalHeading={t.multihop.importExit}
      primaryButtonText={loading ? t.multihop.importing : t.multihop.import}
      secondaryButtonText={t.multihop.cancel}
      primaryButtonDisabled={!canSubmit}
      onRequestClose={onClose}
      onRequestSubmit={handleSubmit}
      className="multihop__modal"
      size="md"
      data-testid="vpn-mh-import-modal"
    >
      <Grid>
        <Column lg={16} md={8} sm={4}>
          <FormError error={error} details={details} className="multihop__modal-error" />

          <TextInput
            id="import-exit-name"
            labelText={t.multihop.name}
            placeholder={t.multihop.namePlaceholder}
            helperText={t.multihop.nameHelperText}
            value={name}
            onChange={(e) => setName(e.target.value)}
            invalid={name.length > 0 && !nameValid}
            invalidText={t.multihop.nameInvalid}
            autoFocus
            data-testid="vpn-mh-import-name"
          />

          <TextArea
            id="import-exit-config"
            labelText={t.multihop.config}
            placeholder={t.multihop.configPlaceholder}
            value={config}
            onChange={(e) => setConfig(e.target.value)}
            rows={12}
            className="multihop__config-input"
            data-testid="vpn-mh-import-config"
          />
        </Column>
      </Grid>
    </Modal>
  );
};

export default ImportExitModal;
