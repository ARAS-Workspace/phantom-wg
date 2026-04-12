
import React, { useMemo } from 'react';
import { useLocation } from 'react-router-dom';
import { useLocale } from '@shared/hooks';
import { getSiteConfig } from '@shared/config/seoConfig';
import { toISO } from '@shared/utils/date-helpers';
import { createTechArticleSchema } from '@shared/utils/schema-helpers';
import SEO from '@shared/components/content/SEO';
import MDXPageRenderer from '@shared/components/content/MDXPageRenderer';

import metaEn from './meta/en.json';
import metaTr from './meta/tr.json';
import ContentTr from './index.mdx';
import ContentEn from './index.en.mdx';

const META_MAP = { en: metaEn, tr: metaTr };
const CONTENT_MAP: Record<string, React.ComponentType> = { tr: ContentTr, en: ContentEn };

// noinspection DuplicatedCode
const BridgePage: React.FC = () => {
  const { locale } = useLocale();
  const { pathname } = useLocation();
  const siteConfig = getSiteConfig(locale);
  const Content = CONTENT_MAP[locale] || CONTENT_MAP.en;
  const meta = META_MAP[locale] || META_MAP.en;

  const schemas = useMemo(() => [
    createTechArticleSchema({
      title: meta.seo.title,
      description: meta.seo.description,
      url: `${siteConfig.url}${pathname}`,
      datePublished: toISO(meta.kv.datePublished),
      dateModified: toISO(meta.kv.dateModified),
    }, locale),
  ], [siteConfig, meta, pathname, locale]);

  return (
    <>
      <SEO {...meta.seo} path={pathname} schemas={schemas} />
      <MDXPageRenderer content={Content} />
    </>
  );
};

export default BridgePage;
