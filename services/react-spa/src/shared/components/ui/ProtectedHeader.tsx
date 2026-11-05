import React, { useMemo } from 'react';
import { useNavigate, useLocation } from 'react-router-dom';
import {
  Header,
  HeaderContainer,
  HeaderName,
  HeaderMenuButton,
  HeaderNavigation,
  HeaderMenu,
  HeaderMenuItem,
  HeaderGlobalBar,
  HeaderGlobalAction,
  HeaderSideNavItems,
  SkipToContent,
  SideNav,
  SideNavItems,
  SideNavMenu,
  SideNavMenuItem,
  SideNavLink,
} from '@carbon/react';
import { Asleep, Close, Light, RotateClockwise } from '@carbon/icons-react';
import { useLocale, useTheme } from '@shared/hooks';
import { useAuth } from '@shared/contexts/AuthContext';
import { useUser } from '@shared/contexts/UserContext';
import { translate } from '@shared/translations';
import { filterByRole, type NavItem, type UserRole } from '@shared/types/nav';
import type { ProtectedNavContent } from '@shared/types/nav';
import FlagIcon from './FlagIcon';
import './styles/ThemeSwitcher.scss';

import navTr from '@shared/content/nav/tr/protected-nav.json';
import navEn from '@shared/content/nav/en/protected-nav.json';

const NAV_MAP: Record<string, ProtectedNavContent> = {
  tr: navTr as ProtectedNavContent,
  en: navEn as ProtectedNavContent,
};

interface RenderProps {
  isSideNavExpanded: boolean;
  onClickSideNavExpand: () => void;
}

const ProtectedHeader: React.FC = () => {
  const { locale, changeLocale } = useLocale();
  const { theme, toggleTheme, isThemeTransitioning } = useTheme();
  const { logout } = useAuth();
  const { user } = useUser();
  const navigate = useNavigate();
  const location = useLocation();
  const t = translate(locale);

  const role = (user?.role ?? 'admin') as UserRole;
  const raw = NAV_MAP[locale] ?? NAV_MAP.tr;

  const headerNav = useMemo(() => filterByRole(raw.headerNav, role), [raw, role]);
  const sideNav = useMemo(() => filterByRole(raw.sideNav, role), [raw, role]);

  const isActive = (href: string) =>
    href === '/'
      ? location.pathname === '/'
      : location.pathname === href || location.pathname.startsWith(href + '/');

  const hasActiveChild = (item: NavItem): boolean => {
    if (item.href && isActive(item.href)) return true;
    return item.children?.some((c) => hasActiveChild(c)) ?? false;
  };

  const nav = (e: React.MouseEvent, href: string, close?: () => void) => {
    e.preventDefault();
    navigate(href);
    close?.();
  };

  const handleLogout = async () => {
    await logout();
    navigate('/login');
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

            <HeaderName href="/" prefix="" onClick={(e: React.MouseEvent) => nav(e, '/')}>
              Phantom-WG
            </HeaderName>

            {/* Desktop — top navigation */}
            <HeaderNavigation aria-label={t.header.appName}>
              {headerNav.map((item) =>
                item.children ? (
                  <HeaderMenu
                    key={item.label}
                    aria-label={item.label}
                    menuLinkName={item.label}
                    isActive={hasActiveChild(item)}
                  >
                    {item.children.map((child) => (
                      <HeaderMenuItem
                        key={child.href}
                        href={child.href}
                        isActive={child.href ? isActive(child.href) : false}
                        onClick={(e: React.MouseEvent) => nav(e, child.href!)}
                      >
                        {child.label}
                      </HeaderMenuItem>
                    ))}
                  </HeaderMenu>
                ) : (
                  <HeaderMenuItem
                    key={item.href}
                    href={item.href}
                    isActive={item.href ? isActive(item.href) : false}
                    onClick={(e: React.MouseEvent) => nav(e, item.href!)}
                  >
                    {item.label}
                  </HeaderMenuItem>
                )
              )}
            </HeaderNavigation>

            <HeaderGlobalBar>
              <HeaderGlobalAction
                aria-label={theme === 'white' ? t.header.darkMode : t.header.lightMode}
                onClick={toggleTheme}
                className={`theme-switcher${isThemeTransitioning ? ' theme-transitioning' : ''}`}
                tooltipAlignment="end"
                data-testid="header-theme-toggle"
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
                onClick={() => changeLocale(locale === 'tr' ? 'en' : 'tr')}
                tooltipAlignment="end"
              >
                <FlagIcon locale={locale === 'tr' ? 'en' : 'tr'} size={20} />
              </HeaderGlobalAction>
              <HeaderGlobalAction
                aria-label={t.header.logout}
                onClick={handleLogout}
                tooltipAlignment="end"
                data-testid="header-logout"
              >
                <Close size={20} />
              </HeaderGlobalAction>
            </HeaderGlobalBar>

            {/* SideNav — persistent on desktop, overlay on mobile */}
            <SideNav
              aria-label="Side navigation"
              expanded={isSideNavExpanded}
              onSideNavBlur={onClickSideNavExpand}
            >
              <SideNavItems>
                {/* Mirror header nav for mobile via HeaderSideNavItems */}
                <HeaderSideNavItems hasDivider>
                  {headerNav.map((item) =>
                    item.children ? (
                      <HeaderMenu
                        key={`mobile-${item.label}`}
                        aria-label={item.label}
                        menuLinkName={item.label}
                        isActive={hasActiveChild(item)}
                      >
                        {item.children.map((child) => (
                          <HeaderMenuItem
                            key={`mobile-${child.href}`}
                            href={child.href}
                            isActive={child.href ? isActive(child.href) : false}
                            onClick={(e: React.MouseEvent) =>
                              nav(e, child.href!, onClickSideNavExpand)
                            }
                          >
                            {child.label}
                          </HeaderMenuItem>
                        ))}
                      </HeaderMenu>
                    ) : (
                      <HeaderMenuItem
                        key={`mobile-${item.href}`}
                        href={item.href}
                        isActive={item.href ? isActive(item.href) : false}
                        onClick={(e: React.MouseEvent) => nav(e, item.href!, onClickSideNavExpand)}
                      >
                        {item.label}
                      </HeaderMenuItem>
                    )
                  )}
                </HeaderSideNavItems>

                {/* SideNav-specific items (VPN actions) */}
                {sideNav.map((item) =>
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
                          data-testid={`nav${child.href!.replace(/\//g, '-')}`}
                          isActive={child.href ? isActive(child.href) : false}
                          onClick={(e: React.MouseEvent) =>
                            nav(e, child.href!, onClickSideNavExpand)
                          }
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
                      onClick={(e: React.MouseEvent) => nav(e, item.href!, onClickSideNavExpand)}
                    >
                      {item.label}
                    </SideNavLink>
                  )
                )}
              </SideNavItems>
            </SideNav>
          </Header>
        </>
      )}
    />
  );
};

export default ProtectedHeader;
