import React, { lazy, Suspense } from 'react';
import { createBrowserRouter, RouterProvider } from 'react-router-dom';

import LandingLayout from '@shared/components/layout/LandingLayout';
import DocumentationLayout from '@shared/components/layout/DocumentationLayout';
import ErrorPage from '@shared/pages/error/ErrorPage';
import LoadingSpinner from '@shared/components/ui/LoadingSpinner';

// ── Home (Landing) ────────────────────────────────────────────────
const HomePage = lazy(() => import('@pages/home/pages/index/LandingPage'));

// ── Documentation pages ───────────────────────────────────────────
const DocsHomePage      = lazy(() => import('@pages/docs/home/pages/index/HomePage'));
const InstallUpdatePage = lazy(() => import('@pages/docs/installation-update/InstallationUpdatePage'));
const MacPage = lazy(() => import('@pages/docs/client-applications/pages/mac/index/MacPage'));
const ApiPage           = lazy(() => import('@pages/docs/api/pages/index/ApiPage'));
const ArchitecturePage  = lazy(() => import('@pages/docs/architecture/pages/index/ArchitecturePage'));
const TeraziPage        = lazy(() => import('@pages/docs/architecture/pages/terazi/pages/index/TeraziPage'));
const MultihopPage      = lazy(() => import('@pages/docs/architecture/pages/multihop/pages/index/MultihopPage'));
const BackupPage        = lazy(() => import('@pages/docs/architecture/pages/backup/pages/index/BackupPage'));
const DatabasePage      = lazy(() => import('@pages/docs/architecture/pages/database/pages/index/DatabasePage'));
const BridgePage        = lazy(() => import('@pages/docs/architecture/pages/bridge/pages/index/BridgePage'));

// ── Tools pages ──────────────────────────────────────────────────
const IPCheckPage       = lazy(() => import('@pages/docs/tools/pages/ip-check/pages/index/IPCheckPage'));
const DnsLeakPage       = lazy(() => import('@pages/docs/tools/pages/dns-leak/pages/index/DnsLeakPage'));

// ── Privacy Policy ───────────────────────────────────────────────
const IOSPrivacyPage    = lazy(() => import('@pages/privacy-policy/pages/ios/IOSPrivacyPage'));

// ── Router ────────────────────────────────────────────────────────
const router = createBrowserRouter([
  // Home — www.phantom.tc/
  {
    path: '/',
    element: <LandingLayout />,
    errorElement: <ErrorPage />,
    children: [
      {
        index: true,
        element: <HomePage />,
      },
    ],
  },
  // Documentation — www.phantom.tc/docs/*
  {
    path: '/docs',
    element: <DocumentationLayout />,
    errorElement: <ErrorPage />,
    children: [
      {
        index: true,
        element: <DocsHomePage />,
      },
      {
        path: 'installation-update',
        element: <InstallUpdatePage />,
      },
      {
        path: 'client-applications/mac',
        element: <MacPage />,
      },
      {
        path: 'api',
        element: <ApiPage />,
      },
      {
        path: 'architecture',
        element: <ArchitecturePage />,
      },
      {
        path: 'architecture/terazi',
        element: <TeraziPage />,
      },
      {
        path: 'architecture/multihop',
        element: <MultihopPage />,
      },
      {
        path: 'architecture/backup',
        element: <BackupPage />,
      },
      {
        path: 'architecture/database',
        element: <DatabasePage />,
      },
      {
        path: 'architecture/bridge',
        element: <BridgePage />,
      },
      {
        path: 'tools/ip',
        element: <IPCheckPage />,
      },
      {
        path: 'tools/dns',
        element: <DnsLeakPage />,
      },
    ],
  },
  // Privacy Policy — www.phantom.tc/privacy-policy/ios
  {
    path: '/privacy-policy/ios',
    element: <DocumentationLayout />,
    errorElement: <ErrorPage />,
    children: [
      {
        index: true,
        element: <IOSPrivacyPage />,
      },
    ],
  },
]);

const AppRouter: React.FC = () => {
  return (
    <Suspense fallback={<LoadingSpinner fullscreen />}>
      <RouterProvider router={router} />
    </Suspense>
  );
};

export default AppRouter;
