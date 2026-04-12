import en from './en/index.json';
import tr from './tr/index.json';

export type Locale = 'en' | 'tr';

export const DEFAULT_LOCALE: Locale = 'en';

export const translations: Record<Locale, typeof en> = { en, tr };

export const translate = (locale: Locale) => {
  return translations[locale] || translations[DEFAULT_LOCALE];
};
