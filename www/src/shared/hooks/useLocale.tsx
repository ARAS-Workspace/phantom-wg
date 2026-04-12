import React, { createContext, useContext, useState, useCallback, useMemo, ReactNode } from 'react';
import { DEFAULT_LOCALE, type Locale, translations } from '@shared/translations';

interface LocaleContextValue {
  locale: Locale;
  changeLocale: (newLocale: Locale) => void;
}

const LocaleContext = createContext<LocaleContextValue | undefined>(undefined);

export const LocaleProvider: React.FC<{ children: ReactNode }> = ({ children }) => {
  const [locale, setLocale] = useState<Locale>(() => {
    try {
      // 1. URL parameter (pre-rendering control)
      const urlLocale = new URLSearchParams(window.location.search).get('locale');
      if (urlLocale && urlLocale in translations) return urlLocale as Locale;

      // 2. Cookie (user explicit choice - persistent)
      const cookieLocale = document.cookie.match(/preferred_locale=(\w+)/)?.[1];
      if (cookieLocale && cookieLocale in translations) return cookieLocale as Locale;

      // 3. HTML lang attribute (server/worker decision)
      const htmlLang = document.documentElement.getAttribute('lang');
      if (htmlLang && htmlLang in translations) return htmlLang as Locale;

      // 4. Browser language fallback
      const browserLang = navigator.language.split('-')[0];
      if (browserLang in translations) return browserLang as Locale;

      // 5. Default
      return DEFAULT_LOCALE;
    } catch {
      return DEFAULT_LOCALE;
    }
  });

  document.documentElement.lang = locale;

  const changeLocale = useCallback((newLocale: Locale) => {
    setLocale(newLocale);
    document.documentElement.lang = newLocale;
    try {
      const maxAge = 60 * 60 * 24 * 365;
      const secure = window.location.protocol === 'https:' ? '; Secure' : '';
      document.cookie = `preferred_locale=${newLocale}; Path=/; Max-Age=${maxAge}; SameSite=Lax${secure}`;
    } catch (error) {
      console.warn('Failed to set cookie:', error);
    }
  }, []);

  const value = useMemo(() => ({ locale, changeLocale }), [locale, changeLocale]);

  return <LocaleContext.Provider value={value}>{children}</LocaleContext.Provider>;
};

export const useLocale = (): LocaleContextValue => {
  const context = useContext(LocaleContext);
  if (!context) {
    throw new Error('useLocale must be used within LocaleProvider');
  }
  return context;
};
