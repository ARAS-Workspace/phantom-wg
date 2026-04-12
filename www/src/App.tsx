import React from 'react';
import { Theme } from '@carbon/react';
import { LocaleProvider, ThemeProvider, useTheme } from '@shared/hooks';
import { SEOProvider } from '@shared/contexts/SEOContext';
import AppRouter from './router';

const AppContent: React.FC = () => {
  const { theme } = useTheme();

  return (
    <Theme theme={theme}>
      <div className="app">
        <AppRouter />
      </div>
    </Theme>
  );
};

const App: React.FC = () => {
  return (
    <LocaleProvider>
      <ThemeProvider>
        <SEOProvider>
          <AppContent />
        </SEOProvider>
      </ThemeProvider>
    </LocaleProvider>
  );
};

export default App;
