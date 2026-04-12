import seoConfigTr from './seo.json';
import seoConfigEn from './seo.en.json';

export interface SiteConfig {
  name: string;
  title: string;
  description: string;
  url: string;
  href?: string;
  locale: string;
  author: {
    name: string;
    url?: string;
  };
  social: {
    twitter?: string | null;
    linkedin?: string | null;
    github?: string | null;
  };
  defaultImage: string;
  logo: string;
}

const SEO_CONFIG_MAP: Record<'tr' | 'en', SiteConfig> = {
  tr: seoConfigTr,
  en: seoConfigEn,
};

export const getSiteConfig = (locale: 'tr' | 'en' = 'en'): SiteConfig => {
  const config = SEO_CONFIG_MAP[locale] || SEO_CONFIG_MAP.en;
  const isClient = typeof window !== 'undefined';
  return {
    ...config,
    url: isClient ? window.location.origin : config.url,
    href: isClient ? `${window.location.origin}${window.location.pathname}` : config.url,
  };
};
