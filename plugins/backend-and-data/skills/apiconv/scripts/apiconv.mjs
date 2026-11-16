#!/usr/bin/env node
// apiconv — deterministic Insomnia v4 export -> Postman v2.1 + Bruno conversion, and its verifier.
//
//   node apiconv.mjs convert <insomnia-dir> <identity-file> <identity-env-name> <out-dir>
//   node apiconv.mjs verify  <insomnia-dir> <identity-file> <identity-env-name> <out-dir>
//
// Both commands build the same neutral model from the Insomnia files. `convert` writes it as
// Postman and Bruno files; `verify` parses those files back with the official libraries
// (postman-collection SDK + JSON schema, @usebruno/lang) into the neutral model and requires
// deep equality, request by request. Any construct the converter does not know aborts the run.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const bruLang = require('@usebruno/lang');
const sdk = require('postman-collection');
const Ajv = require('ajv-draft-04');
const addFormats = require('ajv-formats');

const POSTMAN_SCHEMA_URL = 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json';
const HERE = path.dirname(new URL(import.meta.url).pathname);

// ---------------------------------------------------------------- neutral model

const SUPPORTED_TAGS = ["{% now 'millis' %}", "{% now 'custom', 'yyyy-MM-dd' %}", "{% uuid 'v4' %}"];
const RESPONSE_TAG = /\{%\s*response\s+'body',\s*'(req_[0-9a-f]+)',\s*'b64::([A-Za-z0-9+/=]+)::46b',\s*'when-expired',\s*\d+\s*%\}/g;
// Request settings every source request carries; anything else has no Postman/Bruno equivalent.
const DEFAULT_SETTINGS = {
  settingStoreCookies: true, settingSendCookies: true, settingDisableRenderRequestBody: false,
  settingEncodeUrl: true, settingRebuildPath: true, settingFollowRedirects: 'global',
};

class Unsupported extends Error {}
const fail = (msg) => { throw new Unsupported(msg); };

const neutralTemplate = (s) => String(s ?? '').replace(/\{\{\s*_\.([A-Za-z0-9_]+)\s*\}\}/g, '{{$1}}');

// Insomnia tags inside request fields, mapped both ways. uuid has a native dynamic variable;
// the clock tags become reserved variables that the collection pre-request script sets.
const CLOCK_VARS = { millis: 'apiconv_now_millis', today: 'apiconv_today' };
const INLINE_TAGS = [["{% uuid 'v4' %}", '{{$guid}}'], ["{% now 'millis' %}", `{{${CLOCK_VARS.millis}}}`],
  ["{% now 'custom', 'yyyy-MM-dd' %}", `{{${CLOCK_VARS.today}}}`]];
const usesClock = (requests) => requests.some((r) => /apiconv_now_millis|apiconv_today/.test(JSON.stringify(mapWire(r, inlineOut))));
const inlineOut = (s) => INLINE_TAGS.reduce((t, [a, b]) => t.split(a).join(b), s);
const inlineIn = (s) => INLINE_TAGS.reduce((t, [a, b]) => t.split(b).join(a), s);
// Applies a string mapping to every request field that is sent on the wire.
function mapWire(n, f) {
  const fld = (x) => ({ ...x, value: f(x.value) });
  return {
    ...n, url: f(n.url), query: n.query.map(fld), headers: n.headers.map(fld),
    auth: Object.fromEntries(Object.entries(n.auth).map(([k, v]) => [k, k === 'type' ? v : f(v)])),
    body: n.body.mode === 'json' ? { ...n.body, text: f(n.body.text) } : n.body.mode === 'urlencoded' ? { ...n.body, params: n.body.params.map(fld) } : n.body,
  };
}

function assertPlain(where, s) {
  for (const [, b] of INLINE_TAGS) if (s.includes(b)) fail(`${where}: ${b} already present — the tag mapping would not be reversible`);
  if (/\{%/.test(inlineOut(s))) fail(`${where}: unsupported Insomnia tag in ${JSON.stringify(s)}`);
  if (/\{\{\s/.test(s) || /\{\{[^}]*\s\}\}/.test(s)) fail(`${where}: unrecognised template ${JSON.stringify(s)}`);
  return s;
}

function readInsomnia(file) {
  const doc = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (doc._type !== 'export' || doc.__export_format !== 4) fail(`${file}: not an Insomnia v4 export`);
  return doc.resources;
}

function jsonPathFromB64(b64) {
  const p = Buffer.from(b64, 'base64').toString('utf8');
  if (!/^\$(\.[A-Za-z_][A-Za-z0-9_]*)+$/.test(p)) fail(`response tag path ${p} is not a plain $.a.b path`);
  return p;
}

// One collection file -> { name, description, vars, computed, requests }
function neutralCollection(file) {
  const res = readInsomnia(file);
  const ws = res.filter((r) => r._type === 'workspace');
  if (ws.length !== 1 || ws[0].scope !== 'collection') fail(`${file}: expected exactly one collection workspace`);
  const known = new Set(['workspace', 'environment', 'request']);
  for (const r of res) if (!known.has(r._type)) fail(`${file}: unsupported resource type ${r._type}`);
  const envs = res.filter((r) => r._type === 'environment' && r.parentId === ws[0]._id);
  if (envs.length !== 1) fail(`${file}: expected exactly one base environment`);
  // Sub-environments of the base one are stages (staging, prod): plain values only.
  const subs = res.filter((r) => r._type === 'environment' && r.parentId === envs[0]._id).sort((a, b) => (a.metaSortKey ?? 0) - (b.metaSortKey ?? 0));
  for (const r of res) if (r._type === 'environment' && r !== envs[0] && !subs.includes(r)) fail(`${file}: environment ${r.name} is nested deeper than one level`);
  const reqs = res.filter((r) => r._type === 'request');
  for (const r of reqs) if (r.parentId !== ws[0]._id) fail(`${r.name}: request folders are not supported`);

  const vars = {}; const computed = {};
  for (const [k, v] of Object.entries(envs[0].data ?? {})) {
    if (typeof v !== 'string') fail(`env ${k}: non-string value`);
    if (/\{%|\{\{/.test(v)) {
      const t = neutralTemplate(v);
      for (const tag of t.match(/\{%[^%]*%\}/g) ?? []) if (!SUPPORTED_TAGS.includes(tag)) fail(`env ${k}: unsupported tag ${tag}`);
      computed[k] = t;
    } else vars[k] = v;
  }
  const stages = subs.length ? neutralStages(file, subs, { ...vars, ...computed }) : null;
  // A stage key with the same value in every stage is no stage variable: it joins the collection's own.
  if (stages) for (const k of Object.keys(stages.invariant)) vars[k] = stages.invariant[k];

  const byId = new Map(reqs.map((r) => [r._id, r]));
  const exportsBySource = new Map();
  const ordered = [...reqs].sort((a, b) => a.metaSortKey - b.metaSortKey);
  const requests = ordered.map((r, i) => {
    const where = `${path.basename(file)} / ${r.name}`;
    for (const [k, v] of Object.entries(DEFAULT_SETTINGS)) if (r[k] !== undefined && r[k] !== v) fail(`${where}: ${k}=${r[k]} has no equivalent`);
    if (r.disableUserAgentHeader) fail(`${where}: disableUserAgentHeader has no equivalent`);
    if ((r.pathParameters ?? []).length) fail(`${where}: path parameters are not supported`);
    if ((r.preRequestScript ?? '') !== '') fail(`${where}: pre-request scripts are not supported`);
    // A query string typed inside the URL becomes query parameters: the request on the wire is identical.
    let [urlPath, inlineQuery] = String(r.url).split(/\?(.*)/s);
    let params = r.parameters ?? [];
    if (inlineQuery !== undefined) {
      if (params.length) fail(`${where}: query string in the URL AND query parameters`);
      params = inlineQuery.split('&').map((kv) => { const [name, ...v] = kv.split('='); return { name, value: v.join('=') }; });
    }

    const field = (x, kind) => {
      let value = neutralTemplate(x.value);
      value = value.replace(RESPONSE_TAG, (_m, reqId, b64) => {
        const src = byId.get(reqId) ?? fail(`${where}: response tag points at unknown ${reqId}`);
        const jp = jsonPathFromB64(b64);
        const varName = `response_${reqId}_${jp.slice(2).replace(/\./g, '_')}`;
        const list = exportsBySource.get(src._id) ?? [];
        if (!list.some((e) => e.var === varName)) list.push({ var: varName, path: jp });
        exportsBySource.set(src._id, list);
        return `{{${varName}}}`;
      });
      assertPlain(`${where} ${kind} ${x.name}`, value);
      return { name: x.name, value, enabled: !x.disabled, description: x.description ?? '' };
    };

    const auth = r.authentication ?? {};
    let nAuth;
    if (!auth.type || auth.type === 'none') nAuth = { type: 'none' };
    else if (auth.type === 'basic') nAuth = { type: 'basic', username: assertPlain(where, neutralTemplate(auth.username)), password: assertPlain(where, neutralTemplate(auth.password)) };
    else if (auth.type === 'bearer') {
      if ((auth.prefix ?? 'Bearer') !== 'Bearer') fail(`${where}: bearer prefix ${auth.prefix} is not supported`);
      nAuth = { type: 'bearer', token: assertPlain(where, neutralTemplate(auth.token)) };
    } else fail(`${where}: auth ${auth.type} is not supported`);
    if (auth.disabled) fail(`${where}: disabled auth is not supported`);

    const b = r.body ?? {};
    let body;
    if (!b.mimeType) body = { mode: 'none' };
    else if (b.mimeType === 'application/json') body = (b.text ?? '') === '' ? { mode: 'none' } : { mode: 'json', text: assertPlain(where, neutralTemplate(b.text)) };
    else if (b.mimeType === 'application/x-www-form-urlencoded') {
      for (const p of b.params ?? []) if (p.type && p.type !== 'text') fail(`${where}: body param type ${p.type} is not supported`);
      body = { mode: 'urlencoded', params: (b.params ?? []).map((p) => field(p, 'body')) };
    } else fail(`${where}: body ${b.mimeType} is not supported`);

    const script = r.afterResponseScript ?? '';
    if (/\b(pm|bru|res)\./.test(script)) fail(`${where}: script already uses pm./bru./res. — the mapping would not be reversible`);

    return {
      id: r._id, seq: i + 1, name: r.name, method: String(r.method).toUpperCase(), url: assertPlain(where, neutralTemplate(urlPath)),
      query: params.map((p) => field(p, 'query')),
      headers: (r.headers ?? []).map((h) => field(h, 'header')),
      auth: nAuth, body, script, exports: [], docs: r.description ?? '',
    };
  });
  for (const r of requests) r.exports = exportsBySource.get(r.id) ?? [];
  for (const r of requests) delete r.id;
  return { name: ws[0].name, description: ws[0].description ?? '', vars, computed, stages: stages?.varying ?? null, requests, file: path.basename(file) };
}

// Stage sub-environments -> { invariant: {k: v}, varying: {stage: {k: v}} }. Every stage holds the same keys.
function neutralStages(file, subs, baseVars) {
  const data = Object.fromEntries(subs.map((s) => [s.name, s.data ?? {}]));
  const names = Object.keys(data);
  if (names.length !== subs.length) fail(`${file}: two stages share a name`);
  const keys = Object.keys(data[names[0]]);
  for (const n of names) {
    if (JSON.stringify(Object.keys(data[n])) !== JSON.stringify(keys)) fail(`${file}: stage ${n} does not hold the same keys, in the same order, as ${names[0]}`);
    for (const [k, v] of Object.entries(data[n])) {
      if (typeof v !== 'string' || /\{%|\{\{/.test(v)) fail(`${file}: stage ${n} ${k}: only plain string values are supported`);
      if (k in baseVars) fail(`${file}: ${k} is set both in the base environment and in stage ${n}`);
    }
  }
  const invariant = {}; const varying = Object.fromEntries(names.map((n) => [n, {}]));
  for (const k of keys) {
    if (names.every((n) => data[n][k] === data[names[0]][k])) invariant[k] = data[names[0]][k];
    else for (const n of names) varying[n][k] = data[n][k];
  }
  return { invariant, varying };
}

function neutralIdentity(file, envName) {
  const res = readInsomnia(file);
  const env = res.find((r) => r._type === 'environment' && r.name === envName) ?? fail(`identity ${envName} not found in ${file}`);
  const vars = {};
  for (const [k, v] of Object.entries(env.data ?? {})) {
    if (typeof v !== 'string' || /\{%|\{\{/.test(v)) fail(`identity ${k}: only plain string values are supported`);
    vars[k] = v;
  }
  return { name: envName, vars };
}

// ---------------------------------------------------------------- script mappings

const MAPS = {
  postman: [['insomnia.response.code', 'pm.response.code'], ['insomnia.response.json()', 'pm.response.json()'],
    ['insomnia.environment.set(', 'pm.collectionVariables.set('], ['insomnia.environment.get(', 'pm.variables.get(']],
  bruno: [['insomnia.response.code', 'res.getStatus()'], ['insomnia.response.json()', 'res.getBody()'],
    ['insomnia.environment.set(', 'bru.setEnvVar('], ['insomnia.environment.get(', 'bru.getEnvVar(']],
};
const API = {
  postman: { set: 'pm.collectionVariables.set', get: 'pm.variables.get', body: 'pm.response.json()', uuid: "pm.variables.replaceIn('{{$guid}}')" },
  bruno: { set: 'bru.setEnvVar', get: 'bru.getEnvVar', body: 'res.getBody()', uuid: "bru.interpolate('{{$guid}}')" },
};
const EXPORTS_BEGIN = '// apiconv:begin response-exports (Insomnia {% response %} tags)';
const COMPUTED_BEGIN = '// apiconv:begin computed-variables (Insomnia environment values rendered at send time)';
const END = '// apiconv:end';

const swap = (text, pairs) => pairs.reduce((t, [a, b]) => t.split(a).join(b), text);

function toTargetScript(target, n) {
  let out = swap(n.script, MAPS[target]);
  if (/insomnia\./.test(out)) fail(`${n.name}: script uses an unmapped insomnia.* call`);
  if (n.exports.length) {
    const lines = n.exports.map((e) => `${API[target].set}(${JSON.stringify(e.var)}, ${API[target].body}${e.path.slice(1)});`);
    // Exactly one separator newline, always: the reverse strips it without guessing.
    out += `\n${EXPORTS_BEGIN}\n${lines.join('\n')}\n${END}\n`;
  }
  return out;
}

function fromTargetScript(target, text) {
  let exports = [];
  const i = text.indexOf(`\n${EXPORTS_BEGIN}\n`);
  if (i >= 0) {
    const block = text.slice(i + 1);
    if (!block.endsWith(`${END}\n`)) fail('response-exports block is not at the end of the script');
    const re = new RegExp(`${API[target].set.replace(/\./g, '\\.')}\\(("[^"]+"), ${API[target].body.replace(/[.()]/g, '\\$&')}((?:\\.[A-Za-z0-9_]+)+)\\);`, 'g');
    exports = [...block.matchAll(re)].map((m) => ({ var: JSON.parse(m[1]), path: `$${m[2]}` }));
    text = text.slice(0, i);
  }
  const back = swap(text, MAPS[target].map(([a, b]) => [b, a]));
  return { script: back, exports };
}

const CLOCK_LINE = '  // apiconv:clock';

function computedScript(target, computed, clock) {
  const keys = Object.keys(computed); // source order: a template may read a key rendered before it
  if (!keys.length && !clock) return '';
  const tpl = Object.fromEntries(keys.map((k) => [k, computed[k]]));
  const a = API[target];
  return [
    COMPUTED_BEGIN,
    `const apiconvTemplates = ${JSON.stringify(tpl, null, 2)};`,
    '(function apiconvRender() {',
    '  const pad = (n) => String(n).padStart(2, "0");',
    '  const now = new Date();',
    ...(clock ? [CLOCK_LINE,
      `  ${a.set}("${CLOCK_VARS.millis}", String(now.getTime()));`,
      `  ${a.set}("${CLOCK_VARS.today}", now.getFullYear() + "-" + pad(now.getMonth() + 1) + "-" + pad(now.getDate()));`] : []),
    '  for (const [key, template] of Object.entries(apiconvTemplates)) {',
    '    let value = template',
    `      .split("{% now 'millis' %}").join(String(now.getTime()))`,
    `      .split("{% now 'custom', 'yyyy-MM-dd' %}").join(now.getFullYear() + "-" + pad(now.getMonth() + 1) + "-" + pad(now.getDate()))`,
    `      .split("{% uuid 'v4' %}").join(${a.uuid});`,
    `    value = value.replace(/\\{\\{([A-Za-z0-9_]+)\\}\\}/g, (m, name) => { const v = ${a.get}(name); return v === undefined || v === null ? m : String(v); });`,
    `    ${a.set}(key, value);`,
    '  }',
    '})();',
    END,
  ].join('\n') + '\n';
}

function fromComputedScript(text) {
  if (!text) return { computed: {}, clock: false };
  const m = text.match(/const apiconvTemplates = (\{[\s\S]*?\n?\});/) ?? fail('computed-variables block unreadable');
  return { computed: JSON.parse(m[1]), clock: text.includes(CLOCK_LINE) };
}

// ---------------------------------------------------------------- deterministic helpers

const stable = (v) => JSON.stringify(v, null, 2) + '\n';
const detUuid = (seed) => {
  const h = crypto.createHash('sha256').update(seed).digest('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
};
const slug = (s) => s.normalize('NFKD').replace(/[̀-ͯ]/g, '').replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '').toLowerCase();
const collectionSlug = (file) => file.replace(/\.insomnia\.json$/, '');
const queryString = (q) => q.filter((p) => p.enabled).map((p) => `${p.name}=${p.value}`).join('&');

// ---------------------------------------------------------------- Postman

function postmanItem(n0) {
  const n = mapWire(n0, inlineOut);
  const raw = n.url + (queryString(n.query) ? `?${queryString(n.query)}` : '');
  const url = new sdk.Url(raw).toJSON();
  url.raw = raw;
  url.query = n.query.map((p) => ({ key: p.name, value: p.value, ...(p.enabled ? {} : { disabled: true }), ...(p.description ? { description: p.description } : {}) }));
  if (!url.query.length) delete url.query;
  const request = {
    method: n.method,
    header: n.headers.map((h) => ({ key: h.name, value: h.value, ...(h.enabled ? {} : { disabled: true }), ...(h.description ? { description: h.description } : {}) })),
    url,
  };
  if (n.auth.type === 'none') request.auth = { type: 'noauth' };
  if (n.auth.type === 'basic') request.auth = { type: 'basic', basic: [{ key: 'username', value: n.auth.username, type: 'string' }, { key: 'password', value: n.auth.password, type: 'string' }] };
  if (n.auth.type === 'bearer') request.auth = { type: 'bearer', bearer: [{ key: 'token', value: n.auth.token, type: 'string' }] };
  if (n.body.mode === 'json') request.body = { mode: 'raw', raw: n.body.text, options: { raw: { language: 'json' } } };
  if (n.body.mode === 'urlencoded') request.body = { mode: 'urlencoded', urlencoded: n.body.params.map((p) => ({ key: p.name, value: p.value, type: 'text', ...(p.enabled ? {} : { disabled: true }), ...(p.description ? { description: p.description } : {}) })) };
  if (n.docs) request.description = n.docs;
  const item = { name: n.name, request };
  const script = toTargetScript('postman', n);
  if (script) item.event = [{ listen: 'test', script: { type: 'text/javascript', exec: script.split('\n') } }];
  return item;
}

function toPostman(c) {
  const out = {
    info: { _postman_id: detUuid(`postman:${c.name}:${c.file}`), name: c.name, ...(c.description ? { description: c.description } : {}), schema: POSTMAN_SCHEMA_URL },
    item: c.requests.map(postmanItem),
  };
  const pre = computedScript('postman', c.computed, usesClock(c.requests));
  if (pre) out.event = [{ listen: 'prerequest', script: { type: 'text/javascript', exec: pre.split('\n') } }];
  out.variable = Object.keys(c.vars).map((k) => ({ key: k, value: c.vars[k], type: 'string' }));
  return out;
}

function postmanEnvironment(vars, label) {
  return {
    id: detUuid(`postman-env:${label}`), name: label,
    values: Object.keys(vars).map((k) => ({ key: k, value: vars[k], type: /secret/i.test(k) ? 'secret' : 'default', enabled: true })),
    _postman_variable_scope: 'environment',
  };
}

// One Postman environment per target, shared by every collection: the identity, then each stage variable.
function postmanStageVars(collections, target) {
  const vars = { ...target.vars };
  for (const c of collections) for (const [k, v] of Object.entries(c.stages[target.stage])) {
    if (k in vars && vars[k] !== v) fail(`stage ${target.stage} ${k}: ${c.file} disagrees with another collection, one Postman environment cannot hold both`);
    vars[k] = v;
  }
  return vars;
}

function fromPostman(json) {
  const col = new sdk.Collection(json);
  const pre = (col.events.all().find((e) => e.listen === 'prerequest')?.script.exec ?? []).join('\n');
  const vars = {}; col.variables.each((v) => { vars[v.key] = v.value; });
  const requests = [];
  let seq = 0;
  col.forEachItem((it) => {
    const r = it.request;
    const rawJson = json.item.find((x) => x.name === it.name) ?? fail(`postman item ${it.name} not found`);
    const u = rawJson.request.url;
    const auth = r.auth ? r.auth.toJSON() : { type: 'noauth' };
    const authParam = (k) => (auth[auth.type] ?? []).find((p) => p.key === k)?.value;
    let nAuth = { type: 'none' };
    if (auth.type === 'basic') nAuth = { type: 'basic', username: authParam('username'), password: authParam('password') };
    if (auth.type === 'bearer') nAuth = { type: 'bearer', token: authParam('token') };
    let body = { mode: 'none' };
    if (r.body?.mode === 'raw') body = { mode: 'json', text: r.body.raw };
    if (r.body?.mode === 'urlencoded') body = { mode: 'urlencoded', params: r.body.urlencoded.all().map((p) => ({ name: p.key, value: p.value, enabled: !p.disabled, description: p.description?.content ?? p.description ?? '' })) };
    const test = (it.events.all().find((e) => e.listen === 'test')?.script.exec ?? []).join('\n');
    const { script, exports } = fromTargetScript('postman', test);
    seq += 1;
    requests.push({
      seq, name: it.name, method: r.method, url: u.raw.split('?')[0],
      query: (u.query ?? []).map((p) => ({ name: p.key, value: p.value, enabled: !p.disabled, description: p.description ?? '' })),
      headers: r.headers.all().map((h) => ({ name: h.key, value: h.value, enabled: !h.disabled, description: h.description?.content ?? h.description ?? '' })),
      auth: nAuth, body, script, exports, docs: r.description?.content ?? r.description ?? '',
    });
    if (queryString(requests.at(-1).query) !== (u.raw.split('?')[1] ?? '')) fail(`postman ${it.name}: raw query and query list disagree`);
    requests[requests.length - 1] = mapWire(requests.at(-1), inlineIn);
  });
  return { name: col.name, description: json.info.description ?? '', vars, ...fromComputedScript(pre), requests };
}

// ---------------------------------------------------------------- Bruno

const NOTES = '<!-- apiconv:field-notes (header and body descriptions; Bruno has no field for them) -->';

function brunoDocs(n) {
  const notes = [...n.headers.map((h) => ['header', h]), ...n.query.map((p) => ['query', p]), ...(n.body.params ?? []).map((p) => ['body', p])]
    .filter(([, f]) => f.description).map(([kind, f]) => `- ${kind} ${f.name}: ${JSON.stringify(f.description)}`);
  return notes.length ? `${n.docs}\n\n${NOTES}\n${notes.join('\n')}` : n.docs;
}

function fromBrunoDocs(docs) {
  const i = docs.indexOf(`\n\n${NOTES}\n`);
  if (i < 0) return { docs, notes: new Map() };
  const notes = new Map();
  for (const line of docs.slice(i + NOTES.length + 3).split('\n')) {
    const m = line.match(/^- (header|query|body) (\S+): (".*")$/) ?? fail(`bruno field note unreadable: ${line}`);
    notes.set(`${m[1]} ${m[2]}`, JSON.parse(m[3]));
  }
  return { docs: docs.slice(0, i), notes };
}

function toBrunoRequest(n0) {
  const n = mapWire(n0, inlineOut);
  const qs = queryString(n.query);
  const json = {
    meta: { name: n.name, type: 'http', seq: n.seq },
    http: { method: n.method.toLowerCase(), url: n.url + (qs ? `?${qs}` : ''), body: { none: 'none', json: 'json', urlencoded: 'formUrlEncoded' }[n.body.mode], auth: n.auth.type },
    params: n.query.map((p) => ({ name: p.name, value: p.value, enabled: p.enabled, type: 'query' })),
    headers: n.headers.map((h) => ({ name: h.name, value: h.value, enabled: h.enabled })),
    auth: n.auth.type === 'basic' ? { basic: { username: n.auth.username, password: n.auth.password } } : n.auth.type === 'bearer' ? { bearer: { token: n.auth.token } } : {},
    body: n.body.mode === 'json' ? { json: n.body.text } : n.body.mode === 'urlencoded' ? { formUrlEncoded: n.body.params.map((p) => ({ name: p.name, value: p.value, enabled: p.enabled })) } : {},
  };
  const script = toTargetScript('bruno', n);
  if (script) json.script = { res: script };
  const docs = brunoDocs(n);
  if (docs) json.docs = docs;
  return bruLang.jsonToBruV2(json);
}

// targets: one Bruno environment each (see load). Without stages the single identity lands in environments/staging.bru.
function toBruno(c, targets) {
  const files = {};
  files['bruno.json'] = stable({ version: '1', name: c.name, type: 'collection', ignore: ['node_modules', '.git'] });
  const pre = computedScript('bruno', c.computed, usesClock(c.requests));
  files['collection.bru'] = bruLang.jsonToCollectionBru({ meta: { name: c.name, type: 'collection' }, ...(pre ? { script: { req: pre } } : {}), ...(c.description ? { docs: c.description } : {}) });
  for (const t of targets) {
    const variables = [...Object.entries(t.vars), ...Object.entries(c.vars), ...Object.entries(t.stage ? c.stages[t.stage] : {})].map(([name, value]) => ({ name, value, enabled: true, secret: false }));
    files[`environments/${t.bruno}.bru`] = bruLang.envJsonToBruV2({ variables });
  }
  for (const n of c.requests) files[`${String(n.seq).padStart(2, '0')}-${slug(n.name)}.bru`] = toBrunoRequest(n);
  return files;
}

// Splits each environment file back into identity, collection variables (equal in every file) and stage variables.
function fromBruno(dir, identityKeys, stageKeys, envNames) {
  const meta = JSON.parse(fs.readFileSync(path.join(dir, 'bruno.json'), 'utf8'));
  const colJson = bruLang.collectionBruToJson(fs.readFileSync(path.join(dir, 'collection.bru'), 'utf8'));
  let vars = null; const identities = {}; const stages = {};
  for (const e of envNames) {
    const env = bruLang.bruToEnvJsonV2(fs.readFileSync(path.join(dir, `environments/${e}.bru`), 'utf8'));
    const own = {}; identities[e] = {}; stages[e] = {};
    for (const v of env.variables) (identityKeys.includes(v.name) ? identities[e] : stageKeys.includes(v.name) ? stages[e] : own)[v.name] = v.value;
    if (vars && JSON.stringify(vars) !== JSON.stringify(own)) fail(`${dir}: environments/${e}.bru does not hold the same collection variables as the other environments`);
    vars = own;
  }
  const requests = fs.readdirSync(dir).filter((f) => f.endsWith('.bru') && f !== 'collection.bru').sort().map((f) => {
    const j = bruLang.bruToJsonV2(fs.readFileSync(path.join(dir, f), 'utf8'));
    const { docs, notes } = fromBrunoDocs(j.docs ?? '');
    const note = (kind, name) => notes.get(`${kind} ${name}`) ?? '';
    const authType = j.http.auth;
    const bodyMode = { none: 'none', json: 'json', formUrlEncoded: 'urlencoded' }[j.http.body] ?? fail(`${f}: body ${j.http.body}`);
    const query = (j.params ?? []).filter((p) => p.type === 'query').map((p) => ({ name: p.name, value: p.value, enabled: p.enabled, description: note('query', p.name) }));
    const [urlPath, urlQuery = ''] = j.http.url.split('?');
    if (urlQuery !== queryString(query)) fail(`${f}: url query and params:query disagree`);
    const { script, exports } = fromTargetScript('bruno', j.script?.res ?? '');
    return {
      seq: Number(j.meta.seq), name: j.meta.name, method: j.http.method.toUpperCase(), url: urlPath, query,
      headers: (j.headers ?? []).map((h) => ({ name: h.name, value: h.value, enabled: h.enabled, description: note('header', h.name) })),
      auth: authType === 'basic' ? { type: 'basic', username: j.auth.basic.username, password: j.auth.basic.password }
        : authType === 'bearer' ? { type: 'bearer', token: j.auth.bearer.token } : { type: 'none' },
      body: bodyMode === 'json' ? { mode: 'json', text: j.body.json } : bodyMode === 'urlencoded'
        ? { mode: 'urlencoded', params: j.body.formUrlEncoded.map((p) => ({ name: p.name, value: p.value, enabled: p.enabled, description: note('body', p.name) })) } : { mode: 'none' },
      script, exports, docs,
    };
  });
  return { collection: { name: meta.name, description: colJson.docs ?? '', vars, ...fromComputedScript(colJson.script?.req ?? ''), requests: requests.map((r) => mapWire(r, inlineIn)) }, identities, stages };
}

// ---------------------------------------------------------------- commands

// A target is one environment of the output: an identity paired with a stage.
// Staged collections (sub-environments staging, prod, …) take every identity environment named after a stage
// ("prod") or after a stage and a holder ("staging — alice"); each stage needs at least one. Unstaged ones take
// the single identity environment named idEnv, written as before (Postman 00-environment-<idEnv>, Bruno staging).
// APICONV_LABEL prefixes the Postman environment names ("Acme" -> "Acme staging — dev", "Acme — prod").
const LABEL = process.env.APICONV_LABEL ?? '';
const unstagedLabel = (n) => `${LABEL ? `${LABEL} ` : ''}staging — ${n}`;
const stagedLabel = (n) => (LABEL ? `${LABEL} — ${n}` : n);
function load(insDir, idFile, idEnv) {
  const files = fs.readdirSync(insDir).filter((f) => /^0[1-9].*\.insomnia\.json$/.test(f)).sort();
  if (!files.length) fail(`${insDir}: no collection export (0[1-9]-*.insomnia.json)`);
  const collections = files.map((f) => neutralCollection(path.join(insDir, f)));
  const names = (c) => JSON.stringify(c.stages ? Object.keys(c.stages) : null);
  for (const c of collections) if (names(c) !== names(collections[0])) fail(`${c.file}: stages ${names(c)} differ from ${collections[0].file} ${names(collections[0])}`);
  const stageNames = collections[0].stages ? Object.keys(collections[0].stages) : null;
  if (!stageNames) return { collections, targets: [{ name: idEnv, stage: null, postman: slug(idEnv), bruno: 'staging', label: unstagedLabel(idEnv), vars: neutralIdentity(idFile, idEnv).vars }] };
  const envNames = readInsomnia(idFile).filter((r) => r._type === 'environment').map((r) => r.name);
  const stageOf = (n) => stageNames.find((s) => n === s || n.startsWith(`${s} — `));
  const targets = envNames.filter(stageOf).map((n) => ({ name: n, stage: stageOf(n), postman: slug(n), bruno: slug(n), label: stagedLabel(n), vars: neutralIdentity(idFile, n).vars }));
  for (const s of stageNames) if (!targets.some((t) => t.stage === s)) fail(`${idFile}: no identity environment for stage ${s}`);
  const keys = JSON.stringify(Object.keys(targets[0].vars));
  for (const t of targets) if (JSON.stringify(Object.keys(t.vars)) !== keys) fail(`identity ${t.name}: keys differ from ${targets[0].name}`);
  if (new Set(targets.map((t) => t.postman)).size !== targets.length) fail(`${idFile}: two identity environments share a file name`);
  return { collections, targets };
}

function writeFiles(root, files) {
  for (const [rel, content] of Object.entries(files)) {
    const p = path.join(root, rel); fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, content);
  }
}

// Postman environment files: one per target.
function postmanEnvFiles(collections, targets) {
  return Object.fromEntries(targets.map((t) => [`00-environment-${t.postman}.postman_environment.json`,
    postmanEnvironment(t.stage ? postmanStageVars(collections, t) : t.vars, t.label)]));
}

function convert(insDir, idFile, idEnv, out) {
  const { collections, targets } = load(insDir, idFile, idEnv);
  const envFiles = postmanEnvFiles(collections, targets);
  writeFiles(path.join(out, 'postman'), Object.fromEntries(Object.entries(envFiles).map(([f, e]) => [f, stable(e)])));
  for (const c of collections) {
    const s = collectionSlug(c.file);
    writeFiles(path.join(out, 'postman'), { [`${s}.postman_collection.json`]: stable(toPostman(c)) });
    writeFiles(path.join(out, 'bruno', s), toBruno(c, targets));
  }
  console.log(`converted ${collections.length} collection(s), ${collections.reduce((n, c) => n + c.requests.length, 0)} request(s) for ${targets.map((t) => t.name).join(', ')}`);
}

const canon = (c) => ({ name: c.name, description: c.description, vars: c.vars, computed: c.computed, clock: c.clock ?? usesClock(c.requests), requests: c.requests });

function firstDiff(a, b, at = '') {
  if (JSON.stringify(a) === JSON.stringify(b)) return null;
  if (typeof a !== 'object' || typeof b !== 'object' || a === null || b === null || Array.isArray(a) !== Array.isArray(b)) {
    // The report is shared: a diff on a credential names the field, never its value.
    if (/secret|password|token/i.test(at)) return `${at}: values differ (redacted)`;
    return `${at || '/'}: ${JSON.stringify(a)?.slice(0, 160)} != ${JSON.stringify(b)?.slice(0, 160)}`;
  }
  for (const k of [...new Set([...Object.keys(a), ...Object.keys(b)])]) { const d = firstDiff(a[k], b[k], `${at}/${k}`); if (d) return d; }
  return `${at}: key order differs`;
}

async function postmanSchema() {
  const p = path.join(HERE, 'schemas', 'postman-collection-v2.1.0.json');
  if (!fs.existsSync(p)) {
    const r = await fetch(POSTMAN_SCHEMA_URL); if (!r.ok) fail(`schema download: HTTP ${r.status}`);
    fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, await r.text());
  }
  const text = fs.readFileSync(p, 'utf8');
  return { schema: JSON.parse(text), sha256: crypto.createHash('sha256').update(text).digest('hex') };
}

async function verify(insDir, idFile, idEnv, out) {
  const { collections, targets } = load(insDir, idFile, idEnv);
  const { schema, sha256 } = await postmanSchema();
  const ajv = new Ajv({ strict: false, allErrors: true }); addFormats(ajv);
  const validate = ajv.compile(schema);
  const lines = [`Postman schema v2.1.0 sha256 ${sha256}`];
  let failed = 0;
  const check = (label, ok, detail = '') => { lines.push(`${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? `  ${detail}` : ''}`); if (!ok) failed += 1; };

  for (const [f, expected] of Object.entries(postmanEnvFiles(collections, targets))) {
    const env = JSON.parse(fs.readFileSync(path.join(out, 'postman', f), 'utf8'));
    const envVars = Object.fromEntries(env.values.map((v) => [v.key, v.value]));
    const want = Object.fromEntries(expected.values.map((v) => [v.key, v.value]));
    check(`postman environment ${f.replace(/^00-environment-|\.postman_environment\.json$/g, '')}`, JSON.stringify(envVars) === JSON.stringify(want), firstDiff(want, envVars) ?? '');
  }
  const identityKeys = Object.keys(targets[0].vars);
  const identities = Object.fromEntries(targets.map((t) => [t.bruno, t.vars]));

  for (const c of collections) {
    const s = collectionSlug(c.file);
    const pj = JSON.parse(fs.readFileSync(path.join(out, 'postman', `${s}.postman_collection.json`), 'utf8'));
    const valid = validate(pj);
    check(`postman schema    ${s}`, valid, valid ? '' : ajv.errorsText(validate.errors).slice(0, 300));
    // A file that cannot even be read back is a failed check, reported like any other.
    const attempt = (fn) => { try { return fn(); } catch (e) { if (e instanceof Unsupported) return `unreadable: ${e.message}`; throw e; } };
    const d1 = attempt(() => firstDiff(canon(c), canon(fromPostman(pj))));
    check(`postman roundtrip ${s} (${c.requests.length} requests)`, !d1, d1 ?? '');
    let b = null;
    const stageKeys = c.stages ? Object.keys(Object.values(c.stages)[0]) : [];
    const d2 = attempt(() => { b = fromBruno(path.join(out, 'bruno', s), identityKeys, stageKeys, Object.keys(identities)); return firstDiff(canon(c), canon(b.collection)); });
    check(`bruno roundtrip   ${s} (${c.requests.length} requests)`, !d2, d2 ?? '');
    const d3 = b ? firstDiff(identities, b.identities) : 'bruno collection unreadable';
    check(`bruno identity    ${s} (${targets.length} environment(s))`, !d3, d3 ?? '');
    if (c.stages) {
      const want = Object.fromEntries(targets.map((t) => [t.bruno, c.stages[t.stage]]));
      const d4 = b ? firstDiff(want, b.stages) : 'bruno collection unreadable';
      check(`bruno stages      ${s} (${Object.keys(c.stages).join(', ')})`, !d4, d4 ?? '');
    }
  }
  console.log(lines.join('\n'));
  console.log(failed ? `\n${failed} check(s) FAILED` : '\nall checks passed');
  process.exit(failed ? 1 : 0);
}

const [cmd, ...args] = process.argv.slice(2);
try {
  if (cmd === 'convert' && args.length === 4) convert(...args);
  else if (cmd === 'verify' && args.length === 4) await verify(...args);
  else { console.error('usage: apiconv.mjs convert|verify <insomnia-dir> <identity-file> <identity-env-name> <out-dir>'); process.exit(2); }
} catch (e) {
  if (e instanceof Unsupported) { console.error(`UNSUPPORTED: ${e.message}`); process.exit(3); }
  throw e;
}
