import React, { useMemo } from 'react';
import { useLocation } from 'react-router-dom';
import { useLocale } from '@shared/hooks';
import { getSiteConfig } from '@shared/config/seoConfig';
import { toISO } from '@shared/utils/date-helpers';
import { createTechArticleSchema } from '@shared/utils/schema-helpers';
import SEO from '@shared/components/content/SEO';
import MDXPageRenderer from '@shared/components/content/MDXPageRenderer';

import metaEn from './meta/en.json';
import Content from './index.en.mdx';

const META_MAP: Record<string, typeof metaEn> = { en: metaEn, tr: metaEn };

// noinspection DuplicatedCode
const IOSPrivacyPage: React.FC = () => {
  const { locale } = useLocale();
  const { pathname } = useLocation();
  const siteConfig = getSiteConfig(locale);
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

export default IOSPrivacyPage;
