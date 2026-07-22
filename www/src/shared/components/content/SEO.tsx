import React, { useEffect, useMemo } from 'react';
import { getSiteConfig } from '@shared/config/seoConfig';
import { generateTitle, generateUrl, generateImageUrl } from '@shared/utils/seo-utils';
import { useLocale } from '@shared/hooks';
import { useSEO } from '@shared/contexts/SEOContext';
import { useHead } from '@shared/hooks/useHead';

export interface SEOProps {
  title?: string;
  description?: string;
  image?: string;
  path?: string;
  type?: 'website' | 'article';
  noIndex?: boolean;
  schemas?: any[];
}

// The bare URL serves the default locale; other locales live behind
// `?locale=` (the Worker negotiates). Canonical and hreflang below must
// agree with that contract — and with the sitemap's alternates.
const DEFAULT_LOCALE = 'en';
const LOCALES: Array<'tr' | 'en'> = ['en', 'tr'];

const SEO: React.FC<SEOProps> = ({
  title,
  description,
  image,
  path,
  type = 'website',
  noIndex = false,
  schemas: propSchemas = [],
}) => {
  const { locale } = useLocale();
  const { updateMetadata } = useSEO();

  const siteConfig = getSiteConfig(locale);
  const finalDescription = description || siteConfig.description;
  const fullTitle = generateTitle(title, locale);
  const currentPath = path || (typeof window !== 'undefined' ? window.location.pathname : undefined);
  const fullUrl = generateUrl(currentPath, locale);
  const fullImage = generateImageUrl(image, locale);
  const robotsContent = noIndex ? 'noindex, nofollow' : 'index, follow';

  // Each locale variant is canonical to ITSELF: the default locale to the
  // bare URL, others to their `?locale=` URL. A TR page whose canonical
  // pointed at the bare (EN) URL would tell Google to drop the TR variant.
  const localeUrl = (l: 'tr' | 'en') => (l === DEFAULT_LOCALE ? fullUrl : `${fullUrl}?locale=${l}`);
  const canonicalUrl = localeUrl(locale);
  const altOgLocale = getSiteConfig(locale === 'en' ? 'tr' : 'en').locale;

  useEffect(() => {
    updateMetadata({
      title: fullTitle,
      description: finalDescription,
      path: path || window.location.pathname,
      locale,
    });
  }, [fullTitle, finalDescription, path, locale, updateMetadata]);

  const allSchemas = propSchemas;

  const meta = useMemo(() => [
    { name: 'title', content: fullTitle },
    { name: 'description', content: finalDescription },
    { name: 'author', content: siteConfig.author.name },
    { name: 'robots', content: robotsContent },
    { httpEquiv: 'content-language', content: locale },
    { property: 'og:type', content: type },
    { property: 'og:url', content: canonicalUrl },
    { property: 'og:title', content: fullTitle },
    { property: 'og:description', content: finalDescription },
    { property: 'og:image', content: fullImage },
    { property: 'og:site_name', content: siteConfig.name },
    { property: 'og:locale', content: siteConfig.locale },
    { property: 'og:locale:alternate', content: altOgLocale },
    { name: 'twitter:card', content: 'summary_large_image' },
    { name: 'twitter:url', content: canonicalUrl },
    { name: 'twitter:title', content: fullTitle },
    { name: 'twitter:description', content: finalDescription },
    { name: 'twitter:image', content: fullImage },
  ], [fullTitle, finalDescription, canonicalUrl, fullImage, type, robotsContent, locale, siteConfig, altOgLocale]);

  const links = useMemo(() => [
    { rel: 'canonical', href: canonicalUrl },
    // hreflang pair + x-default — identical on every locale variant, and
    // each href matches that variant's own canonical (sitemap agrees).
    ...LOCALES.map((l) => ({ rel: 'alternate', href: localeUrl(l), hrefLang: l })),
    { rel: 'alternate', href: fullUrl, hrefLang: 'x-default' },
  ], [canonicalUrl, fullUrl, locale]);

  useHead({
    title: fullTitle,
    lang: locale,
    meta,
    links,
    schemas: allSchemas,
  });

  return null;
};

export default SEO;
