import React from 'react';
import { useLocation } from 'react-router-dom';
import { useLocale } from '@shared/hooks';
import SEO from '@shared/components/content/SEO';
import MDXPageRenderer from '@shared/components/content/MDXPageRenderer';

import metaEn from './meta/en.json';
import metaTr from './meta/tr.json';
import ContentTr from './index.mdx';
import ContentEn from './index.en.mdx';

const META_MAP = { en: metaEn, tr: metaTr };
const CONTENT_MAP: Record<string, React.ComponentType> = { tr: ContentTr, en: ContentEn };

const AiPage: React.FC = () => {
  const { locale } = useLocale();
  const { pathname } = useLocation();
  const Content = CONTENT_MAP[locale] || CONTENT_MAP.en;
  const meta = META_MAP[locale] || META_MAP.en;

  return (
    <>
      <SEO {...meta.seo} path={pathname} />
      <MDXPageRenderer content={Content} />
    </>
  );
};

export default AiPage;
