// Injected from config.yaml during build
// noinspection JSUnresolvedVariable,JSUnresolvedReference

const LOCALES = __LOCALES__;
const DEFAULT_LOCALE = __DEFAULT_LOCALE__;
const THEMES = __THEMES__;
const DEFAULT_THEME = __DEFAULT_THEME__;

// ─────────────────────────────────────────────────────────────────────────────
// phantom.tc edge worker. Every request flows through six stages, in order:
//
//   0. negotiation           locale (query → cookie → default), theme (cookie)
//   1. llms endpoints        <route>/llms.txt, /llms-full.txt → negotiated markdown
//   2. static files          any dotted path; /assets/* misses become real 404s
//   3. markdown negotiation  Accept: text/markdown → this page's llms text
//   4. the document          index[.theme][.locale].html fallback chain
//   5. SPA fallback          unknown paths get the shell; the app renders its 404
//
// The order is correctness, not style: llms paths end in `.txt`, so stage 2
// would swallow them if it ran first.
//
// Two response philosophies meet here, deliberately. Where the consumer is a
// machine (stages 1 and 2) the protocol speaks: a miss is a genuine 404,
// because agents read status codes, not rendered pages. Where the consumer is
// a person (stage 5) the application speaks: the server answers "the app
// exists" and the content layer renders the not-found page, navigation intact.
//
// This contract is executable: scripts/test-worker.js asserts it stage by
// stage against the built dist/ running under `wrangler pages dev`.
// ─────────────────────────────────────────────────────────────────────────────

// ── Cache policy ─────────────────────────────────────────────────────────────
// A URL either names its bytes forever or it does not. Content-hashed build
// output cannot change under its URL → cache it for a year. Everything a
// deploy rewrites in place — HTML, llms markdown, sitemap, public images —
// must be revalidated, or a stale document would point at hashed chunks the
// new deploy has already purged. `no-cache` is "store, but ask first": with
// ETags that is a 304, not a re-download.

const IMMUTABLE = 'public, max-age=31536000, immutable';
const REVALIDATE = 'no-cache';

/**
 * Only Vite's hashed output lives at `/assets/*.{js,css,woff2}` (public/ ships
 * images, svg and the install cast there, never these), so that pattern is a
 * safe immutable signal; anything else revalidates. Widen the extension group
 * only together with everything that mirrors this contract in the build tooling.
 * @param {string} pathname
 * @returns {string}
 */
function assetCacheControl(pathname) {
  return /^\/assets\/.+\.(js|css|woff2)$/i.test(pathname) ? IMMUTABLE : REVALIDATE;
}

// ── Negotiation ──────────────────────────────────────────────────────────────
// One symmetric helper per preference, each validating against the injected
// config so config.yaml stays the single authority on what exists. Both are
// pure: the same request always negotiates the same answer.

/**
 * Explicit `?locale=` wins, then the `preferred_locale` cookie, then the
 * default. Agents send no cookie, so the query param is their lever; the
 * cookie is the human's persistent choice.
 * @param {URL} url
 * @param {Request} request
 * @returns {string}
 */
function detectLocale(url, request) {
  const queryLocale = url.searchParams.get('locale');
  if (queryLocale && LOCALES.includes(queryLocale)) return queryLocale;
  const cookieLocale = (request.headers.get('cookie') || '').match(/preferred_locale=(\w+)/)?.[1];
  if (cookieLocale && LOCALES.includes(cookieLocale)) return cookieLocale;
  return DEFAULT_LOCALE;
}

/**
 * Cookie only — no query lever on purpose: a shared link should not force the
 * sender's colours on the reader the way it may fix the language.
 * @param {Request} request
 * @returns {string}
 */
function detectTheme(request) {
  const cookieTheme = (request.headers.get('cookie') || '').match(/preferred_theme=(\w+)/)?.[1];
  if (cookieTheme && THEMES.includes(cookieTheme)) return cookieTheme;
  return DEFAULT_THEME;
}

// ── Markdown lookup ──────────────────────────────────────────────────────────

/**
 * Serve `<dir>/<locale>.txt` as markdown, falling back to the default locale's
 * file. Returns null on a miss so each caller decides what a miss means: an
 * explicit `.txt` request 404s, a negotiated page request falls through to HTML.
 * @param {{ ASSETS: { fetch: (input: string) => Promise<Response> } }} env
 * @param {URL} url
 * @param {string} locale  Already negotiated by the caller.
 * @param {string} dir  Asset directory holding `<locale>.txt`, e.g. `/docs/api/llms`.
 * @returns {Promise<Response|null>}
 */
async function tryServeMarkdown(env, url, locale, dir) {
  const wanted = `${dir}/${locale}.txt`;
  const base = `${dir}/${DEFAULT_LOCALE}.txt`;
  for (const p of [wanted, base]) {
    const r = await env.ASSETS.fetch(new URL(p, url.origin).toString());
    // Pages answers a missing asset with the SPA shell (200 HTML), so a real
    // hit must not be HTML — otherwise the app shell ships as markdown.
    if (r.status === 200 && !/text\/html/i.test(r.headers.get('content-type') || '')) {
      const headers = new Headers(r.headers);
      headers.set('Content-Type', 'text/markdown; charset=utf-8');
      // Names the locale actually served, not the one asked for.
      headers.set('Content-Language', p === wanted ? locale : DEFAULT_LOCALE);
      headers.set('Vary', 'Accept, Cookie');
      // Regenerated every deploy — agents must never read a stale dump.
      headers.set('Cache-Control', REVALIDATE);
      return new Response(r.body, { status: 200, headers });
    }
  }
  return null;
}

// noinspection JSUnusedGlobalSymbols
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const pathname = url.pathname;

    // ── 0. Negotiation ───────────────────────────────────────────────────────
    // Once, up front; every stage below reads these and none re-negotiates.
    const locale = detectLocale(url, request);
    const theme = detectTheme(request);

    // ── 1. llms endpoints ────────────────────────────────────────────────────
    // `<name>.txt` maps to `<name>/<locale>.txt`: per-page files live at
    // `<route>/llms/<locale>.txt`, the concatenated dump at `/llms-full/…`.
    // A miss is an explicit text 404 — falling through would hand the request
    // to the SPA shell, a 200 no browser can render as .txt.
    if (pathname.endsWith('/llms.txt') || pathname.endsWith('/llms-full.txt')) {
      const md = await tryServeMarkdown(env, url, locale, pathname.replace(/\.txt$/, ''));
      if (md) return md;
      return new Response('Not Found\n', {
        status: 404,
        headers: { 'Content-Type': 'text/plain; charset=utf-8' },
      });
    }

    // ── 2. Static files ──────────────────────────────────────────────────────
    // Any dotted path that is not a document. The gate is a heuristic, and it
    // makes one demand of the rest of the site: routes and slugs stay
    // dot-free, or they are misread as files and skip the document chain.
    if (pathname.includes('.') && !pathname.endsWith('.html')) {
      const res = await env.ASSETS.fetch(request);

      // Under /assets/ a miss must be a real, uncacheable 404. Pages answers
      // it with the SPA shell instead, and stamping that shell with the
      // asset's Cache-Control would pin HTML under a hashed .js URL as
      // immutable for a year — the loader would MIME-reject it on every later
      // load. `no-store` because a miss must not be remembered: the file may
      // exist one deploy later. A 200/206/304 for a real file passes through
      // untouched — revalidations and range requests must not be swallowed.
      const isBuildAsset = pathname.startsWith('/assets/');
      const isHtmlShell = /text\/html/i.test(res.headers.get('content-type') || '');
      if (isBuildAsset && (res.status >= 400 || isHtmlShell)) {
        return new Response('Not Found\n', {
          status: 404,
          headers: {
            'Content-Type': 'text/plain; charset=utf-8',
            'Cache-Control': 'no-store',
          },
        });
      }

      const headers = new Headers(res.headers);
      headers.set('Cache-Control', assetCacheControl(pathname));
      return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
    }

    // ── 3. Markdown negotiation ──────────────────────────────────────────────
    // An agent that asks for markdown gets this page's llms text at the same
    // URL. Browsers never send `text/markdown`, and a bare `*/*` is no
    // preference — HTML stays the page's primary representation. A route
    // without llms/ falls through too: serving what we have beats a 406.
    if ((request.headers.get('accept') || '').includes('text/markdown')) {
      const dir = pathname === '/' ? '/llms' : `${pathname.replace(/\/$/, '')}/llms`;
      const md = await tryServeMarkdown(env, url, locale, dir);
      if (md) return md;
    }

    // ── 4. The document ──────────────────────────────────────────────────────
    // Pattern: index[.theme][.locale].html, most specific first. Locale
    // outranks theme on a partial miss — the wrong colours in the right
    // language beat the right colours in the wrong one. Each candidate carries
    // the locale its file actually holds, so Content-Language reports what was
    // served even when the chain falls back. Prerender emits every variant
    // today; the tail is insurance, not a code path.
    const basePath = pathname === '/' ? '/index' : `${pathname.replace(/\/$/, '')}/index`;
    const themeSuffix = theme === DEFAULT_THEME ? '' : `.${theme}`;
    const localeSuffix = locale === DEFAULT_LOCALE ? '' : `.${locale}`;

    const candidates = [
      { path: `${basePath}${themeSuffix}${localeSuffix}.html`, serves: locale },
      { path: `${basePath}${localeSuffix}.html`, serves: locale },
      { path: `${basePath}${themeSuffix}.html`, serves: DEFAULT_LOCALE },
      { path: `${basePath}.html`, serves: DEFAULT_LOCALE },
    ];

    for (const candidate of candidates) {
      try {
        const response = await env.ASSETS.fetch(new URL(candidate.path, url.origin).toString());
        if (response.status === 200) {
          const headers = new Headers(response.headers);
          headers.set('Content-Language', candidate.serves);
          // This URL also answers markdown, and the body follows the cookie.
          headers.set('Vary', 'Accept, Cookie');
          // The document is the map to the current hashed chunks — a stale
          // copy points at purged files, so it is revalidated every time.
          headers.set('Cache-Control', REVALIDATE);
          return new Response(response.body, { status: 200, headers });
        }
      } catch {
        // try next
      }
    }

    // ── 5. SPA fallback ──────────────────────────────────────────────────────
    // Unknown paths return the shell as HTTP 200 and the client router renders
    // the not-found page: the server layer answers for the app, the content
    // layer answers for the page. Machine-facing misses were already handled
    // with protocol 404s in stages 1 and 2.
    const res = await env.ASSETS.fetch(request);
    const headers = new Headers(res.headers);
    headers.set('Cache-Control', REVALIDATE);
    return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
  }
};
