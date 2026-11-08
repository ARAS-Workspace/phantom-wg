import React, { useState, useCallback, useEffect } from 'react';
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
  Pagination,
} from '@carbon/react';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import { apiClient } from '@shared/api/client';
import { formatBytes, formatHandshake } from '@shared/utils/formatUtils';
import TableLoader from '@shared/components/data/TableLoader';
import PeerStatusTag from '@shared/components/data/PeerStatusTag';
import { getPeerStatus, sortPeers, type WireGuardStatusData } from '@shared/types/wireguard';

// ── Constants ─────────────────────────────────────────────────────

const COLUMN_COUNT = 6;
const DEFAULT_PAGE_SIZE = 10;
const PAGE_SIZES = [5, 10, 25];

// ── Component ─────────────────────────────────────────────────────

const DashboardPeers: React.FC = () => {
  const { locale } = useLocale();
  const t = translate(locale);

  const [data, setData] = useState<WireGuardStatusData | null>(null);
  const [loading, setLoading] = useState(true);
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(DEFAULT_PAGE_SIZE);

  const fetchStatus = useCallback(async () => {
    setLoading(true);
    const res = await apiClient.get<WireGuardStatusData>('/api/core/wireguard');
    if (res.ok) setData(res.data);
    setLoading(false);
  }, []);

  useEffect(() => {
    void fetchStatus();
  }, [fetchStatus]);

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

  if (loading && !data) {
    return (
      <Grid>
        <Column lg={16} md={8} sm={4}>
          <TableLoader
            columnCount={COLUMN_COUNT}
            rowCount={DEFAULT_PAGE_SIZE}
            showToolbar={false}
          />
        </Column>
      </Grid>
    );
  }

  // Latest handshake first, equal values in name order
  const peers = sortPeers(data?.peers ?? [], 'last_handshake', 'DESC');
  const peersMap = new Map(peers.map((p) => [p.public_key, p]));
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
    <Grid>
      <Column lg={16} md={8} sm={4}>
        <DataTable rows={rows} headers={headers}>
          {({
            rows: tableRows,
            headers: tableHeaders,
            getTableProps,
            getHeaderProps,
            getRowProps,
            getTableContainerProps,
          }) => (
            <TableContainer title={t.dashboard.wireguardPeers} {...getTableContainerProps()}>
              <Table {...getTableProps()} size="sm" data-testid="dashboard-wg-table">
                <TableHead>
                  <TableRow>
                    {tableHeaders.map((header) => {
                      const { key: _key, ...hProps } = getHeaderProps({ header });
                      return (
                        <TableHeader key={header.key} {...hProps}>
                          {header.header}
                        </TableHeader>
                      );
                    })}
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
                      const key = peer.name ?? peer.public_key.slice(0, 8);
                      return (
                        <TableRow key={row.id} {...rProps} data-testid={`dashboard-wg-row-${key}`}>
                          {row.cells.map((cell) =>
                            cell.info.header === 'status' ? (
                              <TableCell key={cell.id}>
                                <PeerStatusTag latestHandshake={peer.latest_handshake} />
                              </TableCell>
                            ) : (
                              <TableCell key={cell.id}>{cell.value as string}</TableCell>
                            )
                          )}
                        </TableRow>
                      );
                    })
                  )}
                </TableBody>
              </Table>

              {/* Localized pagination */}
              <Pagination
                data-testid="dashboard-wg-pagination"
                size="sm"
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
      </Column>
    </Grid>
  );
};

export default DashboardPeers;
