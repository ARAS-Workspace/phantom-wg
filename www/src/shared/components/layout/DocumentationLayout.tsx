import React from 'react';
import { Outlet, useLocation, useNavigate } from 'react-router-dom';
import {
  Content,
  Header,
  HeaderContainer,
  HeaderName,
  HeaderMenuButton,
  HeaderNavigation,
  HeaderMenuItem,
  HeaderGlobalBar,
  HeaderGlobalAction,
  HeaderSideNavItems,
  SkipToContent,
  SideNav,
  SideNavItems,
  SideNavLink,
  SideNavMenu,
  SideNavMenuItem,
} from '@carbon/react';
import { Asleep, Light, RotateClockwise } from '@carbon/icons-react';

import { useTheme } from '@shared/hooks/useTheme';
import { useLocale } from '@shared/hooks/useLocale';
import { translate } from '@shared/translations';
import FlagIcon from '@shared/components/ui/FlagIcon';
import type { NavItem, DocsNavContent } from '@shared/types/nav';
import Footer from './Footer';

import navTr from '@shared/content/nav/tr/docs-nav.json';
import navEn from '@shared/content/nav/en/docs-nav.json';

import './styles/DocumentationLayout.scss';
import '../ui/styles/ThemeSwitcher.scss';

const NAV_MAP: Record<string, DocsNavContent> = {
  tr: navTr as DocsNavContent,
  en: navEn as DocsNavContent,
};

interface RenderProps {
  isSideNavExpanded: boolean;
  onClickSideNavExpand: () => void;
}

const DocumentationLayout: React.FC = () => {
  const { theme, toggleTheme, isThemeTransitioning } = useTheme();
  const { locale, changeLocale } = useLocale();
  const location = useLocation();
  const navigate = useNavigate();
  const t = translate(locale);

  const raw = NAV_MAP[locale] ?? NAV_MAP.en;

  const handleLocaleToggle = () => {
    changeLocale(locale === 'en' ? 'tr' : 'en');
  };

  // Normalize trailing slash for consistent comparison
  const normalizedPath = location.pathname.replace(/\/$/, '') || '/';

  // Exact match only — parent menu uses hasActiveChild
  const isActive = (href: string) => normalizedPath === (href.replace(/\/$/, '') || '/');

  const hasActiveChild = (item: NavItem): boolean => {
    if (item.href && isActive(item.href)) return true;
    return item.children?.some((c) => hasActiveChild(c)) ?? false;
  };

  const nav = (e: React.MouseEvent, item: NavItem, close?: () => void) => {
    if (item.external) return;
    e.preventDefault();
    if (item.href) navigate(item.href);
    close?.();
  };

  return (
    <HeaderContainer
      render={({ isSideNavExpanded, onClickSideNavExpand }: RenderProps) => (
        <>
          <Header aria-label={t.header.appName}>
            <SkipToContent href="#main-content" />

            <HeaderMenuButton
              aria-label={isSideNavExpanded ? 'Close menu' : 'Open menu'}
              onClick={onClickSideNavExpand}
              isActive={isSideNavExpanded}
            />

            <HeaderName href="/" prefix="" onClick={(e: React.MouseEvent) => { e.preventDefault(); navigate('/'); }}>
              {t.header.appName}
            </HeaderName>

            {/* Desktop — top navigation */}
            <HeaderNavigation aria-label={t.header.appName}>
              {raw.headerNav.map((item) => (
                <HeaderMenuItem
                  key={item.label}
                  href={item.href}
                  onClick={(e: React.MouseEvent) => nav(e, item)}
                  {...(item.external ? { target: '_blank', rel: 'noopener noreferrer' } : {})}
                >
                  {item.label}
                </HeaderMenuItem>
              ))}
            </HeaderNavigation>

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
                onClick={handleLocaleToggle}
                tooltipAlignment="end"
              >
                <FlagIcon locale={locale === 'en' ? 'tr' : 'en'} size={20} />
              </HeaderGlobalAction>
            </HeaderGlobalBar>

            {/* SideNav — persistent on desktop, overlay on mobile */}
            <SideNav
              aria-label="Navigation"
              expanded={isSideNavExpanded}
              onSideNavBlur={onClickSideNavExpand}
            >
              <SideNavItems>
                {/* Mirror header nav for mobile */}
                <HeaderSideNavItems hasDivider>
                  {raw.headerNav.map((item) => (
                    <HeaderMenuItem
                      key={`mobile-${item.label}`}
                      href={item.href}
                      onClick={(e: React.MouseEvent) => nav(e, item, onClickSideNavExpand)}
                      {...(item.external ? { target: '_blank', rel: 'noopener noreferrer' } : {})}
                    >
                      {item.label}
                    </HeaderMenuItem>
                  ))}
                </HeaderSideNavItems>

                {/* SideNav items */}
                {raw.sideNav.map((item) =>
                  item.children ? (
                    <SideNavMenu
                      key={item.label}
                      title={item.label}
                      isActive={hasActiveChild(item)}
                      defaultExpanded={hasActiveChild(item) || (item.defaultExpanded ?? false)}
                    >
                      {item.children.map((child) => (
                        <SideNavMenuItem
                          key={child.href}
                          href={child.href}
                          isActive={child.href ? isActive(child.href) : false}
                          onClick={(e: React.MouseEvent) => nav(e, child, onClickSideNavExpand)}
                        >
                          {child.label}
                        </SideNavMenuItem>
                      ))}
                    </SideNavMenu>
                  ) : (
                    <SideNavLink
                      key={item.href}
                      href={item.href}
                      isActive={item.href ? isActive(item.href) : false}
                      onClick={(e: React.MouseEvent) => nav(e, item, onClickSideNavExpand)}
                    >
                      {item.label}
                    </SideNavLink>
                  )
                )}
              </SideNavItems>
            </SideNav>
          </Header>

          <Content id="main-content" className="docs-content">
            <Outlet />
          </Content>

          <Footer />
        </>
      )}
    />
  );
};

export default DocumentationLayout;
