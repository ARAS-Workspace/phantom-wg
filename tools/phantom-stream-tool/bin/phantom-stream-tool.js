#!/usr/bin/env node
import { run } from '../lib/cli.js';

run(process.argv).catch((err) => {
  const msg = err?.message ?? String(err);
  process.stderr.write(`\nError: ${msg}\n`);
  if (process.env.DEBUG) {
    process.stderr.write(`\n${err?.stack ?? ''}\n`);
  }
  process.exit(1);
});
