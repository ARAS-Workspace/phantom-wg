import React, { useState } from 'react';
import {
  DataTable,
  Table,
  TableHead,
  TableRow,
  TableHeader,
  TableBody,
  TableCell,
  TableContainer,
  TableToolbar,
  TableToolbarContent,
  Button,
  Tag,
  OverflowMenu,
  OverflowMenuItem,
  InlineNotification,
  Grid,
  Column,
} from '@carbon/react';
import { Add } from '@carbon/icons-react';
import { useUser, type UserInfo } from '@shared/contexts/UserContext';
import { useApi, useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import { formatDateTime } from '@shared/utils/dateUtils';
import TableLoader from '@shared/components/data/TableLoader';
import CreateUserModal from './modals/CreateUserModal';
import ChangePasswordModal from './modals/ChangePasswordModal';
import DeleteUserModal from './modals/DeleteUserModal';
import DisableTotpModal from './modals/DisableTotpModal';
import './styles/UserManagement.scss';

// ── Types ─────────────────────────────────────────────────────────

type ActiveAction =
  | { type: 'create' }
  | { type: 'password'; username: string }
  | { type: 'delete'; username: string }
  | { type: 'disable-totp'; username: string }
  | null;

// ── Component ─────────────────────────────────────────────────────

const UserManagement: React.FC = () => {
  const { user, mutateUser } = useUser();
  const { locale } = useLocale();
  const t = translate(locale);

  const { data: usersData, loading, refetch: refetchUsers } = useApi<UserInfo[]>('/auth/users');
  const users = usersData ?? [];

  const [notification, setNotification] = useState<{
    kind: 'success' | 'error';
    text: string;
  } | null>(null);
  const [action, setAction] = useState<ActiveAction>(null);

  const closeAction = () => setAction(null);

  const handleSuccess = (text: string, shouldRefetch = true) => {
    setAction(null);
    setNotification({ kind: 'success', text });
    if (shouldRefetch) void refetchUsers();
  };

  const handleDisableTotpSuccess = async (username: string) => {
    setAction(null);
    setNotification({ kind: 'success', text: t.settings.account.totp.disableSuccess });
    if (user?.username === username) await mutateUser();
    void refetchUsers();
  };

  // ── Table data ────────────────────────────────────────────────

  const headers = [
    { key: 'username', header: t.settings.users.username },
    { key: 'role', header: t.settings.users.role },
    { key: 'totp_enabled', header: t.settings.users.totpStatus },
    { key: 'created_at', header: t.settings.users.createdAt },
    { key: 'actions', header: '' },
  ];

  const rows = users.map((u) => ({
    id: u.id,
    username: u.username,
    role: u.role,
    totp_enabled: u.totp_enabled,
    created_at: u.created_at,
    actions: u.username,
  }));

  // ── Render ────────────────────────────────────────────────────

  return (
    <Grid className="um" narrow>
      {/* ── Modals ── */}
      <CreateUserModal
        open={action?.type === 'create'}
        t={t}
        onClose={closeAction}
        onSuccess={() => handleSuccess(t.settings.users.createSuccess)}
      />
      <ChangePasswordModal
        open={action?.type === 'password'}
        username={action?.type === 'password' ? action.username : ''}
        t={t}
        onClose={closeAction}
        onSuccess={() => handleSuccess(t.settings.users.passwordChangeSuccess, false)}
      />
      <DeleteUserModal
        open={action?.type === 'delete'}
        username={action?.type === 'delete' ? action.username : ''}
        t={t}
        onClose={closeAction}
        onSuccess={() => handleSuccess(t.settings.users.deleteSuccess)}
      />
      <DisableTotpModal
        open={action?.type === 'disable-totp'}
        username={action?.type === 'disable-totp' ? action.username : ''}
        isSelf={action?.type === 'disable-totp' ? user?.username === action.username : false}
        t={t}
        onClose={closeAction}
        onSuccess={() =>
          action?.type === 'disable-totp' && handleDisableTotpSuccess(action.username)
        }
      />

      {/* ── Notification ── */}
      {notification && (
        <Column lg={16} md={8} sm={4}>
          <InlineNotification
            kind={notification.kind}
            title={notification.text}
            onCloseButtonClick={() => setNotification(null)}
            lowContrast
            className="um__notification"
            data-testid="um-notification"
          />
        </Column>
      )}

      {/* ── Users Table ── */}
      <Column lg={16} md={8} sm={4}>
      {loading && users.length === 0 ? (
        <TableLoader columnCount={5} rowCount={5} />
      ) : (
      <DataTable rows={rows} headers={headers}>
        {({
          rows: tableRows,
          headers: tableHeaders,
          getHeaderProps,
          getRowProps,
          getTableProps,
          getTableContainerProps,
        }) => (
          <TableContainer {...getTableContainerProps()}>
            <TableToolbar>
              <TableToolbarContent>
                <Button
                  renderIcon={Add}
                  size="sm"
                  kind="primary"
                  onClick={() => setAction({ type: 'create' })}
                  data-testid="um-add-user"
                >
                  {t.settings.users.addUser}
                </Button>
              </TableToolbarContent>
            </TableToolbar>
            <Table {...getTableProps()} size="lg" data-testid="um-table">
              <TableHead>
                <TableRow>
                  {tableHeaders.map((header) => {
                    const { key: _key, ...headerProps } = getHeaderProps({ header });
                    return (
                      <TableHeader key={header.key} {...headerProps}>
                        {header.header}
                      </TableHeader>
                    );
                  })}
                </TableRow>
              </TableHead>
              <TableBody>
                {tableRows.map((row) => {
                  const { key: _key, ...rowProps } = getRowProps({ row });
                  const rowUsername = row.cells.find((c) => c.id.split(':')[1] === 'username')?.value as string;
                  return (
                    <TableRow key={row.id} {...rowProps} data-testid={`um-row-${rowUsername}`}>
                      {row.cells.map((cell) => {
                        const ck = cell.id.split(':')[1];
                        if (ck === 'role') {
                          const role = cell.value as string;
                          return (
                            <TableCell key={cell.id}>
                              <Tag type={role === 'superadmin' ? 'purple' : 'blue'} size="sm">
                                {role === 'superadmin'
                                  ? t.settings.users.superadmin
                                  : t.settings.users.admin}
                              </Tag>
                            </TableCell>
                          );
                        }
                        if (ck === 'totp_enabled') {
                          return (
                            <TableCell key={cell.id}>
                              <Tag type={cell.value ? 'green' : 'cool-gray'} size="sm">
                                {cell.value
                                  ? t.settings.account.totp.enabled
                                  : t.settings.account.totp.disabled}
                              </Tag>
                            </TableCell>
                          );
                        }
                        if (ck === 'created_at')
                          return (
                            <TableCell key={cell.id}>
                              {formatDateTime(cell.value as string)}
                            </TableCell>
                          );
                        if (ck === 'actions') {
                          const username = cell.value as string;
                          const isSelf = user?.username === username;
                          const target = users.find((u) => u.username === username);
                          const isSA = target?.role === 'superadmin';
                          const hasTotp = target?.totp_enabled;
                          return (
                            <TableCell key={cell.id}>
                              <OverflowMenu size="sm" flipped data-testid={`um-overflow-${username}`}>
                                <OverflowMenuItem
                                  itemText={t.settings.users.changePassword}
                                  onClick={() => setAction({ type: 'password', username })}
                                  data-testid={`um-action-password-${username}`}
                                />
                                <OverflowMenuItem
                                  itemText={t.settings.account.totp.disable}
                                  disabled={!hasTotp}
                                  onClick={() => setAction({ type: 'disable-totp', username })}
                                  data-testid={`um-action-disable-totp-${username}`}
                                />
                                <OverflowMenuItem
                                  itemText={t.settings.users.deleteUser}
                                  isDelete
                                  disabled={isSelf || isSA}
                                  onClick={() => setAction({ type: 'delete', username })}
                                  data-testid={`um-action-delete-${username}`}
                                />
                              </OverflowMenu>
                            </TableCell>
                          );
                        }
                        if (ck === 'username') {
                          const username = cell.value as string;
                          const isSelf = user?.username === username;
                          return (
                            <TableCell key={cell.id}>
                              {username}
                              {isSelf && (
                                <Tag type="blue" size="sm" style={{ marginLeft: '0.5rem' }}>
                                  {t.settings.users.you}
                                </Tag>
                              )}
                            </TableCell>
                          );
                        }
                        return <TableCell key={cell.id}>{cell.value}</TableCell>;
                      })}
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </TableContainer>
        )}
      </DataTable>
      )}
      </Column>
    </Grid>
  );
};

export default UserManagement;
