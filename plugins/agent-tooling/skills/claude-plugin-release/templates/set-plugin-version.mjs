#!/usr/bin/env node
// Usage: node scripts/set-plugin-version.mjs <path/to/plugin.json> <semver>
// Writes `version` into a Claude Code plugin manifest. Copy next to the repo's release config
// (the template .releaserc.json calls it as scripts/set-plugin-version.mjs).
import { readFileSync, writeFileSync } from "node:fs";

const [file, version] = process.argv.slice(2);
if (!file || !/^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/.test(version ?? "")) {
  console.error("usage: set-plugin-version.mjs <plugin.json> <semver>");
  process.exit(2);
}
const manifest = JSON.parse(readFileSync(file, "utf8"));
manifest.version = version;
writeFileSync(file, `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`${file}: version -> ${version}`);
