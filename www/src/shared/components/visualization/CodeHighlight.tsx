import React, { useEffect, useState, lazy, Suspense } from 'react';
import { createHighlighter, type Highlighter } from 'shiki';
import { SkeletonPlaceholder } from '@carbon/react';
import { useIsClient } from '@shared/hooks/useIsClient';
import './styles/CodeHighlight.scss';

// ── Config ────────────────────────────────────────────────────────

const SHIKI_THEME_LIGHT = 'github-light';
const SHIKI_THEME_DARK = 'github-dark';

const SHIKI_LANGS = [
  'python',
  'typescript',
  'javascript',
  'tsx',
  'jsx',
  'bash',
  'shell',
  'json',
  'yaml',
  'toml',
  'go',
  'rust',
  'sql',
  'dockerfile',
  'markdown',
  'text',
] as const;

const LINE_HEIGHT_PX = 22;
const PADDING_PX = 32;

// ── Singleton highlighter ─────────────────────────────────────────

let _highlighterPromise: Promise<Highlighter> | null = null;

function getHighlighter(): Promise<Highlighter> {
  if (!_highlighterPromise) {
    _highlighterPromise = createHighlighter({
      themes: [SHIKI_THEME_LIGHT, SHIKI_THEME_DARK],
      langs: [...SHIKI_LANGS],
    });
  }
  return _highlighterPromise;
}

function getShikiTheme(): string {
  const ct = document.documentElement.getAttribute('data-carbon-theme');
  return ct === 'white' ? SHIKI_THEME_LIGHT : SHIKI_THEME_DARK;
}

// ── Types ─────────────────────────────────────────────────────────

interface CodeHighlightProps {
  code: string;
  lang?: string;
}

// ── Skeleton ──────────────────────────────────────────────────────

const CodeSkeleton: React.FC<{ lineCount: number }> = ({ lineCount }) => {
  const height = lineCount * LINE_HEIGHT_PX + PADDING_PX;
  return (
    <div className="code-highlight__skeleton">
      <SkeletonPlaceholder style={{ width: '100%', height: `${height}px` }} />
    </div>
  );
};

// ── Inner component ───────────────────────────────────────────────

const CodeHighlightInner: React.FC<CodeHighlightProps> = ({ code, lang = 'text' }) => {
  const [html, setHtml] = useState<string | null>(null);

  const highlight = () => {
    getHighlighter()
      .then((highlighter) => {
        const loaded = highlighter.getLoadedLanguages() as string[];
        const safeLang = loaded.includes(lang) ? lang : 'text';
        const result = highlighter.codeToHtml(code, { lang: safeLang, theme: getShikiTheme() });
        setHtml(result);
      })
      .catch(() => {
        setHtml(`<pre><code>${code}</code></pre>`);
      });
  };

  // Initial render + re-highlight on code/lang change
  useEffect(() => {
    highlight();
  }, [code, lang]);

  // Re-highlight on theme change
  useEffect(() => {
    const observer = new MutationObserver((mutations) => {
      for (const m of mutations) {
        if (m.type === 'attributes' && m.attributeName === 'data-carbon-theme') {
          highlight();
        }
      }
    });

    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['data-carbon-theme'],
    });

    return () => observer.disconnect();
  }, [code, lang]);

  if (html === null) {
    return <CodeSkeleton lineCount={code.split('\n').length} />;
  }

  return <div className="code-highlight" dangerouslySetInnerHTML={{ __html: html }} />;
};

// ── Wrapper ───────────────────────────────────────────────────────

// ── Prerender-safe wrapper ────────────────────────────────────────

const CodeHighlight: React.FC<CodeHighlightProps> = (props) => {
  const isClient = useIsClient();

  if (!isClient) {
    return <CodeSkeleton lineCount={(props.code ?? '').split('\n').length} />;
  }

  return <CodeHighlightInner {...props} />;
};

// ── Lazy variant ──────────────────────────────────────────────────

const LazyCodeHighlightComponent = lazy(() => Promise.resolve({ default: CodeHighlight }));

const LazyCodeHighlight: React.FC<CodeHighlightProps> = (props) => (
  <Suspense fallback={<CodeSkeleton lineCount={(props.code ?? '').split('\n').length} />}>
    <LazyCodeHighlightComponent {...props} />
  </Suspense>
);

// ── Composition ───────────────────────────────────────────────────

interface CodeHighlightComponent extends React.FC<CodeHighlightProps> {
  Lazy: React.FC<CodeHighlightProps>;
}

const CodeHighlightWithLazy = Object.assign(CodeHighlight, {
  Lazy: LazyCodeHighlight,
}) as CodeHighlightComponent;

export default CodeHighlightWithLazy;
