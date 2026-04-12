import { useState, useEffect } from 'react';

/**
 * useIsClient Hook
 *
 * Returns false during pre-rendering (?__prerendering=true), true in client browser.
 * Used to wrap components that cause hydration mismatches (Mermaid, DinoGame, CodeHighlight).
 */
export function useIsClient(): boolean {
  const [isClient, setIsClient] = useState(false);

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const isPrerendering = params.get('__prerendering') === 'true';

    if (!isPrerendering) {
      setIsClient(true);
    }
  }, []);

  return isClient;
}
