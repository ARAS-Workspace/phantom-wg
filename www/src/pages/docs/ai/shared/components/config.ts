/**
 * Build-time configuration for the AI worker (ai-worker.phantom.tc).
 *
 * Dev builds fall back to the local worker and Turnstile's always-passing
 * test key — the same convention as the tools' check config — so `npm run
 * dev` against a local `wrangler dev` needs no env file. A production build
 * carries no fallbacks on purpose: without the real values the page renders
 * its prose but not a broken widget (see `isAiChatConfigured`).
 */

/** Worker origin for this build. */
export const AI_WORKER_ENDPOINT: string = import.meta.env.DEV
  ? ((import.meta.env.VITE_PHANTOM_AI_ENDPOINT as string | undefined) ?? 'http://localhost:8792')
  : (import.meta.env.VITE_PHANTOM_AI_ENDPOINT as string);

/** Turnstile site key (visible managed widget). */
export const TURNSTILE_SITE_KEY: string = import.meta.env.DEV
  ? ((import.meta.env.VITE_PHANTOM_AI_TURNSTILE_SITE_KEY as string | undefined) ?? '1x00000000000000000000AA')
  : (import.meta.env.VITE_PHANTOM_AI_TURNSTILE_SITE_KEY as string);

/** Worker routes. */
export const AI_WORKER_ROUTES = {
  session: '/api/v1/session',
  chat: '/api/v1/chat',
} as const;

/**
 * Whether the chat can run at all. A build without the env vars renders the
 * page's prose but not a broken widget.
 */
export const isAiChatConfigured = (): boolean =>
  Boolean(AI_WORKER_ENDPOINT) && Boolean(TURNSTILE_SITE_KEY);
