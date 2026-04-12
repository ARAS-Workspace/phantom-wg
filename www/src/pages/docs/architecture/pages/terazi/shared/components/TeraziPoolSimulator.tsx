import React, { useState, useCallback } from 'react';
import {
  DataTable,
  Table,
  TableHead,
  TableRow,
  TableHeader,
  TableBody,
  TableCell,
  Button,
  Tag,
} from '@carbon/react';
import { Add, TrashCan, Renew } from '@carbon/icons-react';
import { useLocale } from '@shared/hooks';
import { translate } from '@shared/translations';
import './styles/TeraziPoolSimulator.scss';

// ── Tunables ──────────────────────────────────────────────────────

const SUBNET_A = { prefix: 29, v4: '10.8.0', v6: 'fd00:70:68::', start: 2, end: 6  };
const SUBNET_B = { prefix: 28, v4: '10.8.0', v6: 'fd00:70:68::', start: 2, end: 14 };

const FILL_MS        = 160;
const CLEAR_MS       = 70;
const REBUILD_MS     = 700;
const REASSIGN_MS    = 200;
const RESTORE_PAUSE  = 1200;
const COUNTDOWN_FROM = 5;

const RING_RADIUS   = 54;
const CIRCUMFERENCE = 2 * Math.PI * RING_RADIUS;

// ── Types ─────────────────────────────────────────────────────────

type Subnet   = typeof SUBNET_A;
type RowState = 'normal' | 'backup' | 'clearing' | 'incoming';

interface PoolRow {
  ipv4: string; ipv6: string;
  id: string | null; name: string | null;
  privateKey: string | null; publicKey: string | null;
  presharedKey: string | null; createdAt: string | null; updatedAt: string | null;
}

// ── Helpers ───────────────────────────────────────────────────────

let clientCounter = 0;

const mkUuid = () => { const h = () => Math.random().toString(16).slice(2,6); return `${h()}${h()}-${h()}-4${h().slice(1)}-${h()}-${h()}${h()}${h().slice(0,4)}`; };
const mkHex  = () => { let s=''; for(let i=0;i<32;i++) s+=Math.random().toString(16).slice(2,4); return s; };
const mkNow  = () => new Date().toISOString().replace('Z','').slice(0,23);
const delay  = (ms: number) => new Promise<void>(r => setTimeout(r, ms));

function emptyPool(subnet: Subnet): PoolRow[] {
  const rows: PoolRow[] = [];
  for (let i = subnet.start; i <= subnet.end; i++) {
    rows.push({ ipv4: `${subnet.v4}.${i}`, ipv6: `${subnet.v6}${i.toString(16)}`,
      id: null, name: null, privateKey: null, publicKey: null,
      presharedKey: null, createdAt: null, updatedAt: null });
  }
  return rows;
}

// ── Countdown overlay ─────────────────────────────────────────────

const CountdownOverlay: React.FC<{ count: number }> = ({ count }) => {
  const progress = count / COUNTDOWN_FROM;
  const offset   = CIRCUMFERENCE * (1 - progress);
  return (
    <div className="pool-sim__countdown-overlay">
      <div className="pool-sim__countdown-ring-wrap">
        <svg viewBox="0 0 120 120" className="pool-sim__countdown-ring">
          <circle cx="60" cy="60" r={RING_RADIUS} className="pool-sim__ring-bg" />
          <circle cx="60" cy="60" r={RING_RADIUS}
            className="pool-sim__ring-progress"
            strokeDasharray={CIRCUMFERENCE}
            strokeDashoffset={offset}
            transform="rotate(-90 60 60)"
          />
        </svg>
        <span className="pool-sim__countdown-number">{count}</span>
      </div>
    </div>
  );
};

// ── Component ─────────────────────────────────────────────────────

const TeraziPoolSimulator: React.FC = () => {
  const { locale } = useLocale();
  const t = translate(locale);
  const sim = t.documentation.poolSimulator as Record<string, string>;

  const [pool,       setPool]       = useState<PoolRow[]>(() => emptyPool(SUBNET_A));
  const [rowStates,  setRowStates]  = useState<Map<number, RowState>>(new Map());
  const [currentSub, setCurrentSub] = useState<Subnet>(SUBNET_A);
  const [running,    setRunning]    = useState(false);
  const [countdown,  setCountdown]  = useState<number | null>(null);

  const assignedCount = pool.filter(r => r.id !== null).length;
  const freeCount     = pool.length - assignedCount;

  const setRowState = useCallback((idx: number, state: RowState | null) => {
    setRowStates(prev => { const m = new Map(prev); state === null ? m.delete(idx) : m.set(idx, state); return m; });
  }, []);

  const clearRowStates = useCallback(() => setRowStates(new Map()), []);

  // ── Manual controls ──────────────────────────────────────────────

  const handleAssign = () => {
    setPool(prev => {
      const idx = prev.findIndex(r => r.id === null);
      if (idx === -1) return prev;
      clientCounter++;
      const t = mkNow(); const next = [...prev];
      next[idx] = { ...next[idx], id: mkUuid(), name: `client-${clientCounter}`,
        privateKey: mkHex(), publicKey: mkHex(), presharedKey: mkHex(), createdAt: t, updatedAt: t };
      return next;
    });
  };

  const handleRevoke = () => {
    setPool(prev => {
      for (let i = prev.length - 1; i >= 0; i--) {
        if (prev[i].id !== null) {
          const next = [...prev];
          next[i] = { ...next[i], id: null, name: null, privateKey: null,
            publicKey: null, presharedKey: null, createdAt: null, updatedAt: null };
          return next;
        }
      }
      return prev;
    });
  };

  // ── Cinema helpers ────────────────────────────────────────────────

  const fillToCapacity = useCallback(async (base: PoolRow[]): Promise<PoolRow[]> => {
    const result = base.map(r => ({ ...r }));
    for (let ci = 0; ci < result.length; ci++) {
      if (result[ci].id !== null) continue;
      clientCounter++;
      const t = mkNow();
      result[ci] = { ...result[ci], id: mkUuid(), name: `c-${clientCounter}`,
        privateKey: mkHex(), publicKey: mkHex(), presharedKey: mkHex(), createdAt: t, updatedAt: t };
      setPool(result.map(r => ({ ...r })));
      setRowState(ci, 'incoming');
      await delay(FILL_MS);
      setRowState(ci, 'normal');
    }
    await delay(500);
    return result;
  }, [setRowState]);

  const runExpansion = useCallback(async (
    clients: PoolRow[], fromSub: Subnet, toSub: Subnet,
  ): Promise<PoolRow[]> => {
    const assigned = clients.filter(r => r.id !== null);
    const slotCount = fromSub.end - fromSub.start + 1;

    // Backup flash
    assigned.forEach((_, i) => setRowState(i, 'backup'));
    await delay(700);
    clearRowStates();

    // Clear row by row
    setPool(prev => prev.map(r => ({ ...r, id: null, name: null, privateKey: null,
      publicKey: null, presharedKey: null, createdAt: null, updatedAt: null })));
    for (let i = 0; i < slotCount; i++) {
      setRowState(i, 'clearing');
      await delay(CLEAR_MS);
      setRowState(i, 'normal');
    }
    clearRowStates();
    await delay(300);

    // Rebuild
    await delay(REBUILD_MS);
    const newBase = emptyPool(toSub);
    setPool(newBase);
    setCurrentSub(toSub);
    await delay(400);

    // Reassign
    const rebuilt = newBase.map(r => ({ ...r }));
    for (let ci = 0; ci < assigned.length; ci++) {
      const client = assigned[ci];
      const t = mkNow();
      rebuilt[ci] = { ...rebuilt[ci], id: client.id, name: client.name,
        privateKey: client.privateKey, publicKey: client.publicKey,
        presharedKey: client.presharedKey, createdAt: client.createdAt, updatedAt: t };
      setPool(rebuilt.map(r => ({ ...r })));
      setRowState(ci, 'incoming');
      await delay(REASSIGN_MS);
      setRowState(ci, 'normal');
    }
    clearRowStates();
    await delay(500);
    return rebuilt;
  }, [setRowState, clearRowStates]);

  // ── Cinema ────────────────────────────────────────────────────────

  const handleCinema = useCallback(async () => {
    if (running) return;
    setRunning(true);

    for (let c = COUNTDOWN_FROM; c >= 1; c--) {
      setCountdown(c);
      await delay(1000);
    }
    setCountdown(null);

    let userSnapshot: PoolRow[] = [];
    setPool(prev => { userSnapshot = prev.map(r => ({ ...r })); return prev; });
    await delay(30);

    // Stage 1: /29 → fill → /28
    const baseA  = emptyPool(SUBNET_A);
    setPool(baseA); setCurrentSub(SUBNET_A); clearRowStates();
    await delay(400);
    const fullA  = await fillToCapacity(baseA);
    const afterB = await runExpansion(fullA, SUBNET_A, SUBNET_B);

    // Stage 2: /28 → fill
    await delay(300);
    await fillToCapacity(afterB);
    await delay(RESTORE_PAUSE);

    // Restore
    setPool(userSnapshot);
    setCurrentSub(SUBNET_A);
    clearRowStates();
    await delay(800);
    setRunning(false);
  }, [running, fillToCapacity, runExpansion, setRowState, clearRowStates]);

  // ── Table ─────────────────────────────────────────────────────────

  const headers = [
    { key: 'ipv4',         header: 'ipv4_address'     },
    { key: 'ipv6',         header: 'ipv6_address'      },
    { key: 'id',           header: 'id'                },
    { key: 'name',         header: 'name'              },
    { key: 'privateKey',   header: 'private_key_hex'   },
    { key: 'publicKey',    header: 'public_key_hex'    },
    { key: 'presharedKey', header: 'preshared_key_hex' },
    { key: 'createdAt',    header: 'created_at'        },
    { key: 'updatedAt',    header: 'updated_at'        },
  ];

  const trunc = (v: string | null) => v ? (v.length > 10 ? v.slice(0, 10) + '…' : v) : '';
  const NULL_LABEL = <span className="pool-sim__null">&lt;null&gt;</span>;

  const rowClass = (i: number, row: PoolRow) => {
    const rs = rowStates.get(i);
    if (rs === 'backup')   return 'pool-sim__row--backup';
    if (rs === 'clearing') return 'pool-sim__row--clearing';
    if (rs === 'incoming') return 'pool-sim__row--incoming';
    if (row.id)            return 'pool-sim__row--assigned';
    return '';
  };

  return (
    <div className="pool-sim" data-testid="docs-pool-simulator">
      {countdown !== null && <CountdownOverlay count={countdown} />}

      <div className="pool-sim__toolbar">
        <div className="pool-sim__actions">
          <Button size="sm" kind="primary" renderIcon={Add}
            onClick={handleAssign} disabled={running || freeCount === 0}
            data-testid="pool-sim-assign">{sim.assign}</Button>
          <Button size="sm" kind="danger--tertiary" renderIcon={TrashCan}
            onClick={handleRevoke} disabled={running || assignedCount === 0}
            data-testid="pool-sim-revoke">{sim.revoke}</Button>
          <Button size="sm" kind="tertiary" renderIcon={Renew}
            onClick={() => void handleCinema()} disabled={running}
            data-testid="pool-sim-cidr">{sim.cidrSim}</Button>
        </div>
        <div className="pool-sim__stats">
          <Tag type="green" size="sm">{assignedCount} {sim.assigned}</Tag>
          <Tag type="cool-gray" size="sm">{freeCount} {sim.free}</Tag>
          <Tag type="blue" size="sm">/{currentSub.prefix}</Tag>
        </div>
      </div>

      <div className="pool-sim__table-wrapper">
        <DataTable rows={pool.map((_, i) => ({ id: String(i) }))} headers={headers} size="sm">
          {({ headers: hdrs, getHeaderProps, getTableProps }: any) => (
            <Table {...getTableProps()}>
              <TableHead>
                <TableRow>
                  {hdrs.map((h: any) => (
                    <TableHeader {...getHeaderProps({ header: h })} key={h.key}>{h.header}</TableHeader>
                  ))}
                </TableRow>
              </TableHead>
              <TableBody>
                {pool.map((row, i) => (
                  <TableRow key={`${currentSub.prefix}-${i}`} className={rowClass(i, row)}>
                    <TableCell className="pool-sim__cell--mono">{row.ipv4}</TableCell>
                    <TableCell className="pool-sim__cell--mono">{row.ipv6}</TableCell>
                    <TableCell className="pool-sim__cell--mono">{row.id ? trunc(row.id) : NULL_LABEL}</TableCell>
                    <TableCell className="pool-sim__cell--mono">{row.name ?? NULL_LABEL}</TableCell>
                    <TableCell className="pool-sim__cell--mono">{row.privateKey ? trunc(row.privateKey) : NULL_LABEL}</TableCell>
                    <TableCell className="pool-sim__cell--mono">{row.publicKey ? trunc(row.publicKey) : NULL_LABEL}</TableCell>
                    <TableCell className="pool-sim__cell--mono">{row.presharedKey ? trunc(row.presharedKey) : NULL_LABEL}</TableCell>
                    <TableCell className="pool-sim__cell--mono">{row.createdAt ?? NULL_LABEL}</TableCell>
                    <TableCell className="pool-sim__cell--mono">{row.updatedAt ?? NULL_LABEL}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </DataTable>
      </div>

      <p className="pool-sim__caption">
        {sim.caption} <code>/{currentSub.prefix}</code> — {pool.length} {sim.slots}
      </p>
    </div>
  );
};

export default TeraziPoolSimulator;
