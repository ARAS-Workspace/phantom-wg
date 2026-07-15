#!/usr/bin/env node
// noinspection JSUnusedGlobalSymbols

/**
 * Route Builder — writes routes.yaml for the prerender pipeline.
 *
 * The router is parsed once, by lib/route-sources.js (the single source of
 * truth for route ↔ page directory). This script takes the route list from
 * that map, orders it, and writes routes.yaml.
 *
 * Usage: node scripts/build_routes.js
 */

import { writeFileSync } from 'fs';
import yaml from 'js-yaml';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { buildRouteMap } from './lib/route-sources.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = join(__dirname, '..');
const ROUTER_PATH = join(PROJECT_ROOT, 'src/router/index.tsx');
const PAGES_ROOT = join(PROJECT_ROOT, 'src/pages');
const ROUTES_CONFIG_PATH = join(PROJECT_ROOT, 'routes.yaml');

const log = {
  info: (msg) => console.log(`[INFO] ${msg}`),
  success: (msg) => console.log(`[SUCCESS] ${msg}`),
  error: (msg) => console.error(`[ERROR] ${msg}`),
};

/**
 * Order routes by depth then name — the routes.yaml ordering.
 * @param {Iterable<string>} routes
 * @returns {string[]}
 */
function sortRoutes(routes) {
  return [...routes].sort((a, b) => {
    const depthA = (a.match(/\//g) || []).length;
    const depthB = (b.match(/\//g) || []).length;
    if (depthA !== depthB) return depthA - depthB;
    return a.localeCompare(b);
  });
}

function main() {
  log.info('Route Builder - Starting');

  try {
    log.info(`Reading router from ${ROUTER_PATH}`);
    const routes = sortRoutes(buildRouteMap(ROUTER_PATH, PAGES_ROOT).keys());

    if (routes.length === 0) {
      log.error('No routes found!');
      return false;
    }

    log.info(`Found ${routes.length} routes:`);
    routes.forEach((route) => log.info(`  - ${route}`));

    const newYaml = yaml.dump({ routes }, { indent: 2, lineWidth: -1, sortKeys: false });
    writeFileSync(ROUTES_CONFIG_PATH, newYaml, 'utf-8');
    log.success(`Updated ${ROUTES_CONFIG_PATH} with ${routes.length} routes`);
    return true;
  } catch (error) {
    log.error(`Fatal error: ${error.message}`);
    return false;
  }
}

process.exit(main() ? 0 : 1);
