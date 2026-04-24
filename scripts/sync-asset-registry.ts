/**
 * Synchronise asset-registry.yml et asset-registry.schema.json depuis les frontmatters.
 * Mode --backfill : injecte les tags du registre YAML existant dans les fichiers (phase initiale).
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { glob } from "glob";
import matter from "gray-matter";
import yaml from "js-yaml";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..");

const SCHEMA_PATH = path.join(REPO_ROOT, "asset-registry.schema.json");
const REGISTRY_PATH = path.join(REPO_ROOT, "asset-registry.yml");

type AssetType = "skill" | "command" | "rule" | "agent" | "hook";

interface RegistryDoc {
  version: string;
  assets: AssetEntry[];
  "x-tag-descriptions": Record<string, string>;
}

interface AssetEntry {
  path: string;
  type: AssetType;
  tags: string[];
  description?: string;
}

interface SchemaRoot {
  properties?: {
    "x-tag-descriptions"?: {
      required?: string[];
      properties?: Record<string, { type?: string; const?: string }>;
    };
  };
  $defs?: {
    tag?: { enum?: string[] };
  };
}

interface Discovered {
  registryPath: string;
  type: AssetType;
  absFile: string;
}

const CYAN = "\x1b[36m";
const YELLOW = "\x1b[33m";
const GREEN = "\x1b[32m";
const DIM = "\x1b[2m";
const RESET = "\x1b[0m";

function logSection(title: string): void {
  console.log(`\n${CYAN}━━ ${title} ━━${RESET}`);
}

function warn(msg: string): void {
  console.log(`${YELLOW}⚠ ${msg}${RESET}`);
}

function normalizeTags(raw: unknown): string[] {
  if (raw == null) return [];
  if (Array.isArray(raw)) {
    return [...new Set(raw.map((t) => String(t).trim()).filter(Boolean))].sort();
  }
  if (typeof raw === "string" && raw.trim()) return [raw.trim()];
  return [];
}

function pickDescription(data: Record<string, unknown>): string | undefined {
  const d = data.description;
  if (typeof d === "string" && d.trim()) return d.trim();
  return undefined;
}

function skillRegistryPathFromDir(dir: string): string {
  const rel = path.relative(REPO_ROOT, dir).split(path.sep).join("/");
  return rel.endsWith("/") ? rel : `${rel}/`;
}

function discoverAll(): Discovered[] {
  const out: Discovered[] = [];

  for (const dir of glob.sync("skills/*/SKILL.md", { cwd: REPO_ROOT, posix: true })) {
    const abs = path.join(REPO_ROOT, dir);
    out.push({
      registryPath: skillRegistryPathFromDir(path.dirname(abs)),
      type: "skill",
      absFile: abs,
    });
  }
  for (const dir of glob.sync(".agents/skills/*/SKILL.md", { cwd: REPO_ROOT, posix: true })) {
    const abs = path.join(REPO_ROOT, dir);
    out.push({
      registryPath: skillRegistryPathFromDir(path.dirname(abs)),
      type: "skill",
      absFile: abs,
    });
  }
  for (const f of glob.sync("commands/*.md", { cwd: REPO_ROOT, posix: true })) {
    out.push({
      registryPath: f,
      type: "command",
      absFile: path.join(REPO_ROOT, f),
    });
  }
  for (const f of glob.sync(".cursor/commands/*.md", { cwd: REPO_ROOT, posix: true })) {
    out.push({
      registryPath: f,
      type: "command",
      absFile: path.join(REPO_ROOT, f),
    });
  }
  for (const f of glob.sync(".specify/extensions/**/commands/*.md", {
    cwd: REPO_ROOT,
    posix: true,
  })) {
    out.push({
      registryPath: f,
      type: "command",
      absFile: path.join(REPO_ROOT, f),
    });
  }
  for (const f of glob.sync("rules/**/*.mdc", { cwd: REPO_ROOT, posix: true })) {
    out.push({
      registryPath: f,
      type: "rule",
      absFile: path.join(REPO_ROOT, f),
    });
  }
  for (const f of glob.sync(".cursor/rules/*.mdc", { cwd: REPO_ROOT, posix: true })) {
    out.push({
      registryPath: f,
      type: "rule",
      absFile: path.join(REPO_ROOT, f),
    });
  }
  for (const f of glob.sync("agents/*.md", { cwd: REPO_ROOT, posix: true })) {
    out.push({
      registryPath: f,
      type: "agent",
      absFile: path.join(REPO_ROOT, f),
    });
  }

  return out;
}

function registryPathToAbsFile(entryPath: string, type: AssetType): string {
  if (type === "skill") {
    const dir = entryPath.replace(/\/$/, "");
    return path.join(REPO_ROOT, dir, "SKILL.md");
  }
  return path.join(REPO_ROOT, entryPath);
}

function readFrontmatter(
  absFile: string,
): { data: Record<string, unknown>; content: string; error?: string } {
  let raw: string;
  try {
    raw = fs.readFileSync(absFile, "utf8");
  } catch (e) {
    return { data: {}, content: "", error: String(e) };
  }
  try {
    const parsed = matter(raw);
    return {
      data: parsed.data as Record<string, unknown>,
      content: parsed.content,
    };
  } catch (e) {
    return { data: {}, content: raw, error: `matter: ${String(e)}` };
  }
}

function writeFrontmatter(absFile: string, data: Record<string, unknown>, content: string): void {
  const body = matter.stringify(content, data);
  fs.writeFileSync(absFile, body, "utf8");
}

function loadRegistry(): RegistryDoc {
  const raw = fs.readFileSync(REGISTRY_PATH, "utf8");
  const doc = yaml.load(raw) as RegistryDoc;
  return doc;
}

function loadSchema(): SchemaRoot {
  return JSON.parse(fs.readFileSync(SCHEMA_PATH, "utf8")) as SchemaRoot;
}

function sortedRecord(rec: Record<string, string>): Record<string, string> {
  const keys = Object.keys(rec).sort();
  const next: Record<string, string> = {};
  for (const k of keys) next[k] = rec[k];
  return next;
}

function mergeTagDescriptions(
  existing: Record<string, string>,
  newTags: string[],
): { merged: Record<string, string>; added: string[] } {
  const merged = { ...existing };
  const added: string[] = [];
  for (const t of newTags) {
    if (!(t in merged)) {
      merged[t] = `[NEW] ${t}`;
      added.push(t);
    }
  }
  return { merged: sortedRecord(merged), added };
}

function applyNewTagsToSchema(schema: SchemaRoot, newTagNames: string[]): string[] {
  const added: string[] = [];
  const tagDef = schema.$defs?.tag;
  const enumList = tagDef?.enum ?? [];
  const set = new Set(enumList);
  for (const t of newTagNames) {
    if (!set.has(t)) {
      set.add(t);
      added.push(t);
    }
  }
  if (tagDef) {
    tagDef.enum = [...set].sort();
  }

  const xtd = schema.properties?.["x-tag-descriptions"];
  if (xtd) {
    const props = xtd.properties ?? {};
    for (const t of newTagNames) {
      if (!props[t]) {
        props[t] = { type: "string", const: `[NEW] ${t}` };
      }
    }
    xtd.properties = props;
    const req = new Set(xtd.required ?? []);
    for (const t of Object.keys(props)) req.add(t);
    xtd.required = [...req].sort();
  }
  return added;
}

function writeSchema(schema: SchemaRoot): void {
  fs.writeFileSync(SCHEMA_PATH, `${JSON.stringify(schema, null, 2)}\n`, "utf8");
}

function writeRegistry(doc: RegistryDoc): void {
  const assets = [...doc.assets].sort((a, b) => a.path.localeCompare(b.path));
  const payload = {
    version: doc.version,
    "x-tag-descriptions": sortedRecord(doc["x-tag-descriptions"]),
    assets,
  };
  const header = "# yaml-language-server: $schema=./asset-registry.schema.json\n";
  const body = yaml.dump(payload, {
    lineWidth: 120,
    noRefs: true,
    quotingType: '"',
    forceQuotes: false,
  });
  fs.writeFileSync(REGISTRY_PATH, header + body, "utf8");
}

function backfillFromRegistry(): void {
  logSection("Backfill frontmatter depuis asset-registry.yml");
  const reg = loadRegistry();
  let updated = 0;
  for (const entry of reg.assets) {
    const abs = registryPathToAbsFile(entry.path, entry.type);
    if (!fs.existsSync(abs)) {
      warn(`backfill skip (fichier absent): ${entry.path}`);
      continue;
    }
    const tags = normalizeTags(entry.tags);
    if (tags.length === 0) {
      warn(`backfill skip (aucun tag registre): ${entry.path}`);
      continue;
    }
    const { data, content, error } = readFrontmatter(abs);
    if (error) {
      warn(`backfill skip (${error}): ${entry.path}`);
      continue;
    }
    const next = { ...data, tags };
    writeFrontmatter(abs, next, content);
    updated += 1;
  }
  console.log(`${GREEN}Backfill terminé : ${updated} fichier(s) mis à jour.${RESET}`);
}

function sync(): {
  scanned: number;
  added: number;
  updated: number;
  warnings: number;
} {
  logSection("Scan & synchronisation");
  const discovered = discoverAll();
  const schema = loadSchema();
  const reg = loadRegistry();
  const existingEnum = new Set(schema.$defs?.tag?.enum ?? []);

  let warnings = 0;
  const filesWithoutTags: string[] = [];
  const newTagsForSchema = new Set<string>();

  type BuiltEntry = AssetEntry;
  const fromScan = new Map<string, BuiltEntry>();

  for (const d of discovered) {
    const { data, error } = readFrontmatter(d.absFile);
    if (error) {
      warn(`parse ${d.registryPath}: ${error}`);
      warnings += 1;
      continue;
    }
    const tags = normalizeTags(data.tags);
    if (tags.length === 0) {
      filesWithoutTags.push(d.registryPath);
    }
    for (const t of tags) {
      if (!existingEnum.has(t)) {
        newTagsForSchema.add(t);
      }
    }
    const desc = pickDescription(data);
    if (tags.length > 0) {
      fromScan.set(d.registryPath, {
        path: d.registryPath,
        type: d.type,
        tags,
        ...(desc ? { description: desc } : {}),
      });
    }
  }

  for (const p of filesWithoutTags) {
    warn(`fichier sans tags dans le frontmatter : ${p}`);
    warnings += 1;
  }

  let added = 0;
  let updated = 0;
  const finalByPath = new Map<string, AssetEntry>();
  for (const a of reg.assets) {
    finalByPath.set(a.path, { ...a });
  }

  for (const d of discovered) {
    const built = fromScan.get(d.registryPath);
    if (!built) continue;
    const prev = finalByPath.get(d.registryPath);
    if (!prev) {
      finalByPath.set(d.registryPath, built);
      added += 1;
      continue;
    }
    const tagsChanged =
      JSON.stringify(built.tags) !== JSON.stringify(normalizeTags(prev.tags));
    const nextDesc = built.description ?? prev.description;
    const descChanged = (nextDesc ?? "") !== (prev.description ?? "");
    if (tagsChanged || descChanged) updated += 1;
    finalByPath.set(d.registryPath, {
      ...prev,
      tags: built.tags,
      type: built.type,
      ...(nextDesc !== undefined ? { description: nextDesc } : {}),
    });
  }

  for (const prev of reg.assets) {
    const abs = registryPathToAbsFile(prev.path, prev.type);
    if (!fs.existsSync(abs)) {
      warn(`path orphelin (fichier absent, entrée conservée) : ${prev.path}`);
      warnings += 1;
    }
  }

  const mergedAssets = [...finalByPath.values()].sort((a, b) =>
    a.path.localeCompare(b.path),
  );

  const allTagsInUse = new Set<string>();
  for (const a of mergedAssets) {
    for (const t of normalizeTags(a.tags)) allTagsInUse.add(t);
  }

  const schemaAdded = [...newTagsForSchema].filter((t) => !existingEnum.has(t));
  if (schemaAdded.length > 0) {
    for (const t of schemaAdded) {
      warn(`nouveau tag (schéma enrichi) : ${t}`);
      warnings += 1;
    }
    applyNewTagsToSchema(schema, schemaAdded);
    writeSchema(schema);
  }

  const { merged: mergedDesc } = mergeTagDescriptions(
    reg["x-tag-descriptions"],
    [...allTagsInUse],
  );

  reg.assets = mergedAssets;
  reg["x-tag-descriptions"] = mergedDesc;
  writeRegistry(reg);

  logSection("Résumé");
  console.log(`  Fichiers scannés : ${DIM}${discovered.length}${RESET}`);
  console.log(`  Entrées ajoutées  : ${GREEN}${added}${RESET}`);
  console.log(`  Entrées mises à jour : ${GREEN}${updated}${RESET}`);
  console.log(`  Avertissements    : ${warnings > 0 ? YELLOW : GREEN}${warnings}${RESET}`);

  return {
    scanned: discovered.length,
    added,
    updated,
    warnings,
  };
}

const isBackfill = process.argv.includes("--backfill");

if (isBackfill) {
  backfillFromRegistry();
}

const stats = sync();

if (!isBackfill && stats.warnings === 0) {
  console.log(`\n${GREEN}Synchronisation terminée sans avertissement.${RESET}`);
}

process.exit(0);
