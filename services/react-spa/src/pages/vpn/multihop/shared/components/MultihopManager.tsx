import React, { useState, useCallback, useEffect, useRef } from 'react';
import {
  Grid,
  Column,
  Tile,
  Tag,
  Button,
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
  Toggle,
  OverflowMenu,
  OverflowMenuItem,
  InlineNotification,
  StructuredListWrapper,
  StructuredListHead,
  StructuredListRow,
  StructuredListCell,
  StructuredListBody,
  SkeletonText,
} from '@carbon/react';
import { Add, Renew } from '@carbon/icons-react';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import { apiClient } from '@shared/api/client';
import { formatBytes, formatHandshake } from '@shared/utils/formatUtils';
import TableLoader from '@shared/components/data/TableLoader';
import ImportExitModal from './modals/ImportExitModal';
import EditExitModal from './modals/EditExitModal';
import './styles/MultihopManager.scss';

// ── Types ─────────────────────────────────────────────────────────

interface ExitSummary {
  id: string;
  name: string;
  endpoint: string;
  address: string;
  public_key_hex: string;
  allowed_ips: string;
  keepalive: number;
}

interface PeerStatus {
  endpoint: string;
  latest_handshake: number;
  rx_bytes: number;
  tx_bytes: number;
}

interface MultihopStatus {
  enabled: boolean;
  active: string;
  exit: ExitSummary | null;
  peer: PeerStatus | null;
}

interface ExitListResponse {
  exits: ExitSummary[];
  total: number;
  enabled: boolean;
  active: string;
}

// ── Helpers ───────────────────────────────────────────────────────

const ONLINE_THRESHOLD_SECS = 180;
const POLL_INTERVAL_MS = 1000;

type ConnectionState = 'online' | 'offline' | 'never';

const getConnectionState = (ts: number): ConnectionState => {
  if (ts === 0) return 'never';
  return Date.now() / 1000 - ts < ONLINE_THRESHOLD_SECS ? 'online' : 'offline';
};

// ── Table headers ─────────────────────────────────────────────────

const HEADERS = [
  { key: 'name', header: 'Name' },
  { key: 'endpoint', header: 'Endpoint' },
  { key: 'allowed_ips', header: 'Allowed IPs' },
  { key: 'keepalive', header: 'Keepalive' },
  { key: 'toggle', header: '' },
  { key: 'actions', header: '' },
];

// ── Component ─────────────────────────────────────────────────────

const MultihopManager: React.FC = () => {
  const { locale } = useLocale();
  const t = translate(locale);

  const [status, setStatus] = useState<MultihopStatus | null>(null);
  const [exits, setExits] = useState<ExitSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [actionLoading, setActionLoading] = useState<string | null>(null);
  const [importOpen, setImportOpen] = useState(false);
  const [editName, setEditName] = useState<string | null>(null);
  const [successMsg, setSuccessMsg] = useState<string | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);

  // ── Fetch ────────────────────────────────────────────────────

  const fetchStatus = useCallback(async () => {
    const res = await apiClient.get<MultihopStatus>('/api/multihop/status');
    if (res.ok) setStatus(res.data);
  }, []);

  const fetchAll = useCallback(async () => {
    const [statusRes, listRes] = await Promise.all([
      apiClient.get<MultihopStatus>('/api/multihop/status'),
      apiClient.get<ExitListResponse>('/api/multihop/list'),
    ]);

    if (statusRes.ok) setStatus(statusRes.data);
    if (listRes.ok) setExits(listRes.data.exits);
    setLoading(false);
  }, []);

  useEffect(() => {
    void fetchAll();
  }, [fetchAll]);

  // ── Polling — status only, while enabled ──────────────────────

  useEffect(() => {
    if (pollRef.current) {
      clearInterval(pollRef.current);
      pollRef.current = null;
    }

    if (status?.enabled) {
      pollRef.current = setInterval(() => {
        void fetchStatus();
      }, POLL_INTERVAL_MS);
    }

    return () => {
      if (pollRef.current) {
        clearInterval(pollRef.current);
        pollRef.current = null;
      }
    };
  }, [status?.enabled, fetchStatus]);

  // ── Actions ──────────────────────────────────────────────────

  const handleToggle = async (name: string, currentlyActive: boolean) => {
    setActionLoading(name);
    setErrorMsg(null);
    setSuccessMsg(null);

    if (currentlyActive) {
      const res = await apiClient.post<unknown>('/api/multihop/disable');
      if (!res.ok) {
        setErrorMsg(
          (t.daemon_api_codes as Record<string, string>)[res.code ?? ''] ??
            t.settings.error.generic
        );
      }
    } else {
      const res = await apiClient.post<unknown>('/api/multihop/enable', { name });
      if (!res.ok) {
        setErrorMsg(
          (t.daemon_api_codes as Record<string, string>)[res.code ?? ''] ??
            t.settings.error.generic
        );
      }
    }

    setActionLoading(null);
    await fetchAll();
  };

  const handleRemove = async (name: string) => {
    setActionLoading(name);
    setErrorMsg(null);
    setSuccessMsg(null);

    const res = await apiClient.post<unknown>('/api/multihop/remove', { name });

    if (res.ok) {
      setSuccessMsg(
        (t.daemon_api_codes as Record<string, string>)['EXIT_REMOVED'] ?? ''
      );
    } else {
      setErrorMsg(
        (t.daemon_api_codes as Record<string, string>)[res.code ?? ''] ??
          t.settings.error.generic
      );
    }

    setActionLoading(null);
    await fetchAll();
  };

  const handleImportSuccess = () => {
    setImportOpen(false);
    void fetchAll();
  };

  const handleEditSuccess = () => {
    setEditName(null);
    setErrorMsg(null);
    setSuccessMsg(t.multihop.updated);
    void fetchAll();
  };

  // ── Loading skeleton ─────────────────────────────────────────

  if (loading && !status) {
    return (
      <>
        <Grid>
          <Column lg={16} md={8} sm={4}>
            <Tile className="multihop__tile">
              <StructuredListWrapper isCondensed className="multihop__status-list">
                <StructuredListHead>
                  <StructuredListRow head>
                    <StructuredListCell head><SkeletonText width="40%" /></StructuredListCell>
                    <StructuredListCell head />
                  </StructuredListRow>
                </StructuredListHead>
                <StructuredListBody>
                  {Array.from({ length: 7 }, (_, i) => (
                    <StructuredListRow key={i}>
                      <StructuredListCell><SkeletonText width="60%" /></StructuredListCell>
                      <StructuredListCell><SkeletonText width="40%" /></StructuredListCell>
                    </StructuredListRow>
                  ))}
                </StructuredListBody>
              </StructuredListWrapper>
            </Tile>
          </Column>
        </Grid>
        <Grid>
          <Column lg={16} md={8} sm={4}>
            <TableLoader columnCount={6} rowCount={3} />
          </Column>
        </Grid>
      </>
    );
  }

  // ── Derive toggle states ──────────────────────────────────────

  const enabled = status?.enabled ?? false;
  const activeName = status?.active ?? '';
  const peer = status?.peer ?? null;
  const connState = peer ? getConnectionState(peer.latest_handshake) : null;
  const connTagType = connState === 'online' ? 'green' : connState === 'offline' ? 'red' : 'gray';

  const headers = HEADERS.map((h) => ({
    ...h,
    header:
      h.key === 'name' ? t.multihop.name :
      h.key === 'endpoint' ? t.multihop.endpoint :
      h.key === 'allowed_ips' ? t.multihop.allowedIps :
      h.key === 'keepalive' ? t.multihop.keepalive :
      h.header,
  }));

  const rows = exits.map((ex) => ({
    id: ex.id,
    name: ex.name,
    endpoint: ex.endpoint,
    allowed_ips: ex.allowed_ips,
    keepalive: `${ex.keepalive}s`,
    toggle: '',
    actions: '',
  }));

  return (
    <>
      {/* Notifications */}
      {successMsg && (
        <Grid>
          <Column lg={16} md={8} sm={4}>
            <InlineNotification
              kind="success"
              title={successMsg}
              onCloseButtonClick={() => setSuccessMsg(null)}
              className="multihop__notification"
              data-testid="vpn-mh-notification-success"
            />
          </Column>
        </Grid>
      )}
      {errorMsg && (
        <Grid>
          <Column lg={16} md={8} sm={4}>
            <InlineNotification
              kind="error"
              title={errorMsg}
              onCloseButtonClick={() => setErrorMsg(null)}
              className="multihop__notification"
              data-testid="vpn-mh-notification-error"
            />
          </Column>
        </Grid>
      )}

      {/* Status card */}
      <Grid>
        <Column lg={16} md={8} sm={4}>
          <Tile className="multihop__tile" data-testid="vpn-mh-status-tile">
            <StructuredListWrapper isCondensed className="multihop__status-list">
              <StructuredListHead>
                <StructuredListRow head>
                  <StructuredListCell head>{t.multihop.status}</StructuredListCell>
                  <StructuredListCell head />
                </StructuredListRow>
              </StructuredListHead>
              <StructuredListBody>
                <StructuredListRow>
                  <StructuredListCell>{t.multihop.connection}</StructuredListCell>
                  <StructuredListCell data-testid="vpn-mh-status-tag">
                    {enabled && peer ? (
                      <Tag type={connTagType} size="sm">
                        {connState === 'online' ? t.multihop.online :
                         connState === 'offline' ? t.multihop.offline :
                         t.multihop.never}
                      </Tag>
                    ) : (
                      <Tag type="gray" size="sm">{t.multihop.notConnected}</Tag>
                    )}
                  </StructuredListCell>
                </StructuredListRow>
                <StructuredListRow>
                  <StructuredListCell>{t.multihop.activeExit}</StructuredListCell>
                  <StructuredListCell data-testid="vpn-mh-active-name">
                    {enabled ? activeName : '—'}
                  </StructuredListCell>
                </StructuredListRow>
                <StructuredListRow>
                  <StructuredListCell>{t.multihop.endpoint}</StructuredListCell>
                  <StructuredListCell data-testid="vpn-mh-active-endpoint">
                    {enabled && status?.exit ? status.exit.endpoint : '—'}
                  </StructuredListCell>
                </StructuredListRow>
                <StructuredListRow>
                  <StructuredListCell>{t.multihop.address}</StructuredListCell>
                  <StructuredListCell data-testid="vpn-mh-active-address">
                    {enabled && status?.exit ? status.exit.address : '—'}
                  </StructuredListCell>
                </StructuredListRow>
                <StructuredListRow>
                  <StructuredListCell>{t.multihop.handshake}</StructuredListCell>
                  <StructuredListCell data-testid="vpn-mh-handshake">
                    {enabled && peer && peer.latest_handshake > 0
                      ? formatHandshake(peer.latest_handshake)
                      : '—'}
                  </StructuredListCell>
                </StructuredListRow>
                <StructuredListRow>
                  <StructuredListCell>{t.multihop.rx}</StructuredListCell>
                  <StructuredListCell data-testid="vpn-mh-rx">
                    {enabled && peer ? formatBytes(peer.rx_bytes) : '—'}
                  </StructuredListCell>
                </StructuredListRow>
                <StructuredListRow>
                  <StructuredListCell>{t.multihop.tx}</StructuredListCell>
                  <StructuredListCell data-testid="vpn-mh-tx">
                    {enabled && peer ? formatBytes(peer.tx_bytes) : '—'}
                  </StructuredListCell>
                </StructuredListRow>
              </StructuredListBody>
            </StructuredListWrapper>
          </Tile>
        </Column>
      </Grid>

      {/* Exits table */}
      <Grid>
        <Column lg={16} md={8} sm={4}>
          <DataTable rows={rows} headers={headers} size="lg">
            {({
              rows: tableRows,
              headers: tableHeaders,
              getTableProps,
              getHeaderProps,
              getRowProps,
            }) => (
              <TableContainer data-testid="vpn-mh-table">
                <TableToolbar>
                  <TableToolbarContent>
                    <Button
                      renderIcon={Renew}
                      kind="ghost"
                      size="sm"
                      iconDescription={t.multihop.refresh}
                      hasIconOnly
                      onClick={() => void fetchAll()}
                      data-testid="vpn-mh-refresh"
                    />
                    <Button
                      renderIcon={Add}
                      size="sm"
                      kind="primary"
                      onClick={() => setImportOpen(true)}
                      data-testid="vpn-mh-import-btn"
                    >
                      {t.multihop.importExit}
                    </Button>
                  </TableToolbarContent>
                </TableToolbar>

                <Table {...getTableProps()}>
                  <TableHead>
                    <TableRow>
                      {tableHeaders.map((header) => (
                        <TableHeader {...getHeaderProps({ header })} key={header.key}>
                          {header.header}
                        </TableHeader>
                      ))}
                    </TableRow>
                  </TableHead>
                  <TableBody>
                    {tableRows.length === 0 ? (
                      <TableRow>
                        <TableCell colSpan={headers.length}>
                          <p className="multihop__empty">{t.multihop.noExits}</p>
                        </TableCell>
                      </TableRow>
                    ) : (
                      tableRows.map((row) => {
                        const raw = exits.find((e) => e.id === row.id);
                        const exitName = raw?.name ?? '';
                        const isActive = enabled && activeName === exitName;
                        const isToggleDisabled =
                          actionLoading === exitName ||
                          (enabled && !isActive);

                        return (
                          <TableRow
                            {...getRowProps({ row })}
                            key={row.id}
                            className={isActive ? 'multihop__row--active' : ''}
                            data-testid={`vpn-mh-row-${exitName}`}
                          >
                            {row.cells.map((cell) => {
                              if (cell.info.header === 'toggle') {
                                return (
                                  <TableCell key={cell.id}>
                                    <Toggle
                                      id={`toggle-${exitName}`}
                                      size="sm"
                                      toggled={isActive}
                                      disabled={isToggleDisabled}
                                      onToggle={() => handleToggle(exitName, isActive)}
                                      labelA=""
                                      labelB=""
                                      aria-label={`${t.multihop.connection} ${exitName}`}
                                      data-testid={`vpn-mh-toggle-${exitName}`}
                                    />
                                  </TableCell>
                                );
                              }
                              if (cell.info.header === 'actions') {
                                return (
                                  <TableCell key={cell.id}>
                                    <OverflowMenu
                                      size="sm"
                                      flipped
                                      data-testid={`vpn-mh-overflow-${exitName}`}
                                    >
                                      <OverflowMenuItem
                                        itemText={t.multihop.edit}
                                        disabled={isActive}
                                        onClick={() => setEditName(exitName)}
                                        data-testid={`vpn-mh-action-edit-${exitName}`}
                                      />
                                      <OverflowMenuItem
                                        itemText={t.multihop.remove}
                                        isDelete
                                        disabled={isActive}
                                        onClick={() => handleRemove(exitName)}
                                        data-testid={`vpn-mh-action-remove-${exitName}`}
                                      />
                                    </OverflowMenu>
                                  </TableCell>
                                );
                              }
                              return (
                                <TableCell key={cell.id}>{cell.value}</TableCell>
                              );
                            })}
                          </TableRow>
                        );
                      })
                    )}
                  </TableBody>
                </Table>
              </TableContainer>
            )}
          </DataTable>
        </Column>
      </Grid>

      {/* Import modal */}
      <ImportExitModal
        open={importOpen}
        t={t}
        onClose={() => setImportOpen(false)}
        onSuccess={handleImportSuccess}
      />

      {/* Edit modal */}
      <EditExitModal
        open={editName !== null}
        exitName={editName ?? ''}
        t={t}
        onClose={() => setEditName(null)}
        onSuccess={handleEditSuccess}
      />
    </>
  );
};

export default MultihopManager;
