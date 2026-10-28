#!/usr/bin/env node

/**
 * Claude Code Hooks Merger
 *
 * Registers the hooks listed in a manifest into a Claude Code settings.json,
 * preserving every other key and every hook already present in the target.
 * Idempotent: a hook whose exact `command` already exists under the same event
 * is skipped, and the target is not rewritten when nothing changed.
 *
 * Usage:
 *   node merge-claude-hooks.cjs --source <manifest.json> --target <settings.json>
 */

const fs = require('fs');
const path = require('path');

// Parse command line arguments
const args = process.argv.slice(2);
const params = {};

for (let i = 0; i < args.length; i += 2) {
  if (args[i].startsWith('--')) {
    params[args[i].substring(2)] = args[i + 1];
  }
}

if (!params.source || !params.target) {
  console.error('Required parameters missing. Usage:');
  console.error('node merge-claude-hooks.cjs --source <manifest.json> --target <settings.json>');
  process.exit(1);
}

function readJson(file, label) {
  let content;
  try {
    content = fs.readFileSync(file, 'utf8');
  } catch (err) {
    console.error(`Error reading ${label} file ${file}: ${err.message}`);
    process.exit(1);
  }
  try {
    return JSON.parse(content);
  } catch (err) {
    console.error(`Error parsing JSON from ${file}: ${err.message}`);
    process.exit(1);
  }
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

const manifest = readJson(params.source, 'source');
if (!isObject(manifest.hooks)) {
  console.error(`Source file ${params.source} has no "hooks" object`);
  process.exit(1);
}

// Read target, or start from an empty configuration when it does not exist
let target = {};
const targetExists = fs.existsSync(params.target);
if (targetExists) {
  target = readJson(params.target, 'target');
  if (!isObject(target)) {
    console.error(`Target file ${params.target} must contain a JSON object`);
    process.exit(1);
  }
}

const hadHooks = target.hooks !== undefined;
if (!hadHooks) {
  target.hooks = {};
} else if (!isObject(target.hooks)) {
  console.error(`Target file ${params.target} has a non-object "hooks" value`);
  process.exit(1);
}

const added = [];

for (const [event, groups] of Object.entries(manifest.hooks)) {
  if (!Array.isArray(groups)) continue;

  if (target.hooks[event] === undefined) {
    target.hooks[event] = [];
  } else if (!Array.isArray(target.hooks[event])) {
    console.error(`Target "hooks.${event}" is not an array`);
    process.exit(1);
  }
  const targetGroups = target.hooks[event];

  const existingCommands = new Set();
  for (const group of targetGroups) {
    if (group && Array.isArray(group.hooks)) {
      for (const hook of group.hooks) {
        if (hook && typeof hook.command === 'string') existingCommands.add(hook.command);
      }
    }
  }

  for (const group of groups) {
    const hooks = Array.isArray(group.hooks) ? group.hooks : [];
    const wanted = hooks.filter((hook) => !(hook && existingCommands.has(hook.command)));
    if (wanted.length === 0) continue;

    // Same matcher (both absent counts as equal): append to that group
    const match = targetGroups.find(
      (g) => g && g.matcher === group.matcher && Array.isArray(g.hooks)
    );
    if (match) {
      match.hooks.push(...wanted);
    } else {
      targetGroups.push({ ...group, hooks: wanted });
    }
    for (const hook of wanted) {
      existingCommands.add(hook.command);
      added.push(`${event}${group.matcher ? ` [${group.matcher}]` : ''}: ${hook.command}`);
    }
  }

  if (targetGroups.length === 0) delete target.hooks[event];
}

if (!hadHooks && Object.keys(target.hooks).length === 0) {
  delete target.hooks;
}

if (added.length === 0 && targetExists) {
  console.log(`Claude Code hooks: nothing to add in ${params.target}`);
  process.exit(0);
}

try {
  fs.mkdirSync(path.dirname(path.resolve(params.target)), { recursive: true });
  fs.writeFileSync(params.target, JSON.stringify(target, null, 2) + '\n');
} catch (err) {
  console.error(`Error writing to target file ${params.target}: ${err.message}`);
  process.exit(1);
}

if (added.length === 0) {
  console.log(`Claude Code hooks: nothing to add in ${params.target} (created)`);
} else {
  for (const line of added) console.log(`Added hook ${line}`);
}
