import React, { useState } from 'react';
import { Modal, Grid, Column, Stack, TextInput, PasswordInput, Button } from '@carbon/react';
import { Renew, Checkmark, Close } from '@carbon/icons-react';
import FormError from '@shared/components/forms/FormError';
import { apiClient } from '@shared/api/client';
import { type UserInfo } from '@shared/contexts/UserContext';
import { generatePassword, isPasswordValid, getPolicyChecks } from '@shared/utils/passwordUtils';
import { translate } from '@shared/translations';

interface Props {
  open: boolean;
  t: ReturnType<typeof translate>;
  onClose: () => void;
  onSuccess: () => void;
}

const CreateUserModal: React.FC<Props> = ({ open, t, onClose, onSuccess }) => {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const allPassed = isPasswordValid(password);
  const policyChecks = getPolicyChecks(t.passwordChange.policy);

  const reset = () => {
    setUsername('');
    setPassword('');
    setError(null);
  };

  const handleClose = () => {
    reset();
    onClose();
  };

  const handleSubmit = async () => {
    if (!allPassed || !username) return;
    setLoading(true);
    setError(null);
    const res = await apiClient.post<UserInfo>('/auth/users', { username, password });
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
      modalHeading={t.settings.users.addUserTitle}
      primaryButtonText={loading ? t.loadingSpinner.loading : t.settings.users.confirm}
      secondaryButtonText={t.settings.users.cancel}
      primaryButtonDisabled={loading || !username || !allPassed}
      onRequestClose={handleClose}
      onRequestSubmit={handleSubmit}
      className="um__modal"
      size="sm"
      data-testid="um-create-modal"
    >
      <Grid>
        <Column lg={16} md={8} sm={4}>
          <FormError error={error} className="um__modal-error" />
          <Stack gap={5}>
            <TextInput
              id="create-username"
              labelText={t.settings.users.username}
              placeholder={t.settings.users.usernamePlaceholder}
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              data-testid="um-create-username"
              autoFocus
            />
            <div>
              <div className="um__password-row">
                <PasswordInput
                  id="create-password"
                  labelText={t.settings.users.newPassword}
                  placeholder={t.settings.users.newPasswordPlaceholder}
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  data-testid="um-create-password"
                />
                <Button
                  kind="ghost"
                  size="md"
                  renderIcon={Renew}
                  hasIconOnly
                  tooltipAlignment="end"
                  iconDescription={t.settings.users.generatePassword}
                  onClick={() => setPassword(generatePassword())}
                  data-testid="um-create-generate"
                />
              </div>
              <ul className="um__checklist" data-testid="um-create-checklist">
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

export default CreateUserModal;
