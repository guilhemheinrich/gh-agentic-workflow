#!/usr/bin/env node
// Compute the next semantic version of the published plugins from git tags and
// Conventional Commits. Claude Code only offers an update when a plugin's
// `version` string changes, so every publish must carry a new version.
//
// Usage: node scripts/plugin-builder/next-version.mjs [--ref HEAD]
// Prints the version (no `v` prefix) on stdout. The tag `v<version>` is created
// by the CI workflow after a successful publish, never by this script.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SEMVER = /^\d+\.\d+\.\d+$/;
const ORDER = { none: 0, patch: 1, minor: 2, major: 3 };

/** Bump level implied by one commit message (subject + body). */
export function commitBump(message) {
  const [subject = ''] = message.split('\n');
  if (/^BREAKING[ -]CHANGE:/m.test(message) || /^\w+(\([^)]*\))?!:/.test(subject)) return 'major';
  const type = subject.match(/^(\w+)(\([^)]*\))?:/)?.[1];
  if (type === 'feat') return 'minor';
  if (type === 'fix' || type === 'perf' || type === 'revert') return 'patch';
  return 'none';
}

/**
 * Next version after `base` for the given commit messages.
 * A publish always changes the shipped content, so it never stays below a patch bump.
 */
export function nextVersion(base, messages) {
  if (!SEMVER.test(base)) throw new Error(`invalid base version '${base}'`);
  let level = 'patch';
  for (const m of messages) if (ORDER[commitBump(m)] > ORDER[level]) level = commitBump(m);
  const [maj, min, pat] = base.split('.').map(Number);
  if (level === 'major') return `${maj + 1}.0.0`;
  if (level === 'minor') return `${maj}.${min + 1}.0`;
  return `${maj}.${min}.${pat + 1}`;
}

const git = (cwd, ...args) => execFileSync('git', args, { cwd, encoding: 'utf8' }).trim();

/** Resolve the version to publish for `ref`: reuse a tag already on it, else bump from the latest tag. */
export function versionForRef({ cwd, ref = 'HEAD', seed }) {
  const own = git(cwd, 'tag', '--points-at', ref, '--list', 'v[0-9]*').split('\n').filter((t) => SEMVER.test(t.slice(1)));
  if (own.length) return own.sort((a, b) => cmp(b.slice(1), a.slice(1)))[0].slice(1);
  let base = seed;
  let range = ref;
  try {
    const tag = git(cwd, 'describe', '--tags', '--abbrev=0', '--match', 'v[0-9]*', ref);
    if (SEMVER.test(tag.slice(1))) {
      base = tag.slice(1);
      range = `${tag}..${ref}`;
    }
  } catch {
    // No tag yet: the seed is what users already have installed, so the first release
    // is a plain patch bump of it. The pre-tag history is deliberately ignored, it would
    // replay old breaking commits and jump straight to 1.0.0.
    return nextVersion(base, []);
  }
  const raw = git(cwd, 'log', '--format=%B%x00', range);
  const messages = raw.split('\0').map((s) => s.trim()).filter(Boolean);
  return nextVersion(base, messages);
}

function cmp(a, b) {
  const [x, y] = [a, b].map((v) => v.split('.').map(Number));
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i];
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
  const i = process.argv.indexOf('--ref');
  const config = JSON.parse(fs.readFileSync(path.join(root, 'scripts/plugin-builder/config.json'), 'utf8'));
  console.log(versionForRef({ cwd: root, ref: i === -1 ? 'HEAD' : process.argv[i + 1], seed: config.version }));
}
