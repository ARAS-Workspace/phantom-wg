import { Command } from 'commander';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import ora from 'ora';
import pc from 'picocolors';
import { createClient, extractCustomerSubdomain } from '../cf-stream.js';
import { resolve as resolveConfig, writeConfig } from '../config.js';
import { formatUUID, formatJSON } from '../formatters.js';

/** @typedef {import('../types.js').VideoUpdatePatch} VideoUpdatePatch */

/**
 * Options parsed from the `upload` sub-command. Names map 1-to-1 onto
 * Cloudflare Stream API fields (see README → Options Reference).
 *
 * @typedef {object} UploadOptions
 * @property {"uuid"|"json"} [output]              Output format (`--output`, default `uuid`).
 * @property {string}        [name]                Video name shown in the CF dashboard.
 * @property {boolean}       [requireSignedUrls]   Require signed URLs for playback.
 * @property {string[]}      [meta]                Repeatable `--meta key=value` entries (raw strings).
 * @property {string[]}      [allowedOrigin]       Repeatable `--allowed-origin <origin>` entries.
 * @property {string}        [thumbnailPct]        Thumbnail position as string, parsed to 0.0–1.0.
 * @property {string}        [scheduledDeletion]   ISO-8601 timestamp for auto-deletion.
 * @property {string}        [creator]             Opaque creator identifier.
 * @property {string}        [apiToken]            Override CLOUDFLARE_API_TOKEN.
 * @property {string}        [accountId]           Override CLOUDFLARE_ACCOUNT_ID.
 */

/**
 * Collect repeatable CLI flag values into a string array.
 *
 * @param {string}   value
 * @param {string[]} previous
 * @returns {string[]}
 */
const collect = (value, previous) => [...previous, value];

/**
 * Build a `VideoUpdatePatch` from the parsed CLI options. Returns an empty
 * object when the user did not request any metadata changes, so callers can
 * decide to skip the follow-up API call entirely.
 *
 * @param {UploadOptions} opts
 * @param {number|undefined} thumbnailPct  Already-parsed/validated numeric value.
 * @returns {VideoUpdatePatch}
 */
function buildUpdatePatch(opts, thumbnailPct) {
  /** @type {Record<string, string>} */
  const metaObj = {};
  for (const pair of opts.meta ?? []) {
    const eq = pair.indexOf('=');
    if (eq <= 0) {
      throw new Error(`Bad --meta "${pair}". Use key=value.`);
    }
    metaObj[pair.slice(0, eq)] = pair.slice(eq + 1);
  }
  if (opts.name) {
    metaObj.name = opts.name;
  }

  /** @type {VideoUpdatePatch} */
  const patch = {};
  if (Object.keys(metaObj).length > 0) patch.meta = metaObj;
  if (opts.requireSignedUrls) patch.requireSignedURLs = true;
  if (opts.allowedOrigin && opts.allowedOrigin.length > 0) {
    patch.allowedOrigins = opts.allowedOrigin;
  }
  if (thumbnailPct != null) patch.thumbnailTimestampPct = thumbnailPct;
  if (opts.scheduledDeletion) patch.scheduledDeletion = opts.scheduledDeletion;
  if (opts.creator) patch.creator = opts.creator;
  return patch;
}

/**
 * Build the `upload <file>` sub-command — pushes an MP4 to Cloudflare Stream
 * via direct upload (≤200 MB) and, if any metadata options are set, applies
 * them with a follow-up `POST /stream/{uid}`.
 *
 * @returns {Command}
 */
export function uploadCommand() {
  return new Command('upload')
    .description('Upload an MP4 file to Cloudflare Stream (direct upload, ≤200 MB)')
    .argument('<file>', 'Path to MP4 file')
    .option('--output <format>', 'Output format: uuid | json', 'uuid')
    .option('--name <name>', 'Video name (shown in Cloudflare dashboard)')
    .option('--require-signed-urls', 'Require signed URLs (paywall)')
    .option('--meta <pair>', 'Extra meta as key=value (repeatable)', collect, [])
    .option('--allowed-origin <origin>', 'Allow an embed origin (repeatable)', collect, [])
    .option('--thumbnail-pct <number>', 'Thumbnail position, 0.0–1.0')
    .option('--scheduled-deletion <iso>', 'Auto-delete at ISO-8601 timestamp')
    .option('--creator <id>', 'Creator identifier stored with the video')
    .option('--api-token <token>', 'Override CLOUDFLARE_API_TOKEN')
    .option('--account-id <id>', 'Override CLOUDFLARE_ACCOUNT_ID')
    .action(
      /**
       * @param {string}        filePath
       * @param {UploadOptions} opts
       * @returns {Promise<void>}
       */
      async (filePath, opts) => {
        const abs = path.resolve(filePath);
        const st = await stat(abs);
        if (!st.isFile()) {
          throw new Error(`Not a file: ${abs}`);
        }

        if (opts.output !== 'uuid' && opts.output !== 'json') {
          throw new Error(`Invalid --output: ${opts.output}. Use 'uuid' or 'json'.`);
        }

        // Parse + validate --thumbnail-pct before any network call.
        let thumbnailPct;
        if (opts.thumbnailPct != null) {
          thumbnailPct = Number(opts.thumbnailPct);
          if (Number.isNaN(thumbnailPct) || thumbnailPct < 0 || thumbnailPct > 1) {
            throw new Error('--thumbnail-pct must be a number between 0 and 1.');
          }
        }

        // If the user did not pass --name, fall back to the filename stem
        // so the video has a readable label in the CF dashboard.
        if (!opts.name) {
          opts.name = path.basename(abs, path.extname(abs));
        }

        const patch = buildUpdatePatch(opts, thumbnailPct);
        const hasPatch = Object.keys(patch).length > 0;

        const sizeMB = (st.size / (1024 * 1024)).toFixed(1);
        const filename = path.basename(abs);

        const spinner = ora(
          `Uploading ${pc.cyan(filename)} (${sizeMB} MB) to Cloudflare Stream…`,
        ).start();

        const client = createClient({
          apiToken: opts.apiToken,
          accountId: opts.accountId,
        });

        // Step 1 — direct upload (file only).
        let response;
        try {
          const file = await readFile(abs);
          response = await client.uploadVideo({ file, filename });
        } catch (err) {
          spinner.fail(pc.red('Upload failed'));
          throw err;
        }

        // Step 2 — apply metadata via POST /stream/{uid} if any fields are set.
        if (hasPatch) {
          spinner.text = 'Applying metadata…';
          try {
            response = await client.updateVideo(response.result.uid, patch);
          } catch (err) {
            spinner.fail(pc.red('Metadata update failed after upload'));
            process.stderr.write(
              pc.yellow(
                `  (upload succeeded: uid=${response.result.uid}; retry update with this uid)\n`,
              ),
            );
            throw err;
          }
        }

        spinner.succeed(
          pc.green(hasPatch ? 'Upload complete (with metadata)' : 'Upload complete'),
        );

        // Auto-cache customer subdomain (for future HTML embed construction).
        const sub = extractCustomerSubdomain(
          response.result?.playback?.hls ?? response.result?.playback?.dash,
        );
        if (sub && !resolveConfig('CLOUDFLARE_CUSTOMER_SUBDOMAIN')) {
          writeConfig({ CLOUDFLARE_CUSTOMER_SUBDOMAIN: sub });
          process.stderr.write(
            pc.dim(`  cached customer subdomain: ${sub}\n`),
          );
        }

        if (opts.output === 'json') {
          console.log(formatJSON(response.result));
        } else {
          console.log(formatUUID(response.result.uid));
        }
      },
    );
}
