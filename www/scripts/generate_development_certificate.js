#!/usr/bin/env node
/**
 * Generate self-signed SSL certificate for local development.
 * Enables HTTPS with custom domain for prerender DNS override.
 *
 * Usage: node scripts/generate_development_certificate.js
 * Output: certs/cert.pem, certs/key.pem
 */

import { execSync } from 'child_process';
import { existsSync, mkdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const PROJECT_ROOT = join(__dirname, '..');
const CERTS_DIR = join(PROJECT_ROOT, 'certs');

const log = {
  info: (msg) => console.log(`\x1b[36m[CERT]\x1b[0m ${msg}`),
  success: (msg) => console.log(`\x1b[32m[CERT]\x1b[0m ${msg}`),
  error: (msg) => console.error(`\x1b[31m[CERT]\x1b[0m ${msg}`),
};

function main() {
  try {
    log.info('Generating development SSL certificates...');

    if (!existsSync(CERTS_DIR)) {
      mkdirSync(CERTS_DIR, { recursive: true });
      log.info('Created certs/ directory');
    }

    const certPath = join(CERTS_DIR, 'cert.pem');
    const keyPath = join(CERTS_DIR, 'key.pem');

    const opensslCommand = [
      'openssl req -x509',
      '-newkey rsa:2048',
      `-keyout ${keyPath}`,
      `-out ${certPath}`,
      '-days 730',
      '-nodes',
      '-subj "/CN=www.phantom.tc/O=Phantom-WG/C=TR"',
      '-addext "subjectAltName=DNS:www.phantom.tc,DNS:phantom.tc,DNS:localhost,IP:127.0.0.1"',
    ].join(' ');

    log.info('Generating certificate with OpenSSL...');
    execSync(opensslCommand, { cwd: PROJECT_ROOT, stdio: 'pipe' });

    log.success('Certificate generated successfully!');
    log.info(`  - ${certPath}`);
    log.info(`  - ${keyPath}`);
    log.info('');
    log.info('To trust this certificate on macOS:');
    log.info(
      `  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ${certPath}`
    );
  } catch (error) {
    log.error(`Failed to generate certificate: ${error.message}`);
    process.exit(1);
  }
}

main();
