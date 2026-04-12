import { getSiteConfig } from '@shared/config/seoConfig';

export const createOrganizationSchema = (logoUrl: string, locale: 'tr' | 'en' = 'en') => {
  const siteConfig = getSiteConfig(locale);
  return {
    '@context': 'https://schema.org',
    '@type': 'Organization',
    '@id': `${siteConfig.url}/#organization`,
    name: siteConfig.name,
    url: siteConfig.url,
    logo: {
      '@type': 'ImageObject',
      url: logoUrl,
    },
    description: siteConfig.description,
    contactPoint: {
      '@type': 'ContactPoint',
      contactType: 'Customer Service',
      availableLanguage: ['Turkish', 'English'],
    },
    sameAs: Object.values(siteConfig.social).filter(Boolean),
  };
};

export interface TechArticleProps {
  title: string;
  description: string;
  url: string;
  datePublished: string;
  dateModified: string;
}

export const createTechArticleSchema = (props: TechArticleProps, locale: 'tr' | 'en' = 'en') => {
  const siteConfig = getSiteConfig(locale);
  return {
    '@context': 'https://schema.org',
    '@type': 'TechArticle',
    headline: props.title,
    description: props.description,
    url: props.url,
    image: `${siteConfig.url}${siteConfig.defaultImage}`,
    datePublished: props.datePublished,
    dateModified: props.dateModified,
    author: { '@type': 'Person', name: siteConfig.author.name, url: siteConfig.author.url },
    publisher: { '@type': 'Organization', name: siteConfig.name, url: siteConfig.url },
    isPartOf: { '@type': 'WebSite', name: siteConfig.name, url: siteConfig.url },
  };
};

export const createSoftwareApplicationSchema = (locale: 'tr' | 'en' = 'en') => {
  const siteConfig = getSiteConfig(locale);
  return {
    '@context': 'https://schema.org',
    '@type': 'SoftwareApplication',
    '@id': `${siteConfig.url}/#software`,
    name: 'Phantom-WG',
    applicationCategory: 'NetworkApplication',
    operatingSystem: 'Linux',
    license: 'https://www.gnu.org/licenses/agpl-3.0.html',
    url: siteConfig.url,
    author: {
      '@type': 'Person',
      name: siteConfig.author.name,
    },
    offers: {
      '@type': 'Offer',
      price: '0',
      priceCurrency: 'USD',
    },
  };
};
