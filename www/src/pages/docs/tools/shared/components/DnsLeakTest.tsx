import { useCallback, useEffect, useRef, useState } from 'react';
import {
  Button,
  DataTable,
  Table,
  TableHead,
  TableRow,
  TableHeader,
  TableBody,
  TableCell,
  InlineLoading,
  InlineNotification,
  Tag,
} from '@carbon/react';
import { useLocale } from '@shared/hooks/useLocale';
import { translate } from '@shared/translations';
import { CHECK_ENDPOINT, TURNSTILE_SITE_KEY } from './config';

interface ResolverResult {
  ip: string;
  country_code: string | null;
  location: string | null;
  isp: string | null;
  asn: string | null;
}

type TestStatus = 'idle' | 'resolving' | 'enriching' | 'done' | 'error';

const QUERY_COUNT = 6;

export default function DnsLeakTest() {
  const { locale } = useLocale();
  const t = translate(locale);

  const [status, setStatus] = useState<TestStatus>('idle');
  const [resolvers, setResolvers] = useState<ResolverResult[]>([]);
  const [received, setReceived] = useState(0);
  const [errorMsg, setErrorMsg] = useState('');
  const turnstileRef = useRef<HTMLDivElement>(null);
  const turnstileWidgetId = useRef<string | null>(null);

  useEffect(() => {
    if (document.getElementById('turnstile-script')) return;
    const script = document.createElement('script');
    script.id = 'turnstile-script';
    script.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';
    script.async = true;
    document.head.appendChild(script);
  }, []);

  const getTurnstileToken = useCallback((): Promise<string> => {
    return new Promise((resolve, reject) => {
      const turnstile = (window as any).turnstile;
      if (!turnstile) {
        reject(new Error('Turnstile not loaded'));
        return;
      }

      if (turnstileWidgetId.current) {
        turnstile.remove(turnstileWidgetId.current);
      }

      // noinspection JSUnusedGlobalSymbols
      turnstileWidgetId.current = turnstile.render(turnstileRef.current, {
        sitekey: TURNSTILE_SITE_KEY,
        callback: (token: string) => resolve(token),
        'error-callback': () => reject(new Error('Turnstile failed')),
        size: 'invisible',
      });
    });
  }, []);

  const startTest = useCallback(async () => {
    setStatus('resolving');
    setResolvers([]);
    setReceived(0);
    setErrorMsg('');

    try {
      let token: string;
      try {
        token = await getTurnstileToken();
      } catch {
        setErrorMsg(t.tools.dnsLeak.errorTurnstile);
        setStatus('error');
        return;
      }

      let genResp: Response;
      try {
        genResp = await fetch(`${CHECK_ENDPOINT}/dns/generate`, {
          method: 'POST',
          headers: { 'CF-Turnstile-Token': token },
        });
      } catch {
        setErrorMsg(t.tools.dnsLeak.errorNetwork);
        setStatus('error');
        return;
      }

      if (!genResp.ok) {
        setErrorMsg(t.tools.dnsLeak.errorGenerate);
        setStatus('error');
        return;
      }
      const { domains } = await genResp.json();

      const resolverIPs: string[] = [];
      let count = 0;

      await Promise.allSettled(
        domains.map(async (domain: string) => {
          try {
            const resp = await fetch(`https://${domain}/`);
            if (resp.ok) {
              const data = await resp.json();
              if (data.resolver_ip && !resolverIPs.includes(data.resolver_ip)) {
                resolverIPs.push(data.resolver_ip);
              }
            }
          } catch {
            // Some queries may fail — partial results are acceptable
          } finally {
            count++;
            setReceived(count);
          }
        }),
      );

      if (resolverIPs.length === 0) {
        setErrorMsg(t.tools.dnsLeak.errorNoResolvers);
        setStatus('error');
        return;
      }

      setStatus('enriching');

      let lookupToken: string;
      try {
        lookupToken = await getTurnstileToken();
      } catch {
        setResolvers(resolverIPs.map((ip) => ({ ip, country_code: null, location: null, isp: null, asn: null })));
        setStatus('done');
        return;
      }

      const lookupResp = await fetch(`${CHECK_ENDPOINT}/dns/lookup`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'CF-Turnstile-Token': lookupToken,
        },
        body: JSON.stringify({ ips: resolverIPs }),
      });

      if (lookupResp.ok) {
        const { results } = await lookupResp.json();
        setResolvers(results);
      } else {
        setResolvers(resolverIPs.map((ip) => ({ ip, country_code: null, location: null, isp: null, asn: null })));
      }

      setStatus('done');
    } catch (err: any) {
      setErrorMsg(err.message || t.tools.dnsLeak.error);
      setStatus('error');
    }
  }, [getTurnstileToken, t]);

  const headers = [
    { key: 'ip', header: t.tools.dnsLeak.ip },
    { key: 'location', header: t.tools.dnsLeak.location },
    { key: 'isp', header: t.tools.dnsLeak.isp },
    { key: 'asn', header: t.tools.dnsLeak.asn },
  ];

  const rows = resolvers.map((r, i) => ({
    id: String(i),
    ip: r.ip,
    location: r.country_code
      ? `${countryFlag(r.country_code)} ${r.location || r.country_code}`
      : r.location || '—',
    isp: r.isp || '—',
    asn: r.asn || '—',
  }));

  return (
    <>
      <h1>{t.tools.dnsLeak.title}</h1>
      <p>{t.tools.dnsLeak.description}</p>

      <div ref={turnstileRef} style={{ display: 'none' }} />

      <div style={{ marginBlock: '1rem' }}>
        {status === 'idle' && (
          <Button onClick={startTest}>{t.tools.dnsLeak.startButton}</Button>
        )}

        {status === 'resolving' && (
          <InlineLoading
            description={`${t.tools.dnsLeak.resolving} (${received} ${t.tools.dnsLeak.of} ${QUERY_COUNT} ${t.tools.dnsLeak.received})`}
          />
        )}

        {status === 'enriching' && <InlineLoading description={t.tools.dnsLeak.enriching} />}

        {status === 'error' && (
          <>
            <InlineNotification
              kind="error"
              title={errorMsg || t.tools.dnsLeak.error}
              lowContrast
              hideCloseButton
              style={{ maxWidth: '100%' }}
            />
            <Button onClick={startTest} style={{ marginTop: '0.5rem' }}>
              {t.tools.dnsLeak.startButton}
            </Button>
          </>
        )}
      </div>

      {status === 'done' && (
        <>
          <DataTable rows={rows} headers={headers}>
            {({ rows: tableRows, headers: tableHeaders, getTableProps, getHeaderProps, getRowProps }) => (
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
                  {tableRows.map((row) => (
                    <TableRow {...getRowProps({ row })} key={row.id}>
                      {row.cells.map((cell) => (
                        <TableCell key={cell.id}>
                          {cell.info.header === 'ip' ? (
                            <Tag type="cool-gray" size="sm">
                              {cell.value}
                            </Tag>
                          ) : (
                            cell.value
                          )}
                        </TableCell>
                      ))}
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </DataTable>

          <Button
            onClick={() => { setStatus('idle'); setResolvers([]); setReceived(0); }}
            kind="ghost"
            style={{ marginTop: '1rem' }}
          >
            {t.tools.dnsLeak.resetButton}
          </Button>
        </>
      )}
    </>
  );
}

function countryFlag(code: string): string {
  return code
    .toUpperCase()
    .split('')
    .map((c) => String.fromCodePoint(0x1f1e6 + c.charCodeAt(0) - 65))
    .join('');
}
