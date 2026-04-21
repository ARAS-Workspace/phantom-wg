import {Command} from 'commander';
import pc from 'picocolors';
import {kebabToEnvKey, listAllKeys, readConfig, writeConfig,} from '../config.js';

/**
 * Build the `config` sub-command tree (`set` / `get` / `list`) that manages
 * credentials stored in `secrets/.env` via dotenv.
 *
 * @returns {Command}
 */
export function configCommand() {
  const cmd = new Command('config').description(
    'Manage credentials stored in secrets/.env (dotenv format)',
  );

  cmd
    .command('set <entries...>')
    .description('Set one or more values, e.g. set api-token=xxx account-id=yyy')
    .action(
      /**
       * @param {string[]} entries Variadic `key=value` assignments from the CLI.
       * @returns {void}
       */
      (entries) => {
        /** @type {Record<string, string>} */
        const updates = {};
        for (const pair of entries) {
          const eq = pair.indexOf('=');
          if (eq <= 0) {
            throw new Error(`Bad assignment: "${pair}". Use key=value.`);
          }
          const kebab = pair.slice(0, eq);
          updates[kebabToEnvKey(kebab)] = pair.slice(eq + 1);
        }
        writeConfig(updates);
        for (const key of Object.keys(updates)) {
          console.log(`${pc.green('✓')} set ${key}`);
        }
      },
    );

  cmd
    .command('get <key>')
    .description('Print a single value (unmasked) to stdout')
    .action(
      /**
       * @param {string} key Kebab-case or env-style credential key.
       * @returns {void}
       */
      (key) => {
        const envKey = kebabToEnvKey(key);
        const cfg = readConfig();
        const v = cfg[envKey] ?? process.env[envKey];
        if (v == null || v === '') {
          process.stderr.write(pc.dim(`${envKey} is not set\n`));
          process.exit(1);
        }
        console.log(v);
      },
    );

  cmd
    .command('list')
    .description('Show all known credentials (sensitive ones masked)')
    .action(
      /** @returns {void} */
      () => {
        const cfg = readConfig();
        for (const key of listAllKeys()) {
          const v = cfg[key] ?? process.env[key];
          if (v == null || v === '') {
            console.log(`${pc.dim(key.padEnd(32))} ${pc.dim('(not set)')}`);
            continue;
          }
          const display =
            key === 'CLOUDFLARE_API_TOKEN' ? mask(v) : pc.cyan(v);
          console.log(`${key.padEnd(32)} ${display}`);
        }
      },
    );

  return cmd;
}

/**
 * Mask a sensitive value for display, keeping only the first and last four
 * characters. Values shorter than nine characters are fully masked.
 *
 * @param {string} value
 * @returns {string}
 */
function mask(value) {
  if (value.length <= 8) return pc.cyan('***');
  return pc.cyan(`${value.slice(0, 4)}…${value.slice(-4)}`);
}
