/**
 * Recover a tab whose module graph outlived the deployment that produced it.
 *
 * Every route is a `React.lazy` dynamic import, so a click fetches a
 * content-hashed chunk by name long after the document that named it loaded. A
 * deploy rotates those names — a chunk's name is written literally into its
 * importers' import statements, so a single edit cascades upward through every
 * importer chain (measured on a sibling repository with the same build setup,
 * editing four files rotated 123 of 534 chunk filenames). The file the open
 * tab then asks for is no longer served.
 *
 * No cache header reaches this. The failing request is not a document request,
 * so nothing revalidates: the document was fetched an hour ago and the browser
 * has no reason to ask about it again until the reader navigates.
 *
 * Vite dispatches `vite:preloadError` for exactly this case and rethrows unless
 * a listener cancels it. We deliberately do not cancel. Reloading is what fixes
 * a stale graph, and on the occasions it cannot happen the error should still
 * reach the router's error page rather than leave a dead screen behind a
 * spinner.
 *
 * This protects a tab only if its entry chunk already contains it — that is,
 * from the deploy after the one that ships it.
 */

/** How long one recorded attempt suppresses another for the same path. */
const RETRY_WINDOW_MS = 10 * 60 * 1000;

const STORAGE_PREFIX = 'chunk-reload:';

type Decision = { reload: true } | { reload: false; reason: string };

/**
 * Whether to reload, and why not when the answer is no.
 *
 * The record lives in `sessionStorage` rather than a module variable because it
 * has to survive the very reload it guards — an in-memory flag is wiped by the
 * navigation and would let the loop run forever. When storage cannot be read or
 * written we refuse to reload at all: without somewhere to remember the attempt
 * there is no way to stop at one, and an endless reload is much worse than an
 * error page.
 */
function decide(key: string): Decision {
  let previous: string | null;
  try {
    previous = window.sessionStorage.getItem(key);
  } catch {
    return { reload: false, reason: 'session storage cannot be read, so a second attempt could not be prevented' };
  }

  // A malformed value yields NaN, and the comparison is then false — erring
  // towards one reload, which the write below immediately makes guardable.
  if (previous !== null && Date.now() - Number(previous) < RETRY_WINDOW_MS) {
    return { reload: false, reason: 'this path was reloaded once already and failed again' };
  }

  try {
    window.sessionStorage.setItem(key, String(Date.now()));
  } catch {
    return { reload: false, reason: 'the attempt could not be recorded, so a second one could not be prevented' };
  }

  return { reload: true };
}

/**
 * Listen for failed dynamic imports and reload the document once.
 *
 * Call once, before the app renders — the listener has to be in place before
 * the first lazy route is reached.
 */
export function installChunkReloadGuard(): void {
  window.addEventListener('vite:preloadError', (event) => {
    // Being offline is a different failure wearing the same symptom, and
    // reloading would trade an error page that explains itself for the
    // browser's offline screen. `onLine === false` is only ever a definite no;
    // `true` promises nothing, which is why it is not treated as a green light.
    if (!window.navigator.onLine) {
      console.warn('[chunk-reload] not reloading: the browser reports no network', event.payload);
      return;
    }

    // The pathname is already the destination by this point: the router commits
    // the navigation, renders the route element, and only then does React
    // suspend on the import that fails.
    const decision = decide(`${STORAGE_PREFIX}${window.location.pathname}`);
    if (!decision.reload) {
      console.warn(`[chunk-reload] not reloading: ${decision.reason}`, event.payload);
      return;
    }

    console.warn('[chunk-reload] this tab expects a chunk that is no longer deployed — reloading', event.payload);
    window.location.reload();
  });
}
