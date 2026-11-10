import React, { useState } from 'react';
import { Modal, Grid, Column, Stack, PasswordInput } from '@carbon/react';
import FormError from '@shared/components/forms/FormError';
import { apiClient } from '@shared/api/client';
import { translate } from '@shared/translations';

interface Props {
  open: boolean;
  username: string;
  isSelf: boolean;
  t: ReturnType<typeof translate>;
  onClose: () => void;
  onSuccess: () => void;
}

const DisableTotpModal: React.FC<Props> = ({ open, username, isSelf, t, onClose, onSuccess }) => {
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const reset = () => {
    setPassword('');
    setError(null);
  };

  const handleClose = () => {
    reset();
    onClose();
  };

  const handleSubmit = async () => {
    setLoading(true);
    setError(null);
    const res = await apiClient.post<{ message: string }>('/auth/totp/disable', {
      password,
      ...(isSelf ? {} : { username }),
    });
    setLoading(false);
    if (res.ok) {
      reset();
      onSuccess();
    } else {
      setError(
        (t.auth_service_api_codes as Record<string, string>)[res.error_code ?? ''] ??
          t.settings.error.generic
      );
    }
  };

  return (
    <Modal
      open={open}
      danger
      modalHeading={username ? `${t.settings.account.totp.disableTitle}: ${username}` : ''}
      primaryButtonText={loading ? t.loadingSpinner.loading : t.settings.users.confirm}
      secondaryButtonText={t.settings.users.cancel}
      primaryButtonDisabled={loading || !password}
      onRequestClose={handleClose}
      onRequestSubmit={handleSubmit}
      className="um__modal"
      size="sm"
    >
      <Grid>
        <Column lg={16} md={8} sm={4}>
          <FormError error={error} className="um__modal-error" />
          <Stack gap={5}>
            <p className="um__confirm-text">{t.settings.account.totp.passwordRequired}</p>
            <PasswordInput
              id="disable-totp-pw"
              labelText={t.settings.account.totp.confirmPassword}
              tooltipAlignment="end"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoFocus
            />
          </Stack>
        </Column>
      </Grid>
    </Modal>
  );
};

export default DisableTotpModal;
