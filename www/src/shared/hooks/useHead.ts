import { useEffect } from 'react';

const MANAGED_ATTR = 'data-head';

interface MetaTag {
  name?: string;
  property?: string;
  content: string;
  httpEquiv?: string;
}

interface LinkTag {
  rel: string;
  href: string;
  hrefLang?: string;
}

interface HeadConfig {
  title: string;
  lang?: string;
  meta?: MetaTag[];
  links?: LinkTag[];
  schemas?: any[];
}

/**
 * useHead — manages <head> tags with full cleanup on unmount/update.
 * Replaces react-helmet-async with zero dependencies.
 */
export function useHead(config: HeadConfig) {
  useEffect(() => {
    const head = document.head;
    const elements: HTMLElement[] = [];

    // ── Title ──────────────────────────────────────────────────────
    document.title = config.title;

    // ── HTML lang ──────────────────────────────────────────────────
    if (config.lang) {
      document.documentElement.lang = config.lang;
    }

    // ── Remove ALL managed tags (handles prerender→hydration + navigation) ──
    head.querySelectorAll(`[${MANAGED_ATTR}]`).forEach((el) => {
      el.parentNode?.removeChild(el);
    });

    // ── Meta tags ──────────────────────────────────────────────────
    if (config.meta) {
      for (const tag of config.meta) {
        const el = document.createElement('meta');
        if (tag.name) el.setAttribute('name', tag.name);
        if (tag.property) el.setAttribute('property', tag.property);
        if (tag.httpEquiv) el.setAttribute('http-equiv', tag.httpEquiv);
        el.setAttribute('content', tag.content);
        el.setAttribute(MANAGED_ATTR, 'true');
        head.appendChild(el);
        elements.push(el);
      }
    }

    // ── Link tags ──────────────────────────────────────────────────
    if (config.links) {
      for (const tag of config.links) {
        const el = document.createElement('link');
        el.setAttribute('rel', tag.rel);
        el.setAttribute('href', tag.href);
        if (tag.hrefLang) el.setAttribute('hreflang', tag.hrefLang);
        el.setAttribute(MANAGED_ATTR, 'true');
        head.appendChild(el);
        elements.push(el);
      }
    }

    // ── JSON-LD schemas ────────────────────────────────────────────
    if (config.schemas) {
      for (const schema of config.schemas) {
        const el = document.createElement('script');
        el.setAttribute('type', 'application/ld+json');
        el.setAttribute(MANAGED_ATTR, 'true');
        el.textContent = JSON.stringify(schema);
        head.appendChild(el);
        elements.push(el);
      }
    }

    // ── Cleanup on unmount ─────────────────────────────────────────
    return () => {
      elements.forEach((el) => {
        if (el.parentNode) el.parentNode.removeChild(el);
      });
    };
  }, [config.title, config.lang, config.meta, config.links, config.schemas]);
}
