#!/usr/bin/env node
// Generate Claude Code plugins + a marketplace from asset-registry.yml.
// See scripts/plugin-builder/README.md.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildPlugins } from './plugin-builder/build.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(name);
  return i === -1 ? def : args[i + 1];
};
if (args.includes('--help')) {
  console.log('Usage: node scripts/build-plugins.mjs [--out dist] [--report-only] [--fail-on-drift]');
  process.exit(0);
}

const config = JSON.parse(fs.readFileSync(path.join(root, 'scripts/plugin-builder/config.json'), 'utf8'));
const result = buildPlugins({
  root,
  config,
  out: path.resolve(root, opt('--out', 'dist')),
  write: !args.includes('--report-only'),
});

console.log(result.report.join('\n'));
if (result.errors.length) {
  console.error(`\nBUILD FAILED: ${result.errors.length} error(s)`);
  for (const e of result.errors) console.error(`  - ${e}`);
  process.exit(1);
}
if (args.includes('--fail-on-drift') && result.drift > 0) {
  console.error(`\nBUILD FAILED: ${result.drift} registry/filesystem drift issue(s) (--fail-on-drift)`);
  process.exit(1);
}
