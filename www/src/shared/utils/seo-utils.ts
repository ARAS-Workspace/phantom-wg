import { getSiteConfig } from '@shared/config/seoConfig';

export const generateTitle = (pageTitle?: string, locale: 'tr' | 'en' = 'en'): string => {
  const siteConfig = getSiteConfig(locale);
  if (!pageTitle) return siteConfig.title;
  return `${pageTitle} | ${siteConfig.name}`;
};

export const generateUrl = (path?: string, locale: 'tr' | 'en' = 'en'): string => {
  const siteConfig = getSiteConfig(locale);
  if (!path) return siteConfig.url;
  const cleanPath = path.startsWith('/') ? path : `/${path}`;
  return `${siteConfig.url}${cleanPath}`;
};

export const generateImageUrl = (imagePath?: string, locale: 'tr' | 'en' = 'en'): string => {
  const siteConfig = getSiteConfig(locale);
  if (!imagePath) return `${siteConfig.url}${siteConfig.defaultImage}`;
  if (imagePath.startsWith('http')) return imagePath;
  const cleanPath = imagePath.startsWith('/') ? imagePath : `/${imagePath}`;
  return `${siteConfig.url}${cleanPath}`;
};
