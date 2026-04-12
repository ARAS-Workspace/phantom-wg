// Injected from config.yaml during build
// noinspection JSUnresolvedVariable,JSUnresolvedReference

const LOCALES = __LOCALES__;
const DEFAULT_LOCALE = __DEFAULT_LOCALE__;
const THEMES = __THEMES__;
const DEFAULT_THEME = __DEFAULT_THEME__;

// noinspection JSUnusedGlobalSymbols
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const pathname = url.pathname;

    // Static assets — pass through
    if (pathname.includes('.') && !pathname.endsWith('.html')) {
      return env.ASSETS.fetch(request);
    }

    // ── Locale detection (priority order) ──────────────────────────
    let locale = DEFAULT_LOCALE;

    // 1. Query parameter: ?locale=tr (hreflang + prerender)
    const queryLocale = url.searchParams.get('locale');
    if (queryLocale && LOCALES.includes(queryLocale)) {
      locale = queryLocale;
    }
    // 2. Cookie fallback
    else {
      const cookie = request.headers.get('cookie') || '';
      const cookieLocale = cookie.match(/preferred_locale=(\w+)/)?.[1];
      if (cookieLocale && LOCALES.includes(cookieLocale)) {
        locale = cookieLocale;
      }
    }

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
