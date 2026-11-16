#!/usr/bin/env python3
"""conso-report.py - instant `conso` report read from the precomputed cache (stdlib only, Python 3.9+).

Usage: conso [-g day|week|month|session] [-d DAYS | -s DATE -u DATE] [-e EUR] [-n] [-S] [-j]
             [--refresh] [-h]
  -g  granularity (default day; `session` is not in the cache: it runs one live ccusage scan)
  -d  last DAYS days, today included (default 7)
  -s/-u  explicit range YYYY-MM-DD (overrides -d)
  -e  out-of-plan spend (EUR) given by hand, shown when no live figure exists
  -n  offline: never refresh (no Docker, no network); with --refresh: refresh without the API call
  -S  silent refresh (what the timer runs); --refresh forces a live refresh then reports
  -j  JSON instead of the table (includes the billed figures)

Reads CONSO_CACHE (default ~/.local/share/conso/cache.json) and CONSO_STORE (extra.jsonl snapshots).
Freshness: older than CONSO_STALE_AFTER (default 3x the timer interval, else 30 min) prints a notice;
a missing/unreadable cache triggers one refresh (unless -n). CONSO_NOW (ISO UTC) overrides the clock.
"""
import argparse
import json
import os
import subprocess
import sys
from datetime import date, datetime, timedelta, timezone

SCHEMA = 1
SPARK = "▁▂▃▄▅▆▇█"
HERE = os.path.dirname(os.path.realpath(__file__))
DEFAULT_STALE = 1800


def parse_duration(v):
    """'30m' / '2h' / '90' (seconds) -> seconds, or None when malformed."""
    v = (v or "").strip()
    mult = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    unit = v[-1:] if v[-1:] in mult else ""
    num = v[: len(v) - len(unit)]
    if not num.isdigit() or int(num) <= 0:
        return None
    return int(num) * mult.get(unit, 1)


def now_utc():
    raw = os.environ.get("CONSO_NOW")
    if raw:
        return parse_ts(raw)
    return datetime.now(timezone.utc)


def parse_ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)


def stale_threshold(conso_dir):
    env = parse_duration(os.environ.get("CONSO_STALE_AFTER", ""))
    if env:
        return env
    try:
        with open(os.path.join(conso_dir, "interval")) as f:
            return 3 * int(f.read().strip())
    except (OSError, ValueError):
        return DEFAULT_STALE


def fmt_age(sec):
    sec = int(max(sec, 0))
    if sec < 90:
        return "%ds" % sec
    if sec < 5400:
        return "%dm" % round(sec / 60)
    if sec < 172800:
        return "%dh%02dm" % (sec // 3600, sec % 3600 // 60)
    return "%dd" % (sec // 86400)


def load_cache(path):
    """-> (cache dict | None, reason). reason is 'missing' or 'unreadable' when cache is None."""
    try:
        with open(path) as f:
            raw = f.read()
    except OSError:
        return None, "missing"
    try:
        d = json.loads(raw)
        if d.get("schema") != SCHEMA or not isinstance(d.get("days"), dict) or not d.get("generated_at"):
            return None, "unreadable"
        parse_ts(d["generated_at"])
        return d, ""
    except (ValueError, AttributeError, TypeError):
        return None, "unreadable"


def load_snapshots(path):
    snaps = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    s = json.loads(line)
                    if "ts" in s and "day" in s and "used" in s:
                        snaps.append(s)
                except ValueError:
                    continue  # a torn line must not hide the others
    except OSError:
        pass
    snaps.sort(key=lambda s: s["ts"])
    return snaps


def billed_per_day(snaps):
    """Per-day billed amounts (major units) from consecutive snapshot deltas.

    The delta is attributed to the day of the later snapshot; a drop of `used` means the month rolled
    over, so the new value counts in full. Needs 2+ snapshots, else {}.
    """
    per_day = {}
    for a, b in zip(snaps, snaps[1:]):
        f = 10 ** int(b.get("dp", 2))
        delta = b["used"] - a["used"] if b["used"] >= a["used"] else b["used"]
        per_day[b["day"]] = per_day.get(b["day"], 0.0) + delta / f
    return per_day


def day_list(until, n):
    return [(until - timedelta(days=i)).isoformat() for i in range(n - 1, -1, -1)]


def sparkline(values):
    """values: list of float|None (None = no data). Scaled to the max of the series."""
    top = max([v for v in values if v is not None] or [0])
    out = []
    for v in values:
        if v is None:
            out.append("·")
        elif top <= 0:
            out.append(SPARK[0])
        else:
            out.append(SPARK[min(len(SPARK) - 1, int(v / top * (len(SPARK) - 1) + 0.5))])
    return "".join(out)


def billed_summary(snaps, today):
    """Billed consumption block: month-to-date, last 7 days, previous 7 days, per-day series."""
    res = {"snapshots": len(snaps), "currency": snaps[-1].get("cur", "EUR") if snaps else None,
           "since": snaps[0]["ts"] if snaps else None, "enough": len(snaps) >= 2}
    if not snaps:
        return res
    last = snaps[-1]
    f = 10 ** int(last.get("dp", 2))
    this_month = today.isoformat()[:7]
    res["month_to_date"] = last["used"] / f if last["day"][:7] == this_month else None
    res["month_to_date_as_of"] = last["ts"]
    if not res["enough"]:
        return res
    per_day = billed_per_day(snaps)
    first_day = snaps[0]["day"]
    last7 = day_list(today, 7)
    prev7 = day_list(today - timedelta(days=7), 7)
    # a day has data only after the first snapshot's day (deltas start with the second snapshot)
    series = [(d, per_day.get(d, 0.0) if d > first_day or d in per_day else None) for d in last7]
    res["per_day"] = {d: v for d, v in series}
    res["last7"] = sum(v for _, v in series if v is not None)
    res["last7_complete"] = all(v is not None for _, v in series)
    prev_ok = prev7[0] > first_day
    res["prev7"] = sum(per_day.get(d, 0.0) for d in prev7) if prev_ok else None
    if res["prev7"]:
        res["change_pct"] = (res["last7"] - res["prev7"]) / res["prev7"] * 100
    else:
        res["change_pct"] = None
    res["sparkline"] = sparkline([v for _, v in series])
    return res


def week_label(day):
    y, w, _ = date.fromisoformat(day).isocalendar()
    return "%d-W%02d" % (y, w)


def aggregate(days, since, until, gran):
    """Cache days -> ordered rows [{period, cost, tokens, by{model:cost}}] for the window."""
    key = {"day": lambda d: d, "week": week_label, "month": lambda d: d[:7]}[gran]
    rows = {}
    if gran == "day":  # idle days still get a row, so the window is always complete
        d0, d1 = date.fromisoformat(since), date.fromisoformat(until)
        for i in range((d1 - d0).days + 1):
            k = (d0 + timedelta(days=i)).isoformat()
            rows[k] = {"period": k, "cost": 0.0, "tokens": 0, "by": {}, "days": []}
    for d in sorted(days):
        if d < since or d > until:
            continue
        r = rows.setdefault(key(d), {"period": key(d), "cost": 0.0, "tokens": 0, "by": {}, "days": []})
        v = days[d]
        r["cost"] += v.get("cost", 0)
        r["tokens"] += v.get("tokens", 0)
        r["days"].append(d)
        for m, mv in (v.get("models") or {}).items():
            r["by"][m] = r["by"].get(m, 0.0) + mv.get("cost", 0)
    return list(rows.values())


def build(cache, snaps, since, until, gran, today):
    rows = aggregate(cache["days"], since, until, gran)
    per_day = billed_per_day(snaps) if len(snaps) >= 2 else {}
    first_day = snaps[0]["day"] if snaps else None
    for r in rows:
        if gran == "day" and len(snaps) >= 2:
            d = r["period"]
            r["billed"] = per_day.get(d, 0.0) if (d > first_day or d in per_day) else None
    by_model = {}
    for r in rows:
        for m, c in r["by"].items():
            by_model[m] = by_model.get(m, 0.0) + c
    total = {"cost": sum(r["cost"] for r in rows), "tokens": sum(r["tokens"] for r in rows), "byModel": by_model}
    return {"since": since, "until": until, "granularity": gran, "generated_at": cache["generated_at"],
            "covers_since": cache.get("covers_since"), "rows": rows, "total": total,
            "billed": billed_summary(snaps, today), "usage": cache.get("usage")}


def money(v, cur):
    return "—" if v is None else "%.2f %s" % (v, cur)


def render(rep, age_s, extra_eur):
    out = []
    gran = rep["granularity"]
    out.append("Claude Code usage %s -> %s (per %s) · cache %s old\n" % (rep["since"], rep["until"], gran, fmt_age(age_s)))
    rows, total = rep["rows"], rep["total"]
    cols = sorted(total["byModel"], key=lambda m: -total["byModel"][m])
    show_billed = gran == "day" and rep["billed"].get("enough")
    cur = rep["billed"].get("currency") or "EUR"
    w = max([8] + [len(r["period"]) for r in rows])
    head = ["period".ljust(w)] + [c.rjust(18) for c in cols] + ["total".rjust(11), "tokens".rjust(10)]
    if show_billed:
        head.append(("billed " + cur).rjust(14))
    line = "  ".join(head)
    out += [line, "-" * len(line)]
    for r in rows:
        cells = [r["period"].ljust(w)] + [("$%.2f" % r["by"].get(c, 0)).rjust(18) for c in cols]
        cells += [("$%.2f" % r["cost"]).rjust(11), ("%.1fM" % (r["tokens"] / 1e6)).rjust(10)]
        if show_billed:
            b = r.get("billed")
            cells.append(("—" if b is None else "%.2f" % b).rjust(14))
        out.append("  ".join(cells))
    out.append("-" * len(line))
    cells = ["TOTAL".ljust(w)] + [("$%.2f" % total["byModel"].get(c, 0)).rjust(18) for c in cols]
    cells += [("$%.2f" % total["cost"]).rjust(11), ("%.1fM" % (total["tokens"] / 1e6)).rjust(10)]
    if show_billed:
        cells.append(("%.2f" % sum(r["billed"] for r in rows if r.get("billed") is not None)).rjust(14))
    out.append("  ".join(cells))
    if total["cost"]:
        out.append("\nShare: " + " | ".join("%s %.1f%%" % (c, 100 * total["byModel"][c] / total["cost"]) for c in cols))
    out.append("(estimate = ccusage at public API prices; billed = claude.ai out-of-plan counter, different currency, no FX applied)")
    cs = rep.get("covers_since")
    if cs and rep["since"] < cs:
        out.append("note: the cache only goes back to %s; earlier days are missing" % cs)

    # --- billed consumption ---------------------------------------------------------
    b = rep["billed"]
    out.append("\nBilled consumption (real out-of-plan counter, not the estimate):")
    if b["snapshots"] == 0:
        out.append("  no snapshot yet. They are recorded by `conso --refresh` / the timer.")
    else:
        if b.get("month_to_date") is not None:
            out.append("  month to date   %s   (as of %s UTC)" % (money(b["month_to_date"], cur), b["month_to_date_as_of"][:16].replace("T", " ")))
        else:
            out.append("  month to date   not known yet this month (last snapshot %s UTC)" % b["month_to_date_as_of"][:16].replace("T", " "))
        if not b["enough"]:
            out.append("  only %d snapshot so far: per-day figures need 2+ (they accumulate with each refresh)." % b["snapshots"])
        else:
            part = "" if b["last7_complete"] else "  (partial: snapshots since %s UTC)" % b["since"][:16].replace("T", " ")
            out.append("  last 7 days     %s%s" % (money(b["last7"], cur), part))
            if b["prev7"] is None:
                out.append("  previous 7 days n/a (history too short)")
            else:
                chg = "" if b["change_pct"] is None else "  (%+.0f%%)" % b["change_pct"]
                out.append("  previous 7 days %s%s" % (money(b["prev7"], cur), chg))
            days = list(b["per_day"])
            out.append("  trend           %s   %s -> %s" % (b["sparkline"], days[0][5:], days[-1][5:]))
    u = rep.get("usage") or {}
    x = u.get("extra_usage")
    if extra_eur and not x:
        out.append("  given by hand   %s EUR = %.1f%% of the estimated API cost above" % (extra_eur, 100 * float(extra_eur) / (total["cost"] or 1)))
    elif not b["snapshots"] and not x:
        out.append("  pass -e <EUR> (claude.ai > Settings > Usage) to type the value by hand.")

    # --- plan limits (latest successful live fetch) ---------------------------------
    if u.get("limits"):
        out.append("\nPlan (live, claude.ai, fetched %s UTC%s):" % ((u.get("fetched_at") or "?")[:16].replace("T", " "),
                   "" if u.get("ok") else "; latest fetch failed: " + str(u.get("error"))))
        for l in u["limits"]:
            sc = l.get("scope") or {}
            name = (sc.get("model") or {}).get("display_name") or (sc.get("surface") or {}).get("display_name") or ""
            lab = l.get("kind", "?") + (":" + name if name else "")
            rs = l.get("resets_at")
            out.append("  %s %3s%%  %s%s" % (lab.ljust(18), l.get("percent", "?"), l.get("severity", ""),
                       "  resets " + rs[:16].replace("T", " ") + " UTC" if rs else ""))
        if x and x.get("is_enabled") and x.get("monthly_limit"):
            out.append("  out-of-plan limit  %s %s" % (x["monthly_limit"] / 10 ** x.get("decimal_places", 2), x.get("currency", "")))
    elif u.get("error"):
        out.append("\nPlan (live): unavailable - %s" % u["error"])
    return "\n".join(out)


def refresh_bin():
    return os.environ.get("CONSO_REFRESH_BIN") or os.path.join(HERE, "conso-refresh.sh")


def run_refresh(silent, offline):
    cmd = [refresh_bin()] + (["-q"] if silent else []) + (["-n"] if offline else [])
    return subprocess.call(cmd)


def main(argv):
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("-g", default="day")
    ap.add_argument("-d", type=int, default=7)
    ap.add_argument("-s")
    ap.add_argument("-u")
    ap.add_argument("-e")
    ap.add_argument("-n", action="store_true")
    ap.add_argument("-S", action="store_true")
    ap.add_argument("-j", action="store_true")
    ap.add_argument("--refresh", action="store_true")
    ap.add_argument("-h", "--help", action="store_true")
    a = ap.parse_args(argv)
    if a.help:
        print(__doc__)
        return 0
    if a.g not in ("day", "week", "month", "session"):
        print("granularity must be day|week|month|session", file=sys.stderr)
        return 1
    if a.d < 1:
        print("-d must be >= 1", file=sys.stderr)
        return 1

    store = os.environ.get("CONSO_STORE") or os.path.expanduser("~/.local/share/conso/extra.jsonl")
    cache_path = os.environ.get("CONSO_CACHE") or os.path.join(os.path.dirname(store), "cache.json")
    conso_dir = os.environ.get("CONSO_DIR") or os.path.expanduser("~/.config/conso")

    if a.S or a.refresh:  # slow path, explicit
        rc = run_refresh(a.S, a.n)
        if a.S or rc != 0:
            return rc

    now = now_utc()
    today = now.astimezone().date()
    until = a.u or today.isoformat()
    since = a.s or (date.fromisoformat(until) - timedelta(days=a.d - 1)).isoformat()

    if a.g == "session":  # not in the cache: one live scan
        r = subprocess.run([refresh_bin(), "--session", since, until], stdout=subprocess.PIPE)
        if r.returncode != 0:
            return r.returncode
        data = json.loads(r.stdout or b"{}")
        rows = next((v for v in data.values() if isinstance(v, list)), [])
        if a.j:
            print(json.dumps(data, indent=2))
            return 0
        print("Claude Code usage %s -> %s (per session, live scan)\n" % (since, until))
        for s in rows:
            print("%-40s  $%8.2f  %7.1fM" % (str(s.get("period") or s.get("sessionId"))[:40], s.get("totalCost", 0), s.get("totalTokens", 0) / 1e6))
        return 0

    cache, why = load_cache(cache_path)
    if cache is None:
        if a.n:
            print("conso: cache %s (%s) and -n forbids refreshing. Run `conso --refresh`." % (why, cache_path), file=sys.stderr)
            return 1
        print("conso: cache %s, building it once (first run takes a few seconds)..." % why, file=sys.stderr)
        rc = run_refresh(False, False)
        cache, why = load_cache(cache_path)
        if cache is None:
            print("conso: refresh did not produce a usable cache (rc=%s)." % rc, file=sys.stderr)
            return 1
    age = (now - parse_ts(cache["generated_at"])).total_seconds()
    limit = stale_threshold(conso_dir)
    snaps = load_snapshots(store)
    rep = build(cache, snaps, since, until, a.g, date.fromisoformat(until) if a.u else today)
    rep["cache_age_seconds"] = int(age)
    rep["stale"] = age > limit
    if a.j:
        print(json.dumps(rep, indent=2))
        return 0
    if age > limit:
        print("! cache is %s old (threshold %s) — run `conso --refresh`, or enable the timer\n" % (fmt_age(age), fmt_age(limit)))
    print(render(rep, age, a.e))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
