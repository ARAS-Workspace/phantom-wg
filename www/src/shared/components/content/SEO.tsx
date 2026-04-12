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
    { property: 'og:url', content: fullUrl },
    { property: 'og:title', content: fullTitle },
    { property: 'og:description', content: finalDescription },
    { property: 'og:image', content: fullImage },
    { property: 'og:site_name', content: siteConfig.name },
    { property: 'og:locale', content: siteConfig.locale },
    { name: 'twitter:card', content: 'summary_large_image' },
    { name: 'twitter:url', content: fullUrl },
    { name: 'twitter:title', content: fullTitle },
    { name: 'twitter:description', content: finalDescription },
    { name: 'twitter:image', content: fullImage },
  ], [fullTitle, finalDescription, fullUrl, fullImage, type, robotsContent, locale, siteConfig]);

  const links = useMemo(() => [
    { rel: 'canonical', href: fullUrl },
  ], [fullUrl]);

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
