import React, { useState, useCallback, useEffect } from 'react';
import {
  Grid,
  Column,
  Tile,
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
  Button,
  OverflowMenu,
  OverflowMenuItem,
  Pagination,
  Modal,
  StructuredListWrapper,
  StructuredListBody,
  StructuredListRow,
  StructuredListCell,
} from '@carbon/react';
import { Renew } from '@carbon/icons-react';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import { apiClient } from '@shared/api/client';
import { formatBytes, formatHandshake } from '@shared/utils/formatUtils';
import TableLoader from '@shared/components/data/TableLoader';
import PeerStatusTag from '@shared/components/data/PeerStatusTag';
import {
  getPeerStatus,
  sortPeers,
  type PeerInfo,
  type PeerSortKey,
  type SortDirection,
  type WireGuardStatusData,
} from '@shared/types/wireguard';
import './styles/WireGuardStatus.scss';

// ── Constants ─────────────────────────────────────────────────────

const COLUMN_COUNT = 7; // 6 data cols + 1 actions col
const DEFAULT_PAGE_SIZE = 25;
const PAGE_SIZES = [10, 25, 50, 100];
const SORT_KEYS: readonly string[] = ['name', 'last_handshake', 'rx', 'tx'];

// ── Helpers ───────────────────────────────────────────────────────

const isSortKey = (key: string): key is PeerSortKey => SORT_KEYS.includes(key);

const truncateKey = (key: string): string =>
  key.length > 20 ? `${key.slice(0, 8)}…${key.slice(-8)}` : key;

const peerKey = (peer: PeerInfo): string => peer.name ?? peer.public_key.slice(0, 8);

// ── Component ─────────────────────────────────────────────────────

const WireGuardStatus: React.FC = () => {
  const { locale } = useLocale();
  const t = translate(locale);

  const [data, setData] = useState<WireGuardStatusData | null>(null);
  const [loading, setLoading] = useState(true);
  const [detail, setDetail] = useState<PeerInfo | null>(null);
  const [refreshingPeer, setRefreshingPeer] = useState<string | null>(null);
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(DEFAULT_PAGE_SIZE);
  const [search, setSearch] = useState('');
  const [sort, setSort] = useState<{ key: PeerSortKey; direction: SortDirection }>({
    key: 'name',
    direction: 'ASC',
  });

  // ── Fetch ─────────────────────────────────────────────────────
  const fetchStatus = useCallback(async () => {
    setLoading(true);
    const res = await apiClient.get<WireGuardStatusData>('/api/core/wireguard');
    if (res.ok) setData(res.data);
    setLoading(false);
  }, []);

  useEffect(() => {
    void fetchStatus();
  }, [fetchStatus]);

  // ── Per-peer refresh ──────────────────────────────────────────
  const handleRefreshPeer = async (name: string) => {
    setRefreshingPeer(name);
    const res = await apiClient.post<PeerInfo>('/api/core/wireguard/peer', { name });
    if (res.ok && data) {
      setData({
        ...data,
        peers: data.peers.map((p) => (p.name === name ? res.data : p)),
      });
    }
    setRefreshingPeer(null);
  };

  const handlePaginationChange = ({
    page: p,
    pageSize: ps,
  }: {
    page: number;
    pageSize: number;
  }) => {
    setPage(p);
    setPageSize(ps);
  };

  const handleSearch = (e: React.ChangeEvent<HTMLInputElement> | string) => {
    setSearch(typeof e === 'string' ? e : e.target.value);
    setPage(1);
  };

  const handleSort = (key: PeerSortKey) => {
    setSort((prev) =>
      prev.key === key
        ? { key, direction: prev.direction === 'ASC' ? 'DESC' : 'ASC' }
        : { key, direction: 'ASC' }
    );
    setPage(1);
  };

  // ── Initial skeleton ──────────────────────────────────────────
  if (loading && !data) {
    return (
      <Grid>
        <Column lg={16} md={8} sm={4}>
          <TableLoader columnCount={COLUMN_COUNT} rowCount={8} showToolbar />
        </Column>
      </Grid>
    );
  }

  // ── Table data ────────────────────────────────────────────────
  const allPeers = data?.peers ?? [];
  const peersMap = new Map(allPeers.map((p) => [p.public_key, p]));
  const query = search.trim().toLowerCase();
  const matching = query
    ? allPeers.filter((p) => p.name !== null && p.name.toLowerCase().includes(query))
    : allPeers;
  const peers = sortPeers(matching, sort.key, sort.direction);
  const pageCount = Math.max(1, Math.ceil(peers.length / pageSize));
  const currentPage = Math.min(page, pageCount);
  const pagePeers = peers.slice((currentPage - 1) * pageSize, currentPage * pageSize);

  const headers = [
    { key: 'status', header: t.wireguard.status },
    { key: 'name', header: t.wireguard.name },
    { key: 'endpoint', header: t.wireguard.endpoint },
    { key: 'last_handshake', header: t.wireguard.lastHandshake },
    { key: 'rx', header: t.wireguard.rxBytes },
    { key: 'tx', header: t.wireguard.txBytes },
  ];

  const rows = pagePeers.map((p) => ({
    id: p.public_key,
    status: getPeerStatus(p.latest_handshake) as string,
    name: p.name ?? t.wireguard.unknown,
    endpoint: p.endpoint || '—',
    last_handshake: formatHandshake(p.latest_handshake),
    rx: formatBytes(p.rx_bytes),
    tx: formatBytes(p.tx_bytes),
  }));

  return (
    <>
      {/* Interface card */}
      <Grid>
        <Column lg={16} md={8} sm={4}>
          <Tile className="wireguard__interface" data-testid="vpn-wg-interface">
            <p className="wireguard__interface-title">{t.wireguard.interfaceTitle}</p>
            <div className="wireguard__interface-kv-grid">
              <div className="wireguard__kv">
                <span className="wireguard__kv-label">{t.wireguard.publicKey}</span>
                <span className="wireguard__kv-value">
                  {truncateKey(data?.interface.public_key ?? '')}
                </span>
              </div>
              <div className="wireguard__kv">
                <span className="wireguard__kv-label">{t.wireguard.listenPort}</span>
                <span className="wireguard__kv-value">{data?.interface.listen_port}</span>
              </div>
              <div className="wireguard__kv">
                <span className="wireguard__kv-label">{t.wireguard.fwmark}</span>
                <span className="wireguard__kv-value">{data?.interface.fwmark}</span>
              </div>
              <div className="wireguard__kv">
                <span className="wireguard__kv-label">{t.wireguard.totalPeers}</span>
                <span className="wireguard__kv-value">{data?.total_peers}</span>
              </div>
            </div>
          </Tile>
        </Column>
      </Grid>

      {/* Peers table */}
      <Grid>
        <Column lg={16} md={8} sm={4}>
          <div className="wireguard">
            <DataTable rows={rows} headers={headers}>
              {({
                rows: tableRows,
                headers: tableHeaders,
                getTableProps,
                getHeaderProps,
                getRowProps,
                getTableContainerProps,
              }) => (
                <TableContainer {...getTableContainerProps()}>
                  <TableToolbar>
                    <TableToolbarContent>
                      <TableToolbarSearch
                        persistent
                        placeholder={t.wireguard.filterName}
                        value={search}
                        onChange={handleSearch}
                        data-testid="vpn-wg-search"
                      />
                      <Button
                        renderIcon={Renew}
                        size="sm"
                        kind="primary"
                        onClick={() => void fetchStatus()}
                        disabled={loading}
                        data-testid="vpn-wg-refresh"
                      >
                        {t.wireguard.refresh}
                      </Button>
                    </TableToolbarContent>
                  </TableToolbar>

                  {loading ? (
                    <TableLoader
                      columnCount={COLUMN_COUNT}
                      rowCount={Math.min(pagePeers.length || 5, 10)}
                      showToolbar={false}
                      showHeader={false}
                    />
                  ) : (
                    <Table {...getTableProps()} size="md" data-testid="vpn-wg-table">
                      <TableHead>
                        <TableRow>
                          {tableHeaders.map((header) => {
                            const { key: _key, ...hProps } = getHeaderProps({ header });
                            const key = header.key;
                            if (!isSortKey(key)) {
                              return (
                                <TableHeader key={key} {...hProps}>
                                  {header.header}
                                </TableHeader>
                              );
                            }
                            const active = sort.key === key;
                            return (
                              <TableHeader
                                key={key}
                                {...hProps}
                                isSortable
                                isSortHeader={active}
                                sortDirection={active ? sort.direction : 'NONE'}
                                onClick={() => handleSort(key)}
                                data-testid={`vpn-wg-sort-${key}`}
                              >
                                {header.header}
                              </TableHeader>
                            );
                          })}
                          <TableHeader key="actions-header" />
                        </TableRow>
                      </TableHead>
                      <TableBody>
                        {tableRows.length === 0 ? (
                          <TableRow>
                            <TableCell colSpan={COLUMN_COUNT}>
                              <p
                                style={{
                                  padding: '1rem 0',
                                  color: 'var(--cds-text-secondary)',
                                  textAlign: 'center',
                                  margin: 0,
                                }}
                              >
                                {t.wireguard.noPeers}
                              </p>
                            </TableCell>
                          </TableRow>
                        ) : (
                          tableRows.map((row) => {
                            const { key: _key, ...rProps } = getRowProps({ row });
                            const peer = peersMap.get(row.id)!;
                            const key = peerKey(peer);
                            return (
                              <TableRow key={row.id} {...rProps} data-testid={`vpn-wg-row-${key}`}>
                                {row.cells.map((cell) => {
                                  if (cell.info.header === 'status') {
                                    return (
                                      <TableCell key={cell.id}>
                                        <PeerStatusTag latestHandshake={peer.latest_handshake} />
                                      </TableCell>
                                    );
                                  }
                                  return (
                                    <TableCell key={cell.id}>{cell.value as string}</TableCell>
                                  );
                                })}
                                <TableCell key={`${row.id}-actions`}>
                                  <OverflowMenu
                                    size="sm"
                                    flipped
                                    data-testid={`vpn-wg-overflow-${key}`}
                                  >
                                    <OverflowMenuItem
                                      itemText={t.wireguard.details}
                                      onClick={() => setDetail(peer)}
                                      data-testid={`vpn-wg-action-details-${key}`}
                                    />
                                    {peer.name && (
                                      <OverflowMenuItem
                                        itemText={
                                          refreshingPeer === peer.name
                                            ? '...'
                                            : t.wireguard.refreshPeer
                                        }
                                        disabled={refreshingPeer === peer.name}
                                        onClick={() =>
                                          peer.name && void handleRefreshPeer(peer.name)
                                        }
                                        data-testid={`vpn-wg-action-refresh-${peer.name}`}
                                      />
                                    )}
                                  </OverflowMenu>
                                </TableCell>
                              </TableRow>
                            );
                          })
                        )}
                      </TableBody>
                    </Table>
                  )}

                  {/* Localized pagination */}
                  <Pagination
                    data-testid="vpn-wg-pagination"
                    totalItems={peers.length}
                    pageSize={pageSize}
                    page={currentPage}
                    pageSizes={PAGE_SIZES}
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

      {/* Peer detail modal */}
      <Modal
        open={!!detail}
        modalHeading={t.wireguard.peerDetails}
        primaryButtonText={t.wireguard.close}
        onRequestClose={() => setDetail(null)}
        onRequestSubmit={() => setDetail(null)}
        size="sm"
        className="wireguard__modal"
        data-testid="vpn-wg-detail-modal"
      >
        {detail && (
          <Grid>
            <Column lg={16} md={8} sm={4}>
              <StructuredListWrapper isCondensed>
                <StructuredListBody>
                  <StructuredListRow>
                    <StructuredListCell>{t.wireguard.status}</StructuredListCell>
                    <StructuredListCell>
                      <PeerStatusTag latestHandshake={detail.latest_handshake} />
                    </StructuredListCell>
                  </StructuredListRow>
                  <StructuredListRow>
                    <StructuredListCell>{t.wireguard.name}</StructuredListCell>
                    <StructuredListCell>{detail.name ?? t.wireguard.unknown}</StructuredListCell>
                  </StructuredListRow>
                  <StructuredListRow>
                    <StructuredListCell>{t.wireguard.publicKey}</StructuredListCell>
                    <StructuredListCell>
                      <span className="wireguard__detail-mono">{detail.public_key}</span>
                    </StructuredListCell>
                  </StructuredListRow>
                  <StructuredListRow>
                    <StructuredListCell>{t.wireguard.endpoint}</StructuredListCell>
                    <StructuredListCell>
                      <span className="wireguard__detail-mono">{detail.endpoint || '—'}</span>
                    </StructuredListCell>
                  </StructuredListRow>
                  <StructuredListRow>
                    <StructuredListCell>{t.wireguard.allowedIps}</StructuredListCell>
                    <StructuredListCell>
                      <div className="wireguard__allowed-ips">
                        {detail.allowed_ips.length > 0
                          ? detail.allowed_ips.map((ip) => <span key={ip}>{ip}</span>)
                          : '—'}
                      </div>
                    </StructuredListCell>
                  </StructuredListRow>
                  <StructuredListRow>
                    <StructuredListCell>{t.wireguard.lastHandshake}</StructuredListCell>
                    <StructuredListCell>
                      {formatHandshake(detail.latest_handshake)}
                    </StructuredListCell>
                  </StructuredListRow>
                  <StructuredListRow>
                    <StructuredListCell>{t.wireguard.rxBytes}</StructuredListCell>
                    <StructuredListCell>{formatBytes(detail.rx_bytes)}</StructuredListCell>
                  </StructuredListRow>
                  <StructuredListRow>
                    <StructuredListCell>{t.wireguard.txBytes}</StructuredListCell>
                    <StructuredListCell>{formatBytes(detail.tx_bytes)}</StructuredListCell>
                  </StructuredListRow>
                  <StructuredListRow>
                    <StructuredListCell>{t.wireguard.keepalive}</StructuredListCell>
                    <StructuredListCell>
                      {detail.keepalive > 0 ? `${detail.keepalive}s` : '—'}
                    </StructuredListCell>
                  </StructuredListRow>
                </StructuredListBody>
              </StructuredListWrapper>
            </Column>
          </Grid>
        )}
      </Modal>
    </>
  );
};

export default WireGuardStatus;
