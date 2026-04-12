import React from 'react';
import { Outlet, useNavigate } from 'react-router-dom';
import {
  Content,
  Header,
  HeaderName,
  HeaderGlobalBar,
  HeaderGlobalAction,
  SkipToContent,
} from '@carbon/react';
import { Asleep, Light, RotateClockwise } from '@carbon/icons-react';

import { useTheme } from '@shared/hooks/useTheme';
import { useLocale } from '@shared/hooks/useLocale';
import { translate } from '@shared/translations';
import FlagIcon from '@shared/components/ui/FlagIcon';
import Footer from './Footer';

import '../ui/styles/ThemeSwitcher.scss';

const LandingLayout: React.FC = () => {
  const { theme, toggleTheme, isThemeTransitioning } = useTheme();
  const { locale, changeLocale } = useLocale();
  const navigate = useNavigate();
  const t = translate(locale);

  return (
    <>
      <Header aria-label={t.header.appName}>
        <SkipToContent href="#main-content" />

        <HeaderName href="/" prefix="" onClick={(e: React.MouseEvent) => { e.preventDefault(); navigate('/'); }}>
          {t.header.appName}
        </HeaderName>

        <HeaderGlobalBar>
          <HeaderGlobalAction
            aria-label={theme === 'white' ? t.header.darkMode : t.header.lightMode}
            onClick={toggleTheme}
            className={`theme-switcher${isThemeTransitioning ? ' theme-transitioning' : ''}`}
            tooltipAlignment="end"
          >
            {isThemeTransitioning ? (
              <RotateClockwise size={20} className="spinner-icon" />
            ) : theme === 'white' ? (
              <Asleep size={20} />
            ) : (
              <Light size={20} />
            )}
          </HeaderGlobalAction>
          <HeaderGlobalAction
            aria-label={t.language.switchTo}
            onClick={() => changeLocale(locale === 'en' ? 'tr' : 'en')}
            tooltipAlignment="end"
          >
            <FlagIcon locale={locale === 'en' ? 'tr' : 'en'} size={20} />
          </HeaderGlobalAction>
        </HeaderGlobalBar>
      </Header>

      <Content id="main-content" className="landing-content">
        <Outlet />
      </Content>

      <Footer />
    </>
  );
};

export default LandingLayout;
