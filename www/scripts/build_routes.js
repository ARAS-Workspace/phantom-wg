#!/usr/bin/env node
// noinspection JSUnresolvedReference,JSUnusedGlobalSymbols

/**
 * Route Builder — AST-based route extraction for prerender pipeline
 *
 * Parses src/router/index.tsx, extracts routes from createBrowserRouter,
 * strips dynamic :locale prefix, and writes routes.yaml.
 *
 * Usage: node scripts/build_routes.js
 */

import { readFileSync, writeFileSync } from 'fs';
import { parse } from '@babel/parser';
import _traverse from '@babel/traverse';
import yaml from 'js-yaml';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
// Handle ESM/CJS compatibility for @babel/traverse
const traverse = _traverse.default || _traverse;

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const PROJECT_ROOT = join(__dirname, '..');
const ROUTER_PATH = join(PROJECT_ROOT, 'src/router/index.tsx');
const ROUTES_CONFIG_PATH = join(PROJECT_ROOT, 'routes.yaml');

const log = {
  info: (msg) => console.log(`[INFO] ${msg}`),
  success: (msg) => console.log(`[SUCCESS] ${msg}`),
  error: (msg) => console.error(`[ERROR] ${msg}`),
};

function extractRoutes(routerCode) {
  const routes = new Set();

  try {
    const ast = parse(routerCode, {
      sourceType: 'module',
      plugins: ['typescript', 'jsx'],
    });

    traverse(ast, {
      CallExpression(path) {
        if (
          path.node.callee.type === 'Identifier' &&
          path.node.callee.name === 'createBrowserRouter' &&
          path.node.arguments.length > 0 &&
          path.node.arguments[0].type === 'ArrayExpression'
        ) {
          const routeArray = path.node.arguments[0].elements;
          routeArray.forEach((routeNode) => {
            if (routeNode && routeNode.type === 'ObjectExpression') {
              processRouteObject(routeNode, '', routes);
            }
          });
        }
      },
    });

    return Array.from(routes).sort((a, b) => {
      const depthA = (a.match(/\//g) || []).length;
      const depthB = (b.match(/\//g) || []).length;
      if (depthA !== depthB) return depthA - depthB;
      return a.localeCompare(b);
    });
  } catch (error) {
    log.error(`Failed to parse router: ${error.message}`);
    throw error;
  }
}

function processRouteObject(routeNode, parentPath, routes) {
  let currentPath = parentPath;
  let hasIndex = false;
  let children = null;

  routeNode.properties.forEach((prop) => {
    if (prop.type !== 'ObjectProperty') return;
    const key = prop.key.name || prop.key.value;

    if (key === 'path' && prop.value.type === 'StringLiteral') {
      const pathValue = prop.value.value;

      if (pathValue.startsWith('/')) {
        currentPath = pathValue;
      } else if (parentPath) {
        currentPath = parentPath === '/' ? `/${pathValue}` : `${parentPath}/${pathValue}`;
      } else {
        currentPath = `/${pathValue}`;
      }
    }

    if (key === 'index' && prop.value.type === 'BooleanLiteral' && prop.value.value === true) {
      hasIndex = true;
    }

    if (key === 'children' && prop.value.type === 'ArrayExpression') {
      children = prop.value.elements;
    }
  });

  // Dynamic segments (e.g. /:locale) — strip and process children under /
  if (currentPath.includes(':')) {
    currentPath = currentPath.replace(/\/:[^/]+/g, '') || '/';
  } else if (currentPath && !currentPath.includes(':')) {
    routes.add(currentPath);
  }

  if (hasIndex && parentPath && !routes.has(parentPath)) {
    routes.add(parentPath);
  }

  if (children) {
    children.forEach((childNode) => {
      if (childNode && childNode.type === 'ObjectExpression') {
        processRouteObject(childNode, currentPath, routes);
      }
    });
  }
}

function updateYamlConfig(routes) {
  try {
    const config = { routes };
    const newYaml = yaml.dump(config, {
      indent: 2,
      lineWidth: -1,
      sortKeys: false,
    });

    writeFileSync(ROUTES_CONFIG_PATH, newYaml, 'utf-8');
    log.success(`Updated ${ROUTES_CONFIG_PATH} with ${routes.length} routes`);
  } catch (error) {
    log.error(`Failed to update YAML: ${error.message}`);
    throw error;
  }
}

async function main() {
  log.info('Route Builder - Starting');

  try {
    log.info(`Reading router from ${ROUTER_PATH}`);
    const routerCode = readFileSync(ROUTER_PATH, 'utf-8');

    log.info('Extracting routes from AST...');
    const routes = extractRoutes(routerCode);

    if (routes.length === 0) {
      log.error('No routes found!');
      return false;
    }

    log.info(`Found ${routes.length} routes:`);
    routes.forEach((route) => log.info(`  - ${route}`));

    log.info('Updating routes.yaml...');
    updateYamlConfig(routes);

    log.success('Route extraction complete!');
    return true;
  } catch (error) {
    log.error(`Fatal error: ${error.message}`);
    return false;
  }
}

main()
  .then((success) => process.exit(success ? 0 : 1))
  .catch((error) => {
    log.error(`Unhandled error: ${error}`);
    process.exit(1);
  });
