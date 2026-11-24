#!/usr/bin/env python3
"""Enrich dependency findings with exploitation evidence and rank them.

Reads the deps-findings.json written by scan-deps.sh (or bare CVE ids given
with --cve), then adds for every CVE:

  * CISA KEV membership  - reliable evidence it HAS BEEN exploited in the wild
  * EPSS score           - global forecast: probability of exploitation activity
                           against this CVE somewhere in the next 30 days
  * CVSS v3 base score   - computed from the vector, no network call

and assigns a priority P0..P3 (rule in references/dependency-triage.md).

Standard library only. Run it in Docker, isolated mode:

  docker run --rm -v "$OUT":/out \
    -v "<skill>/scripts":/scripts:ro python:3.12-slim \
    python -I /scripts/enrich-kev-epss.py /out/deps-findings.json --out /out

Exit codes: 0 = nothing at P0/P1, 1 = at least one P0/P1, 2 = failure.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

KEV_URL = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
EPSS_URL = "https://api.first.org/data/v1/epss"
EPSS_CHUNK = 80  # keeps the query string under the API's URL length limit
EPSS_HIGH = 0.10  # skill convention, not a FIRST standard: see dependency-triage.md
USER_AGENT = "audit-security-skill/1.0"


def http_json(url: str, timeout: int = 60) -> dict:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def fetch_kev() -> tuple[dict[str, dict], dict]:
    feed = http_json(KEV_URL)
    by_cve = {entry["cveID"]: entry for entry in feed.get("vulnerabilities", [])}
    meta = {"catalogVersion": feed.get("catalogVersion"), "count": feed.get("count")}
    return by_cve, meta


def fetch_epss(cves: list[str]) -> dict[str, dict]:
    scores: dict[str, dict] = {}
    for start in range(0, len(cves), EPSS_CHUNK):
        chunk = cves[start:start + EPSS_CHUNK]
        url = f"{EPSS_URL}?{urllib.parse.urlencode({'cve': ','.join(chunk), 'limit': EPSS_CHUNK})}"
        for row in http_json(url).get("data", []):
            scores[row["cve"]] = {
                "epss": float(row["epss"]),
                "percentile": float(row["percentile"]),
                "date": row.get("date"),
            }
    return scores


def roundup(value: float) -> float:
    """CVSS v3.1 specification, appendix A."""
    scaled = int(round(value * 100000))
    if scaled % 10000 == 0:
        return scaled / 100000.0
    return (math.floor(scaled / 10000) + 1) / 10.0


def cvss3_base(vector: str | None) -> float | None:
    """Base score of a CVSS v3.0/v3.1 vector; None for anything else (v2, v4)."""
    if not vector or not vector.startswith("CVSS:3."):
        return None
    try:
        metrics = dict(part.split(":", 1) for part in vector.split("/")[1:])
        scope_changed = metrics["S"] == "C"
        av = {"N": 0.85, "A": 0.62, "L": 0.55, "P": 0.2}[metrics["AV"]]
        ac = {"L": 0.77, "H": 0.44}[metrics["AC"]]
        pr = {"N": 0.85, "L": 0.68 if scope_changed else 0.62, "H": 0.5 if scope_changed else 0.27}[metrics["PR"]]
        ui = {"N": 0.85, "R": 0.62}[metrics["UI"]]
        cia = {"H": 0.56, "L": 0.22, "N": 0.0}
        iss = 1 - (1 - cia[metrics["C"]]) * (1 - cia[metrics["I"]]) * (1 - cia[metrics["A"]])
    except (KeyError, ValueError):
        return None
    impact = 7.52 * (iss - 0.029) - 3.25 * (iss - 0.02) ** 15 if scope_changed else 6.42 * iss
    if impact <= 0:
        return 0.0
    exploitability = 8.22 * av * ac * pr * ui
    if scope_changed:
        return roundup(min(1.08 * (impact + exploitability), 10))
    return roundup(min(impact + exploitability, 10))


LABEL_SCORE = {"CRITICAL": 9.0, "HIGH": 7.0, "MODERATE": 4.0, "MEDIUM": 4.0, "LOW": 0.1}


def prioritise(finding: dict) -> tuple[str, str]:
    """Return (priority, reason). First matching rule wins."""
    if finding["id"].startswith("MAL-") or (finding.get("summary") or "").lower().startswith("malicious"):
        return "P0", "malicious package: treat every machine that installed it as compromised"
    if finding["kev"]:
        ransomware = " (ransomware use: Known)" if finding["kev_ransomware"] == "Known" else ""
        return "P0", f"in CISA KEV since {finding['kev_date_added']}{ransomware}"
    epss = finding["epss"]
    if epss is not None and epss >= EPSS_HIGH:
        return "P1", f"EPSS {epss:.3f} >= {EPSS_HIGH}"
    score = finding["cvss"]
    if score is None:
        score = LABEL_SCORE.get((finding.get("advisory_severity") or "").upper())
        source = "advisory label"
    else:
        source = "CVSS"
    if score is None:
        return "P2", "no usable CVSS and no exploitation evidence: unknown severity, review by hand"
    if score >= 9.0:
        return "P1", f"{source} {score} critical"
    if score >= 7.0:
        return "P2", f"{source} {score} high, no exploitation evidence"
    return "P3", f"{source} {score}, no exploitation evidence"


def load_findings(args: argparse.Namespace) -> list[dict]:
    findings: list[dict] = []
    if args.findings:
        findings = json.loads(Path(args.findings).read_text(encoding="utf-8"))
    for cve in args.cve:
        findings.append({"ecosystem": "-", "name": "-", "version": "-", "id": cve, "cves": [cve],
                         "summary": "", "cvss_vector": None, "advisory_severity": None, "fixed": []})
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("findings", nargs="?", help="deps-findings.json from scan-deps.sh")
    parser.add_argument("--cve", action="append", default=[], help="extra CVE id (repeatable)")
    parser.add_argument("--out", help="directory for deps-triage.json and deps-triage.md")
    args = parser.parse_args()

    findings = load_findings(args)
    if not findings:
        print("no finding to enrich", file=sys.stderr)
        return 0
    cves = sorted({cve for finding in findings for cve in finding.get("cves", [])})

    try:
        kev, kev_meta = fetch_kev()
        epss = fetch_epss(cves) if cves else {}
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        # Never rank without the exploitation data: a silent fallback to CVSS
        # alone would hide the KEV entries this script exists to surface.
        print(f"enrichment failed, no triage produced: {error}", file=sys.stderr)
        return 2

    for finding in findings:
        ids = finding.get("cves", [])
        kev_hit = next((kev[cve] for cve in ids if cve in kev), None)
        best = max((epss[cve] for cve in ids if cve in epss), key=lambda row: row["epss"], default=None)
        finding["kev"] = kev_hit is not None
        finding["kev_date_added"] = kev_hit["dateAdded"] if kev_hit else None
        finding["kev_ransomware"] = kev_hit.get("knownRansomwareCampaignUse") if kev_hit else None
        finding["epss"] = best["epss"] if best else None
        finding["epss_percentile"] = best["percentile"] if best else None
        finding["cvss"] = cvss3_base(finding.get("cvss_vector"))
        finding["priority"], finding["priority_reason"] = prioritise(finding)

    findings.sort(key=lambda f: (f["priority"], -(f["epss"] or 0), -(f["cvss"] or 0), f["name"]))

    lines = [
        f"KEV catalog {kev_meta['catalogVersion']} ({kev_meta['count']} entries), "
        f"EPSS for {len(epss)}/{len(cves)} CVE ids",
        "",
        "| Prio | Package | Vuln | CVE | KEV | EPSS (pct) | CVSS | Fixed in | Why |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for f in findings:
        epss_cell = f"{f['epss']:.3f} ({f['epss_percentile']:.0%})" if f["epss"] is not None else "n/a"
        cvss_cell = f["cvss"] if f["cvss"] is not None else (f.get("advisory_severity") or "n/a")
        lines.append(
            f"| {f['priority']} | {f['name']}@{f['version']} | {f['id']} | {', '.join(f.get('cves', [])) or '-'} "
            f"| {'YES' if f['kev'] else 'no'} | {epss_cell} | {cvss_cell} "
            f"| {', '.join(f.get('fixed', [])) or 'none'} | {f['priority_reason']} |"
        )
    table = "\n".join(lines)
    print(table)

    if args.out:
        out = Path(args.out)
        out.mkdir(parents=True, exist_ok=True)
        (out / "deps-triage.json").write_text(json.dumps(findings, indent=2) + "\n", encoding="utf-8")
        (out / "deps-triage.md").write_text(table + "\n", encoding="utf-8")

    return 1 if any(f["priority"] in ("P0", "P1") for f in findings) else 0


if __name__ == "__main__":
    sys.exit(main())
