import React, { useMemo } from 'react';
import { useLocation } from 'react-router-dom';
import { useLocale } from '@shared/hooks';
import { getSiteConfig } from '@shared/config/seoConfig';
import { toISO } from '@shared/utils/date-helpers';
import { createTechArticleSchema } from '@shared/utils/schema-helpers';
import SEO from '@shared/components/content/SEO';
import UnderConstruction from '@shared/components/ui/UnderConstruction';
import type { UnderConstructionContent } from '@shared/components/ui/UnderConstruction';

import metaEn from './meta/en.json';
import metaTr from './meta/tr.json';
import contentEn from '../../data/sections/en/under-construction.json';
import contentTr from '../../data/sections/tr/under-construction.json';

const META_MAP = { en: metaEn, tr: metaTr };
const CONTENT_MAP: Record<string, UnderConstructionContent> = { tr: contentTr, en: contentEn };

// noinspection DuplicatedCode
const HomePage: React.FC = () => {
  const { locale } = useLocale();
  const { pathname } = useLocation();
  const siteConfig = getSiteConfig(locale);
  const content = CONTENT_MAP[locale] || CONTENT_MAP.en;
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
      <UnderConstruction content={content} />
    </>
  );
};

export default HomePage;
