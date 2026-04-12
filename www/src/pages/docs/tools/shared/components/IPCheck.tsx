import { useEffect, useState } from 'react';
import {
  Tile,
  StructuredListWrapper,
  StructuredListHead,
  StructuredListBody,
  StructuredListRow,
  StructuredListCell,
  InlineLoading,
} from '@carbon/react';
import { useLocale } from '@shared/hooks/useLocale';
import { translate } from '@shared/translations';
import { CHECK_ENDPOINT } from './config';

interface IPInfo {
  ip: string;
  country: string | null;
  city: string | null;
  region: string | null;
  isp: string | null;
  asn: string | null;
}

export default function IPCheck() {
  const { locale } = useLocale();
  const t = translate(locale);

  const [info, setInfo] = useState<IPInfo | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);

  useEffect(() => {
    fetch(`${CHECK_ENDPOINT}/ip`)
      .then((res) => res.json())
      .then((data) => {
        setInfo(data);
        setLoading(false);
      })
      .catch(() => {
        setError(true);
        setLoading(false);
      });
  }, []);

  const location = [info?.city, info?.region, info?.country].filter(Boolean).join(', ');

  return (
    <>
      <h1>{t.tools.ipCheck.title}</h1>
      <p>{t.tools.ipCheck.description}</p>

      {loading && <InlineLoading description={t.tools.ipCheck.loading} />}

      {error && <p style={{ color: 'var(--cds-text-error)' }}>{t.tools.ipCheck.error}</p>}

      {info && (
        <>
          <Tile style={{ marginBlock: '1rem', padding: '1.5rem' }}>
            <span style={{ fontSize: '0.875rem', color: 'var(--cds-text-secondary)' }}>{t.tools.ipCheck.ip}</span>
            <p style={{ fontSize: '2rem', fontWeight: 600, fontFamily: 'var(--cds-code-01)', wordBreak: 'break-all' }}>
              {info.ip}
            </p>
          </Tile>

          <StructuredListWrapper>
            <StructuredListHead>
              <StructuredListRow head>
                <StructuredListCell head style={{ width: '30%' }}>
                  {t.tools.ipCheck.field}
                </StructuredListCell>
                <StructuredListCell head>{t.tools.ipCheck.value}</StructuredListCell>
              </StructuredListRow>
            </StructuredListHead>
            <StructuredListBody>
              {location && (
                <StructuredListRow>
                  <StructuredListCell>{t.tools.ipCheck.location}</StructuredListCell>
                  <StructuredListCell>{location}</StructuredListCell>
                </StructuredListRow>
              )}
              {info.isp && (
                <StructuredListRow>
                  <StructuredListCell>{t.tools.ipCheck.isp}</StructuredListCell>
                  <StructuredListCell>{info.isp}</StructuredListCell>
                </StructuredListRow>
              )}
              {info.asn && (
                <StructuredListRow>
                  <StructuredListCell>{t.tools.ipCheck.asn}</StructuredListCell>
                  <StructuredListCell>{info.asn}</StructuredListCell>
                </StructuredListRow>
              )}
            </StructuredListBody>
          </StructuredListWrapper>
        </>
      )}
    </>
  );
}
