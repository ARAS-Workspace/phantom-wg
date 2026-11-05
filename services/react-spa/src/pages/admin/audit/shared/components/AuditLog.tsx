import React, { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import {
  Grid,
  Column,
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
  TableToolbarSearch,
  Pagination,
  Tag,
  Popover,
  PopoverContent,
  Select,
  SelectItem,
  OverflowMenu,
  OverflowMenuItem,
} from '@carbon/react';
import { Filter, FilterRemove } from '@carbon/icons-react';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import { apiClient } from '@shared/api/client';
import { formatDateTime } from '@shared/utils/dateUtils';
import TableLoader from '@shared/components/data/TableLoader';
import AuditDetailModal from './modals/AuditDetailModal';
import './styles/AuditLog.scss';

// ── Constants ─────────────────────────────────────────────────────

type TagType = 'green' | 'red' | 'warm-gray' | 'blue' | 'cool-gray' | 'teal';
type SortDir = 'ASC' | 'DESC';

const AUDIT_ACTIONS = [
  'login_success',
  'login_failed',
  'login_rate_limited',
  'mfa_challenge',
  'mfa_success',
  'mfa_failed',
  'backup_code_failed',
  'backup_code_used',
  'totp_setup_started',
  'totp_enabled',
  'totp_disabled',
  'logout',
  'password_change_started',
  'password_changed',
  'user_created',
  'user_deleted',
  'proxy_request',
] as const;

const ACTION_TAG: Record<string, TagType> = {
  login_success: 'green',
  mfa_success: 'green',
  backup_code_used: 'green',
  totp_enabled: 'green',
  user_created: 'green',
  login_failed: 'red',
  mfa_failed: 'red',
  backup_code_failed: 'red',
  login_rate_limited: 'red',
  user_deleted: 'red',
  totp_disabled: 'warm-gray',
  password_changed: 'warm-gray',
  password_change_started: 'blue',
  mfa_challenge: 'blue',
  totp_setup_started: 'blue',
  logout: 'cool-gray',
  proxy_request: 'teal',
};

const COLUMN_COUNT = 6;
const DEFAULT_LIMIT = 25;
const SEARCH_DEBOUNCE_MS = 400;

// ── Types ─────────────────────────────────────────────────────────

interface AuditEntry {
  id: number;
  user_id: string | null;
  username: string | null;
  action: string;
  detail: Record<string, unknown>;
  ip_address: string;
  timestamp: string;
}

interface AuditPage {
  items: AuditEntry[];
  total: number;
  page: number;
  limit: number;
  pages: number;
  order: string;
  sort_by: string;
}

// ── Helpers ───────────────────────────────────────────────────────

const formatDetail = (detail: Record<string, unknown>): string => {
  const entries = Object.entries(detail);
  if (entries.length === 0) return '—';
  return entries.map(([k, v]) => `${k}: ${v}`).join('  ·  ');
};

// ── Component ─────────────────────────────────────────────────────

const AuditLog: React.FC = () => {
  const { locale } = useLocale();
  const t = translate(locale);

  // ── Server state ──────────────────────────────────────────────
  const [data, setData] = useState<AuditPage | null>(null);
  const [loading, setLoading] = useState(true);
  const [page, setPage] = useState(1);
  const [limit, setLimit] = useState(DEFAULT_LIMIT);
  const [sortDir, setSortDir] = useState<SortDir>('DESC');

  // ── Filter state ──────────────────────────────────────────────
  const [actionFilter, setActionFilter] = useState('');
  const [usernameFilter, setUsernameFilter] = useState('');
  const [actionPopoverOpen, setActionPopoverOpen] = useState(false);

  // ── Modal state ─────────────────────────────────────────────
  const [selectedEntry, setSelectedEntry] = useState<AuditEntry | null>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const popoverRef = useRef<HTMLDivElement>(null);

  // Close popover on outside click
  useEffect(() => {
    if (!actionPopoverOpen) return;
    const handleOutside = (e: MouseEvent) => {
      if (popoverRef.current && !popoverRef.current.contains(e.target as Node)) {
        setActionPopoverOpen(false);
      }
    };
    document.addEventListener('mousedown', handleOutside);
    return () => document.removeEventListener('mousedown', handleOutside);
  }, [actionPopoverOpen]);

  // ── Fetch ─────────────────────────────────────────────────────
  const fetchLogs = useCallback(
    async (p: number, l: number, action: string, username: string, order: SortDir) => {
      setLoading(true);
      const params = new URLSearchParams();
      params.set('page', String(p));
      params.set('limit', String(l));
      params.set('order', order.toLowerCase());
      params.set('sort_by', 'timestamp');
      if (action) params.set('action', action);
      if (username) params.set('username', username);

      const res = await apiClient.get<AuditPage>(`/auth/audit?${params.toString()}`);
      if (res.ok) setData(res.data);
      setLoading(false);
    },
    []
  );

  useEffect(() => {
    void fetchLogs(page, limit, actionFilter, usernameFilter, sortDir);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [page, limit, actionFilter, sortDir, fetchLogs]);

  // ── Handlers ──────────────────────────────────────────────────

  const handleUsernameSearch = (e: React.ChangeEvent<HTMLInputElement> | string) => {
    const value = typeof e === 'string' ? e : e.target.value;
    setUsernameFilter(value);
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => {
      setPage(1);
      void fetchLogs(1, limit, actionFilter, value, sortDir);
    }, SEARCH_DEBOUNCE_MS);
  };

  const handleActionSelect = (e: React.ChangeEvent<HTMLSelectElement>) => {
    const val = e.target.value;
    setActionFilter(val);
    setActionPopoverOpen(false);
    setPage(1);
    void fetchLogs(1, limit, val, usernameFilter, sortDir);
  };

  const handlePaginationChange = ({
    page: p,
    pageSize: ps,
  }: {
    page: number;
    pageSize: number;
  }) => {
    setPage(p);
    setLimit(ps);
  };

  const toggleSort = () => {
    const next: SortDir = sortDir === 'DESC' ? 'ASC' : 'DESC';
    setSortDir(next);
    setPage(1);
  };

  // ── Table rows ────────────────────────────────────────────────
  const entries = data?.items ?? [];

  const entryMap = useMemo(
    () => new Map(entries.map((e) => [String(e.id), e])),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [data]
  );

  const tableRows = useMemo(
    () =>
      entries.map((entry) => ({
        id: String(entry.id),
        timestamp: formatDateTime(entry.timestamp, { seconds: true }),
        username: entry.username ?? '—',
        action: entry.action,
        detail: formatDetail(entry.detail),
        ip_address: entry.ip_address || '—',
      })),
    [entries]
  );

  const headers = [
    { key: 'timestamp', header: t.audit.timestamp },
    { key: 'username', header: t.audit.username },
    { key: 'action', header: t.audit.action },
    { key: 'detail', header: t.audit.detail },
    { key: 'ip_address', header: t.audit.ipAddress },
  ];

  // ── Render ────────────────────────────────────────────────────
  if (loading && !data) {
    return (
      <Grid>
        <Column lg={16} md={8} sm={4}>
          <TableLoader columnCount={COLUMN_COUNT} rowCount={10} showToolbar />
        </Column>
      </Grid>
    );
  }

  return (
    <Grid>
      <Column lg={16} md={8} sm={4}>
        <AuditDetailModal
          open={selectedEntry !== null}
          entry={selectedEntry}
          t={t}
          actionTagType={ACTION_TAG[selectedEntry?.action ?? ''] ?? 'cool-gray'}
          onClose={() => setSelectedEntry(null)}
        />
        <div className="audit-log">
          <DataTable rows={tableRows} headers={headers}>
            {({
              rows,
              headers: tableHeaders,
              getTableProps,
              getHeaderProps,
              getRowProps,
              getTableContainerProps,
            }) => (
              <TableContainer {...getTableContainerProps()}>
                {/* ── Toolbar ── */}
                <TableToolbar>
                  <TableToolbarContent>
                    <TableToolbarSearch
                      persistent
                      placeholder={t.audit.filterUsername}
                      value={usernameFilter}
                      onChange={handleUsernameSearch}
                    />
                  </TableToolbarContent>
                </TableToolbar>

                {/* ── Table ── */}
                {loading ? (
                  <TableLoader
                    columnCount={COLUMN_COUNT}
                    rowCount={Math.min(limit, 10)}
                    showToolbar={false}
                    showHeader={false}
                  />
                ) : (
                  <Table {...getTableProps()} size="md" data-testid="audit-table">
                    <TableHead>
                      <TableRow>
                        {tableHeaders.map((header) => {
                          const { key: _key, ...hProps } = getHeaderProps({ header });
                          const isTs = header.key === 'timestamp';
                          const isAction = header.key === 'action';

                          if (isAction) {
                            return (
                              <TableHeader
                                key={header.key}
                                {...hProps}
                                className="audit-log__action-header"
                              >
                                <span>{header.header}</span>
                                <div ref={popoverRef} className="audit-log__action-popover-anchor">
                                  <button
                                    type="button"
                                    className={`audit-log__filter-btn${actionFilter ? ' audit-log__filter-btn--active' : ''}`}
                                    onClick={() => setActionPopoverOpen((o) => !o)}
                                    title={t.audit.action}
                                  >
                                    {actionFilter ? (
                                      <FilterRemove size={14} />
                                    ) : (
                                      <Filter size={14} />
                                    )}
                                  </button>
                                  <Popover
                                    open={actionPopoverOpen}
                                    align="bottom-left"
                                    caret={false}
                                  >
                                    <PopoverContent className="audit-log__action-popover-content">
                                      <Select
                                        id="audit-action-popover-select"
                                        labelText=""
                                        hideLabel
                                        size="sm"
                                        value={actionFilter}
                                        onChange={handleActionSelect}
                                      >
                                        <SelectItem value="" text={t.audit.allActions} />
                                        {AUDIT_ACTIONS.map((a) => (
                                          <SelectItem key={a} value={a} text={a} />
                                        ))}
                                      </Select>
                                    </PopoverContent>
                                  </Popover>
                                </div>
                              </TableHeader>
                            );
                          }

                          return (
                            <TableHeader
                              key={header.key}
                              {...hProps}
                              isSortable={isTs}
                              sortDirection={isTs ? sortDir : 'NONE'}
                              onClick={isTs ? toggleSort : undefined}
                            >
                              {header.header}
                            </TableHeader>
                          );
                        })}
                        <TableHeader key="actions-header" />
                      </TableRow>
                    </TableHead>
                    <TableBody>
                      {rows.length === 0 ? (
                        <TableRow>
                          <TableCell colSpan={COLUMN_COUNT}>
                            <p className="audit-log__empty">{t.audit.noResults}</p>
                          </TableCell>
                        </TableRow>
                      ) : (
                        rows.map((row) => {
                          const { key: _key, ...rProps } = getRowProps({ row });
                          return (
                            <TableRow key={row.id} {...rProps}>
                              {row.cells.map((cell) => {
                                const ck = cell.id.split(':')[1];

                                if (ck === 'action') {
                                  const action = cell.value as string;
                                  return (
                                    <TableCell key={cell.id}>
                                      <Tag type={ACTION_TAG[action] ?? 'cool-gray'} size="sm">
                                        {action}
                                      </Tag>
                                    </TableCell>
                                  );
                                }

                                if (ck === 'detail') {
                                  return (
                                    <TableCell key={cell.id}>
                                      <span
                                        className="audit-log__detail"
                                        title={cell.value as string}
                                      >
                                        {cell.value as string}
                                      </span>
                                    </TableCell>
                                  );
                                }

                                return <TableCell key={cell.id}>{cell.value as string}</TableCell>;
                              })}
                              <TableCell key={`${row.id}-actions`}>
                                <OverflowMenu size="sm" flipped data-testid={`audit-overflow-${row.id}`}>
                                  <OverflowMenuItem
                                    itemText={t.audit.showDetail}
                                    onClick={() => {
                                      const entry = entryMap.get(row.id);
                                      if (entry) setSelectedEntry(entry);
                                    }}
                                    data-testid={`audit-show-detail-${row.id}`}
                                  />
                                </OverflowMenu>
                              </TableCell>
                            </TableRow>
                          );
                        })
                      )}
                    </TableBody>
                  </Table>
                )}

                {/* ── Pagination — localized ── */}
                <Pagination
                  totalItems={data?.total ?? 0}
                  pageSize={limit}
                  page={page}
                  pageSizes={[10, 25, 50, 100]}
                  backwardText={t.pagination.backwardText}
                  forwardText={t.pagination.forwardText}
                  itemsPerPageText={t.pagination.itemsPerPageText}
                  itemRangeText={(min, max, total) =>
                    `${min}–${max} ${t.pagination.ofText} ${total} ${t.pagination.itemsText}`
                  }
                  pageRangeText={(current, total) =>
                    `${current} ${t.pagination.ofText} ${total} ${t.pagination.pagesText}`
                  }
                  onChange={handlePaginationChange}
                />
              </TableContainer>
            )}
          </DataTable>
        </div>
      </Column>
    </Grid>
  );
};

export default AuditLog;
