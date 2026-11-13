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
