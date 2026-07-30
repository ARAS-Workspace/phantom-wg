/**
 * Cloudflare Turnstile browser API — the visible managed widget, rendered
 * explicitly. Solved once per session: the token is exchanged for the
 * worker's own session token, so it never rides along with chat messages.
 */

interface TurnstileRenderOptions {
  sitekey: string;
  theme?: 'light' | 'dark' | 'auto';
  callback?: (token: string) => void;
  'error-callback'?: () => void;
  'expired-callback'?: () => void;
}

interface TurnstileAPI {
  render: (container: HTMLElement | string, options: TurnstileRenderOptions) => string;
  reset: (widgetId?: string) => void;
  remove: (widgetId: string) => void;
}

declare global {
  interface Window {
    turnstile?: TurnstileAPI;
    onTurnstileLoadCallback?: () => void;
  }
}

const SCRIPT_URL =
  'https://challenges.cloudflare.com/turnstile/v0/api.js?onload=onTurnstileLoadCallback';

/** How long to wait for the API before calling the load a failure. */
const LOAD_TIMEOUT_MS = 10_000;

/**
 * Load the Turnstile script once and run `onReady` when the API is available.
 * Safe to call from several components: an existing script tag is reused and
 * only the load callback is re-pointed.
 *
 * `onFailure` matters as much as `onReady` — a blocked or unreachable script
 * would otherwise leave the gate sitting empty forever with nothing to tell
 * the visitor why.
 *
 * Returns a disposer. Both things this leaves behind outlive the caller — a
 * global callback the script will invoke whenever it finishes loading, and a
 * timer that reports failure — so a component that unmounts before the API
 * arrives has to be able to take them back.
 *
 * @example useEffect(() => loadTurnstile(renderWidget, showGateError), [...]);
 */
export function loadTurnstile(onReady: () => void, onFailure: () => void): () => void {
  if (typeof window === 'undefined') return () => {};

  if (window.turnstile) {
    onReady();
    return () => {};
  }

  // The API can take a moment even on a good connection; this only fires when
  // it never arrives at all.
  const timeout = window.setTimeout(() => {
    if (!window.turnstile) onFailure();
  }, LOAD_TIMEOUT_MS);
  const installed = (): void => {
    window.clearTimeout(timeout);
    onReady();
  };
  window.onTurnstileLoadCallback = installed;

  const dispose = (): void => {
    window.clearTimeout(timeout);
    // Compared by identity, not by presence: a later caller may already have
    // replaced the callback, and clearing whatever happens to be installed
    // would leave that caller waiting for a script event that never reaches it.
    if (window.onTurnstileLoadCallback === installed) window.onTurnstileLoadCallback = undefined;
  };

  const existing = document.querySelector('script[src*="challenges.cloudflare.com/turnstile"]');
  if (existing) return dispose;

  const script = document.createElement('script');
  script.src = SCRIPT_URL;
  script.async = true;
  script.defer = true;
  script.onerror = () => {
    window.clearTimeout(timeout);
    onFailure();
  };
  document.body.appendChild(script);

  return dispose;
}
