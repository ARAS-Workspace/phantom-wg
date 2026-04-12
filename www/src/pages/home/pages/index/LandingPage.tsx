import React, { useMemo } from 'react';
import { useLocation } from 'react-router-dom';
import { useLocale } from '@shared/hooks';
import { getSiteConfig } from '@shared/config/seoConfig';
import SEO from '@shared/components/content/SEO';
import { createOrganizationSchema, createSoftwareApplicationSchema } from '@shared/utils/schema-helpers';
import Hero from '@shared/components/ui/Hero';
import type { HeroContent } from '@shared/components/ui/Hero';

import metaEn from './meta/en.json';
import metaTr from './meta/tr.json';
import heroEn from '../../data/sections/en/hero.json';
import heroTr from '../../data/sections/tr/hero.json';

const META_MAP = { en: metaEn, tr: metaTr };
const HERO_MAP: Record<string, HeroContent> = {
  en: heroEn as unknown as HeroContent,
  tr: heroTr as unknown as HeroContent,
};

const LandingPage: React.FC = () => {
  const { locale } = useLocale();
  const { pathname } = useLocation();
  const siteConfig = getSiteConfig(locale);
  const meta = META_MAP[locale] || META_MAP.en;
  const heroContent = HERO_MAP[locale] || HERO_MAP.en;

  const logoUrl = siteConfig.logo.startsWith('http')
    ? siteConfig.logo
    : `${siteConfig.url}${siteConfig.logo}`;

  const schemas = useMemo(() => [
    createOrganizationSchema(logoUrl, locale),
    {
      '@context': 'https://schema.org',
      '@type': 'WebSite',
      name: siteConfig.name,
      description: meta.seo.description,
      url: siteConfig.url,
    },
    createSoftwareApplicationSchema(locale),
  ], [siteConfig, meta, locale, logoUrl]);

  return (
    <>
      <SEO {...meta.seo} path={pathname} schemas={schemas} />
      <Hero content={heroContent} />
    </>
  );
};

export default LandingPage;
