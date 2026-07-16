// Injected from config.yaml during build
// noinspection JSUnresolvedVariable,JSUnresolvedReference

const LOCALES = __LOCALES__;
const DEFAULT_LOCALE = __DEFAULT_LOCALE__;
const THEMES = __THEMES__;
const DEFAULT_THEME = __DEFAULT_THEME__;

/**
 * Locale negotiation shared by every route: an explicit `?locale=` wins;
 * otherwise the `preferred_locale` cookie; otherwise the default. Agents send
 * no cookie, so they fall through to the default — the query param is their lever.
 *
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
 * Serve `<dir>/<locale>.txt` as markdown, negotiating the locale and falling back
 * to the default file. Returns null when nothing is there, so each caller decides
 * what a miss means: an explicit `.txt` request 404s, a negotiated page request
 * falls through to HTML.
 *
 * @param {{ ASSETS: { fetch: (input: string) => Promise<Response> } }} env
 * @param {URL} url
 * @param {Request} request
 * @param {string} dir  Asset directory holding `<locale>.txt`, e.g. `/docs/api/llms`.
 * @returns {Promise<Response|null>}
 */
async function tryServeMarkdown(env, url, request, dir) {
  const loc = detectLocale(url, request);
  const wanted = `${dir}/${loc}.txt`;
  const base = `${dir}/${DEFAULT_LOCALE}.txt`;
  for (const p of [wanted, base]) {
    const r = await env.ASSETS.fetch(new URL(p, url.origin).toString());
    // A missing asset is answered with the SPA shell (200 HTML), so a real hit
    // must not be HTML — otherwise the app shell ships as markdown.
    if (r.status === 200 && !/text\/html/i.test(r.headers.get('content-type') || '')) {
      const headers = new Headers(r.headers);
      headers.set('Content-Type', 'text/markdown; charset=utf-8');
      headers.set('Content-Language', p === wanted ? loc : DEFAULT_LOCALE);
      // The body depends on both the negotiated format and the locale cookie.
      headers.set('Vary', 'Accept, Cookie');
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

    // llms.txt / llms-full.txt — locale-negotiated markdown. Both map the same
    // way: <name>.txt → <name>/<locale>.txt, i.e. per-page files live at
    // <route>/llms/<locale>.txt and the concatenated dump at /llms-full/<locale>.txt.
    if (pathname.endsWith('/llms.txt') || pathname.endsWith('/llms-full.txt')) {
      const md = await tryServeMarkdown(env, url, request, pathname.replace(/\.txt$/, ''));
      if (md) return md;
      // No llms/ behind this path: answer as a missing text file. Falling through
      // would hand the request to the SPA shell, which a browser cannot render
      // as .txt — the request would look like a 200 instead of a 404.
      return new Response('Not Found\n', {
        status: 404,
        headers: { 'Content-Type': 'text/plain; charset=utf-8' },
      });
    }

    // Static assets — pass through
    if (pathname.includes('.') && !pathname.endsWith('.html')) {
      return env.ASSETS.fetch(request);
    }

    // Markdown negotiation — an agent that explicitly asks for markdown gets this
    // page's llms text at the same URL. Browsers never send `text/markdown`, and
    // a bare `*/*` means "no preference", so both keep HTML: it stays the page's
    // primary representation. A route without llms/ falls through to HTML too —
    // serving what we have beats answering 406.
    if ((request.headers.get('accept') || '').includes('text/markdown')) {
      const dir = pathname === '/' ? '/llms' : `${pathname.replace(/\/$/, '')}/llms`;
      const md = await tryServeMarkdown(env, url, request, dir);
      if (md) return md;
    }

    // ── Locale detection (query → cookie → default) ────────────────
    const locale = detectLocale(url, request);

    // ── Theme detection ────────────────────────────────────────────
    let theme = DEFAULT_THEME;
    const cookie = request.headers.get('cookie') || '';
    const cookieTheme = cookie.match(/preferred_theme=(white|g100)/)?.[1];
    if (cookieTheme && THEMES.includes(cookieTheme)) {
      theme = cookieTheme;
    }

    // ── Build file paths with fallback chain ───────────────────────
    // Pattern: index[.theme][.locale].html
    const basePath = pathname === '/' ? '/index' : `${pathname.replace(/\/$/, '')}/index`;
    const themeSuffix = theme === DEFAULT_THEME ? '' : `.${theme}`;
    const localeSuffix = locale === DEFAULT_LOCALE ? '' : `.${locale}`;

    const tryPaths = [
      `${basePath}${themeSuffix}${localeSuffix}.html`,
      `${basePath}${localeSuffix}.html`,
      `${basePath}${themeSuffix}.html`,
      `${basePath}.html`,
    ];

    for (const tryPath of tryPaths) {
      try {
        const response = await env.ASSETS.fetch(new URL(tryPath, url.origin).toString());
        if (response.status === 200) {
          const headers = new Headers(response.headers);
          headers.set('Content-Language', locale);
          // Accept: this URL also answers markdown when an agent asks for it.
          headers.set('Vary', 'Accept, Cookie');
          return new Response(response.body, { status: 200, headers });
        }
      } catch {
        // try next
      }
    }

    // SPA fallback
    return env.ASSETS.fetch(request);
  }
};
