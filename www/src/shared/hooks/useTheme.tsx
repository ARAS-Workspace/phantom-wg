import React, {
  createContext,
  useContext,
  useState,
  useCallback,
  useMemo,
  useEffect,
  ReactNode,
} from 'react';

export type AppTheme = 'white' | 'g100';

interface ThemeContextValue {
  theme: AppTheme;
  toggleTheme: () => void;
  isThemeTransitioning: boolean;
}

const ThemeContext = createContext<ThemeContextValue | undefined>(undefined);

const VALID_THEMES: AppTheme[] = ['white', 'g100'];
const DEFAULT_THEME: AppTheme = 'white';

export const ThemeProvider: React.FC<{ children: ReactNode }> = ({ children }) => {
  const [theme, setTheme] = useState<AppTheme>(() => {
    try {
      // 1. URL parameter (pre-rendering control)
      const urlTheme = new URLSearchParams(window.location.search).get('theme');
      if (urlTheme && VALID_THEMES.includes(urlTheme as AppTheme)) {
        return urlTheme as AppTheme;
      }

      // 2. Cookie (user explicit choice - persistent)
      const cookieTheme = document.cookie.match(/preferred_theme=(white|g100)/)?.[1];
      if (cookieTheme && VALID_THEMES.includes(cookieTheme as AppTheme)) {
        return cookieTheme as AppTheme;
      }

      // 3. HTML data-carbon-theme attribute (server/worker decision)
      const htmlTheme = document.documentElement.getAttribute('data-carbon-theme');
      if (htmlTheme && VALID_THEMES.includes(htmlTheme as AppTheme)) {
        return htmlTheme as AppTheme;
      }

      // 4. Default
      return DEFAULT_THEME;
    } catch {
      return DEFAULT_THEME;
    }
  });

  const [isThemeTransitioning, setIsThemeTransitioning] = useState(false);

  const toggleTheme = useCallback(() => {
    if (isThemeTransitioning) return;

    setIsThemeTransitioning(true);
    const newTheme = theme === 'white' ? 'g100' : 'white';
    setTheme(newTheme);

    try {
      document.cookie = `preferred_theme=${newTheme}; path=/; max-age=31536000; SameSite=Lax`;
      document.documentElement.setAttribute('data-carbon-theme', newTheme);
    } catch {
      // Silent fail
    }

    setTimeout(() => {
      setIsThemeTransitioning(false);
    }, 800);
  }, [theme, isThemeTransitioning]);

  useEffect(() => {
    document.documentElement.setAttribute('data-carbon-theme', theme);
  }, [theme]);

  const value = useMemo(
    () => ({ theme, toggleTheme, isThemeTransitioning }),
    [theme, toggleTheme, isThemeTransitioning]
  );

  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>;
};

export const useTheme = (): ThemeContextValue => {
  const context = useContext(ThemeContext);
  if (!context) {
    throw new Error('useTheme must be used within ThemeProvider');
  }
  return context;
};
