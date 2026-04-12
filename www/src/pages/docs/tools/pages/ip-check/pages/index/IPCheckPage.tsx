import { useLocation } from 'react-router-dom';
import { useLocale } from '@shared/hooks/useLocale';
import SEO from '@shared/components/content/SEO';
import IPCheck from '../../../../shared/components/IPCheck';

import metaEn from './meta/en.json';
import metaTr from './meta/tr.json';

const META_MAP: Record<string, typeof metaEn> = { en: metaEn, tr: metaTr };

export default function IPCheckPage() {
  const { locale } = useLocale();
  const { pathname } = useLocation();
  const meta = META_MAP[locale] || META_MAP.en;

  return (
    <>
      <SEO {...meta.seo} path={pathname} />
      <IPCheck />
    </>
  );
}
