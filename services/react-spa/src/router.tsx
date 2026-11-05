import React from 'react';
import { createBrowserRouter, RouterProvider, Navigate } from 'react-router-dom';
import { useAuth } from '@shared/contexts/AuthContext';
import { useUser } from '@shared/contexts/UserContext';
import LoadingSpinner from '@shared/components/ui/LoadingSpinner';
import ProtectedLayout from '@shared/components/layout/ProtectedLayout';
import PublicLayout from '@shared/components/layout/PublicLayout';
import ErrorPage from '@shared/pages/error/ErrorPage';

// ── public ────────────────────────────────────────────────────────
import LoginPage from '@pages/login/LoginPage';

// ── account ───────────────────────────────────────────────────────
import DashboardPage from '@pages/dashboard/pages/index/DashboardPage';
import TotpPage from '@pages/account/totp/pages/index/TotpPage';
import TotpEnablePage from '@pages/account/totp/pages/enable/TotpEnablePage';
import TotpDisablePage from '@pages/account/totp/pages/disable/TotpDisablePage';
import PasswordChangePage from '@pages/account/password-change/pages/index/PasswordChangePage';

// ── admin ─────────────────────────────────────────────────────────
import UsersPage from '@pages/admin/users/pages/index/UsersPage';
import AuditPage from '@pages/admin/audit/pages/index/AuditPage';

// ── vpn ───────────────────────────────────────────────────────────
import ClientsPage from '@pages/vpn/clients/pages/index/ClientsPage';
import WireGuardPage from '@pages/vpn/wireguard/pages/index/WireGuardPage';
import FirewallPage from '@pages/vpn/firewall/pages/index/FirewallPage';
import DnsPage from '@pages/vpn/dns/pages/index/DnsPage';
import NetworkPage from '@pages/vpn/network/pages/index/NetworkPage';
import BackupPage from '@pages/vpn/backup/pages/index/BackupPage';
import MultihopPage from '@pages/vpn/multihop/pages/index/MultihopPage';

// ── Route guards ──────────────────────────────────────────────────

const ProtectedRoute: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const { isAuthenticated, initializing } = useAuth();

  if (initializing) return <LoadingSpinner fullscreen />;
  if (!isAuthenticated) return <Navigate to="/login" replace />;
  return <>{children}</>;
};

const SuperadminRoute: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const { isSuperadmin } = useUser();

  if (!isSuperadmin) return <Navigate to="/" replace />;
  return <>{children}</>;
};

const PublicRoute: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const { isAuthenticated, initializing } = useAuth();

  if (initializing) return <LoadingSpinner fullscreen />;
  if (isAuthenticated) return <Navigate to="/" replace />;
  return <>{children}</>;
};

// ── Router ────────────────────────────────────────────────────────

const router = createBrowserRouter([
  // Public
  {
    element: (
      <PublicRoute>
        <PublicLayout />
      </PublicRoute>
    ),
    children: [{ path: '/login', element: <LoginPage /> }],
  },

  // Protected
  {
    element: (
      <ProtectedRoute>
        <ProtectedLayout />
      </ProtectedRoute>
    ),
    children: [
      // account
      { path: '/', element: <DashboardPage /> },
      { path: '/account/totp', element: <TotpPage /> },
      { path: '/account/totp/enable', element: <TotpEnablePage /> },
      { path: '/account/totp/disable', element: <TotpDisablePage /> },
      { path: '/account/password-change', element: <PasswordChangePage /> },

      // admin
      { path: '/admin/users', element: <UsersPage /> },
      { path: '/admin/audit', element: <AuditPage /> },

      // vpn
      { path: '/vpn/clients', element: <ClientsPage /> },
      { path: '/vpn/wireguard', element: <WireGuardPage /> },
      { path: '/vpn/firewall', element: <FirewallPage /> },
      { path: '/vpn/dns', element: <DnsPage /> },
      { path: '/vpn/network', element: <NetworkPage /> },
      {
        path: '/vpn/backup',
        element: (
          <SuperadminRoute>
            <BackupPage />
          </SuperadminRoute>
        ),
      },
      { path: '/vpn/multihop', element: <MultihopPage /> },

    ],
  },

  // Error pages
  { path: '*', element: <ErrorPage /> },
]);

const AppRouter: React.FC = () => <RouterProvider router={router} />;

export default AppRouter;
