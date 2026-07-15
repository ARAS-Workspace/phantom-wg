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

// noinspection JSUnusedGlobalSymbols
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const pathname = url.pathname;

    // llms.txt — locale-negotiated markdown (files live at <route>/llms/<locale>.txt)
    if (pathname.endsWith('/llms.txt')) {
      const loc = detectLocale(url, request);
      const wanted = pathname.replace(/llms\.txt$/, `llms/${loc}.txt`);
      const base = pathname.replace(/llms\.txt$/, `llms/${DEFAULT_LOCALE}.txt`);
      for (const p of [wanted, base]) {
        const r = await env.ASSETS.fetch(new URL(p, url.origin));
        if (r.status === 200) {
          const headers = new Headers(r.headers);
          headers.set('Content-Type', 'text/markdown; charset=utf-8');
          headers.set('Content-Language', p === wanted ? loc : DEFAULT_LOCALE);
          return new Response(r.body, { status: 200, headers });
        }
      }
      // no llms/ for this page → fall through
    }

    // Static assets — pass through
    if (pathname.includes('.') && !pathname.endsWith('.html')) {
      return env.ASSETS.fetch(request);
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
        const response = await env.ASSETS.fetch(new URL(tryPath, url.origin));
        if (response.status === 200) {
          const headers = new Headers(response.headers);
          headers.set('Content-Language', locale);
          headers.set('Vary', 'Cookie');
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
