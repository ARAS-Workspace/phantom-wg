// noinspection JSUnusedGlobalSymbols

import { readFileSync } from 'node:fs';
import path from 'node:path';
import { parse } from '@babel/parser';
import _traverse from '@babel/traverse';

// Handle ESM/CJS interop for @babel/traverse (same as build_routes.js).
const traverse = _traverse.default || _traverse;

/**
 * Parse src/router/index.tsx and build a route → absolute page-directory map.
 *
 * The route tree and the page's source directory are BOTH irregular
 * (e.g. `/docs` ← `docs/home/pages/index`, `/docs/tools/ip` ← `tools/ip-check/…`),
 * so neither is derivable from the other by path munging — the router is the
 * single authority. Only lazy `@pages/…` page components are mapped; layout
 * wrappers (LandingLayout / DocumentationLayout) are skipped.
 *
 * @param {string} routerPath  Absolute path to src/router/index.tsx.
 * @param {string} pagesRoot   Absolute path that `@pages` resolves to (…/src/pages).
 * @returns {Map<string, string>}  route → page directory
 */
export function buildRouteMap(routerPath, pagesRoot) {
  const ast = parse(readFileSync(routerPath, 'utf8'), {
    sourceType: 'module',
    plugins: ['typescript', 'jsx'],
  });

  // ── Pass 1: component name → @pages source directory ──────────────
  /** @type {Map<string, string>} */
  const componentDir = new Map();
  traverse(ast, {
    VariableDeclarator(p) {
      const name = p.node.id?.name;
      const init = p.node.init;
      if (!name || init?.type !== 'CallExpression' || init.callee?.name !== 'lazy') return;
      const body = init.arguments[0]?.body; // () => import('…')
      if (body?.type !== 'CallExpression' || body.callee?.type !== 'Import') return;
      const lit = body.arguments[0];
      if (lit?.type !== 'StringLiteral' || !lit.value.startsWith('@pages/')) return;
      // '@pages/docs/…/bridge/pages/index/BridgePage' → '…/src/pages/docs/…/bridge/pages/index'
      const rel = lit.value.replace(/^@pages\//, '').replace(/\/[^/]+$/, '');
      componentDir.set(name, path.join(pagesRoot, rel));
    },
  });

  // ── Pass 2: walk the route tree, accumulate paths, map route → dir ─
  /** @type {Map<string, string>} */
  const routeDir = new Map();

  const joinPath = (parent, child) => {
    if (!child) return parent;
    if (child.startsWith('/')) return child;
    return parent === '/' ? `/${child}` : `${parent}/${child}`;
  };

  /** @param {any} objNode @param {string} parentPath */
  const walk = (objNode, parentPath) => {
    let curPath = parentPath;
    let isIndex = false;
    let elementName;
    let children;
    for (const prop of objNode.properties) {
      if (prop.type !== 'ObjectProperty') continue;
      const key = prop.key.name ?? prop.key.value;
      if (key === 'path' && prop.value.type === 'StringLiteral') {
        curPath = joinPath(parentPath, prop.value.value);
      } else if (key === 'index' && prop.value.type === 'BooleanLiteral') {
        isIndex = prop.value.value;
      } else if (key === 'element' && prop.value.type === 'JSXElement') {
        elementName = prop.value.openingElement?.name?.name;
      } else if (key === 'children' && prop.value.type === 'ArrayExpression') {
        children = prop.value.elements;
      }
    }

    const raw = (isIndex ? parentPath : curPath) || '/';
    // strip dynamic segments (e.g. /:locale) — parity with the prerender route list
    const route = raw.includes(':') ? raw.replace(/\/:[^/]+/g, '') || '/' : raw;
    if (elementName && componentDir.has(elementName)) {
      routeDir.set(route, componentDir.get(elementName));
    }
    if (children) {
      for (const c of children) if (c?.type === 'ObjectExpression') walk(c, curPath);
    }
  };

  traverse(ast, {
    CallExpression(p) {
      if (p.node.callee?.name !== 'createBrowserRouter') return;
      const arr = p.node.arguments[0];
      if (arr?.type !== 'ArrayExpression') return;
      for (const el of arr.elements) if (el?.type === 'ObjectExpression') walk(el, '');
    },
  });

  return routeDir;
}
