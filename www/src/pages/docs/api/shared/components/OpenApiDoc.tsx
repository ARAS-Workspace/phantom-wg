import React, { useEffect, useState } from 'react';
import { InlineLoading, InlineNotification } from '@carbon/react';
import { useLocale } from '@shared/hooks';
import { useIsClient } from '@shared/hooks/useIsClient';
import { translate } from '@shared/translations';
import OpenApiRenderer from '@shared/components/openapi/components/OpenApiRenderer';
import type { OpenApiSpec } from '@shared/components/openapi/types/openapi';

const OpenApiDoc: React.FC = () => {
  const { locale } = useLocale();
  const isClient = useIsClient();
  const t = translate(locale);

  const [spec, setSpec] = useState<OpenApiSpec | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);

  useEffect(() => {
    if (!isClient) return;
    setLoading(true);
    setError(false);
    fetch('/openapi.json')
      .then((res) => {
        if (!res.ok) throw new Error('Failed to fetch');
        return res.json() as Promise<OpenApiSpec>;
      })
      .then((data) => {
        setSpec(data);
        setLoading(false);
      })
      .catch(() => {
        setError(true);
        setLoading(false);
      });
  }, [isClient]);

  if (!isClient || loading) {
    return (
      <div style={{ padding: '2rem' }}>
        <InlineLoading description={t.common.loading} />
      </div>
    );
  }

  if (error) {
    return (
      <div style={{ padding: '2rem' }}>
        <InlineNotification kind="error" title={t.apiDoc.error} hideCloseButton lowContrast />
      </div>
    );
  }

  if (!spec) return null;

  return <OpenApiRenderer spec={spec} showVersion />;
};

export default OpenApiDoc;
