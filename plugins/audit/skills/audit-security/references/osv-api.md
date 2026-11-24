# OSV.dev API

OSV.dev is Google's open vulnerability database. It aggregates the GitHub
Advisory Database (`GHSA-`), PyPA (`PYSEC-`), Go (`GO-`), RustSec
(`RUSTSEC-`), the OpenSSF malicious-packages feed (`MAL-`), distribution
trackers and more, in one schema. No key, no account.

Everything below was run against `https://api.osv.dev` on 2026-11-24. Outputs
are real, trimmed with `...` where long.

All commands assume a shell with curl and jq. Docker-only equivalent:

```bash
docker run --rm curlimages/curl:8.23.0 -s -X POST https://api.osv.dev/v1/query \
  -d '{"package":{"name":"minimist","ecosystem":"npm"},"version":"0.0.8"}' \
  | docker run --rm -i ghcr.io/jqlang/jq:1.8.2 '[.vulns[]?.id]'
```

## Endpoints

| Endpoint | Use | Returns |
|---|---|---|
| `POST /v1/query` | One package at one version | Full vulnerability records |
| `POST /v1/querybatch` | Up to 1000 packages in one call | **Only `id` and `modified`** per hit |
| `GET /v1/vulns/{id}` | One record by id | Full record |

The usual pattern is therefore: `querybatch` to learn which ids apply, then
`GET /v1/vulns/{id}` for each distinct id. That is exactly what
`<skill>/scripts/scan-deps.sh --mode api` does.

## POST /v1/query

Request:

```json
{"package": {"name": "minimist", "ecosystem": "npm"}, "version": "0.0.8"}
```

Response (2 vulnerabilities; first one shown, `details` and `references` cut):

```json
{
  "vulns": [
    {
      "id": "GHSA-vh95-rmgr-6w4m",
      "aliases": ["CVE-2020-7598"],
      "summary": "...",
      "modified": "...", "published": "...", "schema_version": "...",
      "severity": [
        {"type": "CVSS_V3", "score": "CVSS:3.1/AV:N/AC:H/PR:N/UI:N/S:U/C:L/I:L/A:L"}
      ],
      "affected": [
        {"ranges": [{"type": "SEMVER", "events": [{"introduced": "0"}, {"fixed": "0.2.1"}]}]}
      ],
      "database_specific": {
        "cwe_ids": ["CWE-1321"],
        "severity": "MODERATE",
        "github_reviewed": true,
        "github_reviewed_at": "2020-04-03T21:42:08Z",
        "nvd_published_at": "2020-03-11T23:15:00Z"
      }
    }
  ]
}
```

Fields you actually use:

| Field | Meaning | Trap |
|---|---|---|
| `id` | The advisory id in its home database | Rarely a CVE; the CVE is in `aliases` |
| `aliases` | Same vulnerability in other databases | Can be absent or `null` (seen on `MAL-2025-20690`) |
| `severity[].score` | A CVSS **vector**, not a number | Compute the base score yourself; `enrich-kev-epss.py` does |
| `database_specific.severity` | GitHub's label: LOW, MODERATE, HIGH, CRITICAL | GHSA records only |
| `database_specific.cwe_ids` | CWE ids | GHSA records only |
| `affected[].ranges[].events` | `introduced` / `fixed` pairs | Several `affected` entries for several packages or branches |
| `withdrawn` | Set when the advisory was retracted | See "withdrawn" below |

Other query forms:

```json
{"package": {"purl": "pkg:pypi/jinja2@2.4.1"}}
{"commit": "6879efc2c1596d11a6a6ad296f80063b558d5e0f"}
```

A purl carries its own version: do not add `"version"` next to it. The commit
form is for C/C++ and vendored code with no package version; the hash above
is a real harfbuzz commit and returns `CVE-2023-25193` among others.

## POST /v1/querybatch

Request:

```json
{"queries": [
  {"package": {"name": "lodash",   "ecosystem": "npm"}, "version": "4.17.4"},
  {"package": {"name": "left-pad", "ecosystem": "npm"}, "version": "1.3.0"},
  {"package": {"purl": "pkg:pypi/jinja2@2.4.1"}}
]}
```

Response (9 ids for lodash, none for left-pad, 18 for jinja2; cut):

```json
{"results": [
  {"vulns": [
    {"id": "GHSA-29mw-wpgm-hmr9", "modified": "2025-09-29T21:12:31.102523Z"},
    {"id": "GHSA-jf85-cpcp-j695", "modified": "2026-09-10T03:47:55.238868Z"}
  ]},
  {},
  {"vulns": [
    {"id": "GHSA-462w-v97r-4m45", "modified": "2024-09-24T21:03:59.802687Z"},
    {"id": "PYSEC-2014-8",        "modified": "2023-11-08T03:57:34.512953Z"}
  ]}
]}
```

`results` is positional: `results[i]` answers `queries[i]`. There is no
package name in the response, so keep your query list to join on.

## GET /v1/vulns/{id}

```bash
curl -s https://api.osv.dev/v1/vulns/GHSA-jf85-cpcp-j695 \
  | jq '{id, aliases, summary, severity, cwe: .database_specific.cwe_ids, label: .database_specific.severity}'
```

```json
{
  "id": "GHSA-jf85-cpcp-j695",
  "aliases": ["CVE-2019-10744", "SNYK-JS-LODASH-450202"],
  "summary": "Prototype Pollution in lodash",
  "severity": [{"type": "CVSS_V3", "score": "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:H/A:H"}],
  "cwe": ["CWE-1321", "CWE-20"],
  "label": "CRITICAL"
}
```

## Pitfalls, each one observed

| What you send or see | What happens | Consequence |
|---|---|---|
| A package with no vulnerability | HTTP 200, body `{}`: **no `vulns` key** | `.vulns[]` fails in jq; write `.vulns[]?` or `(.vulns // [])` |
| `"ecosystem": "NPM"` | HTTP 400 `{"code":3,"message":"invalid ecosystem"}` | Ecosystem names are case-sensitive: `npm`, `PyPI`, `Go`, `crates.io`, `Maven`, `Packagist`, `NuGet`, `RubyGems` |
| No `ecosystem` at all | HTTP 200 with hits from **every** ecosystem | `lodash@4.17.4` returned `CLSA-...` (TuxCare) and `ECHO-...` ids on top of the 9 GHSA: always send the ecosystem |
| Unknown id on `/v1/vulns/` | HTTP 404 `{"code":5,"message":"Vulnerability not found"}` | Check the status code, not only the body |
| A package with very many hits | A `next_page_token` appears next to `vulns` | Repeat the same query with `"page_token": "<token>"` until it is gone; `scan-deps.sh` does not follow it: it marks the run `INCOMPLETE` in `deps-coverage.json` and exits 2 |
| 1001 queries in one batch | HTTP 400 `{"code":3,"message":"too many queries"}` | Chunk; `scan-deps.sh` sends 1000 at a time |
| A purl with `@version` **and** a `"version"` field | HTTP 400 `{"code":3,"message":"version specified in params and PURL query"}` | One or the other |

**Withdrawn advisories.** `GHSA-7fhm-mqm4-2wp7` once listed `minimist < 1.2.2`
and was withdrawn on 2020-04-03. `POST /v1/query` for `minimist@0.0.8` does
not return it (2 hits), while GitHub's REST endpoint
`GET https://api.github.com/advisories?ecosystem=npm&affects=minimist@0.0.8`
does (3 hits, the third with `withdrawn_at` set). When two sources disagree
on a count, look for `withdrawn` before concluding that one is incomplete.

**Malicious packages.** `flatmap-stream@0.1.1` (the 2018 event-stream
incident) returns `MAL-2025-20690` "Malicious code in flatmap-stream (npm)"
next to two GHSA records, with no CVE alias and no CVSS. A CVE-only
workflow never sees it. `enrich-kev-epss.py` ranks any `MAL-` id, and any
advisory whose summary starts with "Malicious", P0.

## What OSV cannot tell you

- Whether your code calls the vulnerable function (see
  `dependency-triage.md`, reachability).
- Whether the vulnerability is being exploited: that is KEV and EPSS.
- Anything about a package that has no advisory yet: a typosquat published
  this morning has a clean OSV record.
- Anything about a version it cannot parse: a git URL or a local `file:`
  dependency is skipped by the API path of `scan-deps.sh` (it shows up in
  `deps-hygiene.json` as `non-registry-source`). Lockfile formats the API
  path cannot read (`pnpm-lock.yaml`, `yarn.lock`, `go.mod`, ...) are listed
  under `skipped` in `deps-coverage.json` and make the run exit 2.

## The two enrichment feeds

Also verified on 2026-11-24.

**CISA KEV**, one JSON file, about 1.9 MB, no key:
`https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json`

```json
{
  "title": "CISA Catalog of Known Exploited Vulnerabilities",
  "catalogVersion": "2026.11.23",
  "count": 1792,
  "vulnerabilities": [
    {
      "cveID": "CVE-2021-44228",
      "vendorProject": "Apache", "product": "Log4j2",
      "dateAdded": "2021-12-10",
      "dueDate": "2021-12-24",
      "knownRansomwareCampaignUse": "Known",
      "cwes": ["CWE-20", "CWE-400", "CWE-502"]
    }
  ]
}
```

Membership is binary: a CVE is in the list or not. `knownRansomwareCampaignUse`
is `Known` or `Unknown`.

**EPSS**, FIRST.org, no key: `https://api.first.org/data/v1/epss?cve=<id>,<id>`

```json
{"status": "OK", "total": 2, "offset": 0, "limit": 100, "data": [
  {"cve": "CVE-2021-44228", "epss": "0.999990000", "percentile": "1.000000000", "date": "2026-11-23"},
  {"cve": "CVE-2019-10744", "epss": "0.050060000", "percentile": "0.924470000", "date": "2026-11-23"}
]}
```

`epss` and `percentile` are **strings**. An unknown CVE is not an error: it
is simply missing from `data` (`"total": 0, "data": []`). `limit` defaults to
100; the script sends 80 ids per request to stay under the URL length limit.
Scores are recomputed daily, so record the `date` in the report.
