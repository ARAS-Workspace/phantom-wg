import React, { useState } from 'react';
import { Modal, Grid, Column, Stack, PasswordInput, Button } from '@carbon/react';
import { Renew, Checkmark, Close } from '@carbon/icons-react';
import FormError from '@shared/components/forms/FormError';
import { apiClient } from '@shared/api/client';
import { generatePassword, isPasswordValid, getPolicyChecks } from '@shared/utils/passwordUtils';
import { translate } from '@shared/translations';

interface Props {
  open: boolean;
  username: string;
  t: ReturnType<typeof translate>;
  onClose: () => void;
  onSuccess: () => void;
}

const ChangePasswordModal: React.FC<Props> = ({ open, username, t, onClose, onSuccess }) => {
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const allPassed = isPasswordValid(password);
  const policyChecks = getPolicyChecks(t.passwordChange.policy);

  const reset = () => {
    setPassword('');
    setError(null);
  };

  const handleClose = () => {
    reset();
    onClose();
  };

  const handleSubmit = async () => {
    if (!allPassed) return;
    setLoading(true);
    setError(null);
    const res = await apiClient.post<{ message: string }>(`/auth/users/${username}/password`, {
      password,
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
      modalHeading={username ? `${t.settings.users.changePasswordTitle}: ${username}` : ''}
      primaryButtonText={loading ? t.loadingSpinner.loading : t.settings.users.confirm}
      secondaryButtonText={t.settings.users.cancel}
      primaryButtonDisabled={loading || !allPassed}
      onRequestClose={handleClose}
      onRequestSubmit={handleSubmit}
      className="um__modal"
      size="sm"
      data-testid="um-password-modal"
    >
      <Grid>
        <Column lg={16} md={8} sm={4}>
          <FormError error={error} className="um__modal-error" />
          <Stack gap={5}>
            <div>
              <div className="um__password-row">
                <PasswordInput
                  id="change-password"
                  labelText={t.settings.users.newPassword}
                  placeholder={t.settings.users.newPasswordPlaceholder}
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  data-testid="um-password-input"
                  autoFocus
                />
                <Button
                  kind="ghost"
                  size="md"
                  renderIcon={Renew}
                  hasIconOnly
                  tooltipAlignment="end"
                  iconDescription={t.settings.users.generatePassword}
                  onClick={() => setPassword(generatePassword())}
                  data-testid="um-password-generate"
                />
              </div>
              <ul className="um__checklist" data-testid="um-password-checklist">
                {policyChecks.map((c) => {
                  const passed = c.test(password);
                  return (
                    <li key={c.key} className={`um__check ${passed ? 'um__check--pass' : ''}`}>
                      {passed ? <Checkmark size={16} /> : <Close size={16} />}
                      <span>{c.label}</span>
                    </li>
                  );
                })}
              </ul>
            </div>
          </Stack>
        </Column>
      </Grid>
    </Modal>
  );
};

export default ChangePasswordModal;
