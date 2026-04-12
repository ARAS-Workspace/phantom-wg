import React, { lazy, Suspense } from 'react';
import type { DinoGameProps } from './DinoGame';
import LoadingSpinner from '@shared/components/ui/LoadingSpinner';
import { useIsClient } from '@shared/hooks/useIsClient';

// Real chunk split — DinoGame + engine are NOT in the initial bundle
const DinoGameLazy = lazy(() => import('./DinoGame'));

// .Lazy: prerender-safe with useIsClient + Suspense + LoadingSpinner
const DinoGameLazyWithSuspense: React.FC<DinoGameProps> = (props) => {
  const isClient = useIsClient();

  if (!isClient) {
    return <LoadingSpinner />;
  }

  return (
    <Suspense fallback={<LoadingSpinner />}>
      <DinoGameLazy {...props} />
    </Suspense>
  );
};

// Default export with .Lazy attached
const DinoGame = Object.assign(DinoGameLazyWithSuspense, {
  Lazy: DinoGameLazyWithSuspense,
});

export default DinoGame;
