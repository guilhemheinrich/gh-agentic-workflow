#!/usr/bin/env python3
"""Tests for conso-report.py (reader, billed deltas, 7-day window, freshness) - fixtures only, no Docker inside.

Run from the repo root, in Docker (python 3.12) and on the macOS system Python line (3.9):
  docker run --rm -v "$PWD/skills/ai-usage-tracking/scripts/claude-code-macos":/t:ro python:3.12-alpine python -I /t/test-conso-report.py
  docker run --rm -v "$PWD/skills/ai-usage-tracking/scripts/claude-code-macos":/t:ro python:3.9-alpine python -I /t/test-conso-report.py
The merge step (node) is tested by test-conso-merge.js, the installer by test-setup-sandbox.sh.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import date, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("conso_report", os.path.join(HERE, "conso-report.py"))
cr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cr)

NOW = "2026-11-13T12:00:00Z"
TODAY = date(2026, 11, 13)


def make_cache(generated_at=NOW, ndays=20, usage=None):
    days = {}
    for i in range(ndays):
        d = (TODAY - timedelta(days=i)).isoformat()
        days[d] = {"cost": 10.0 + i, "tokens": 1_000_000 * (i + 1),
                   "models": {"opus-4-7": {"cost": 8.0 + i, "tokens": 800_000}, "sonnet-5": {"cost": 2.0, "tokens": 200_000}}}
    return {"schema": 1, "generated_at": generated_at, "covers_since": min(days), "days": days, "usage": usage}


def snap(ts, used, cur="EUR", dp=2):
    return {"ts": ts, "day": ts[:10], "used": used, "dp": dp, "cur": cur}


class Env:
    """Temp dir with cache/store paths wired through the environment."""
    def __init__(self, cache=None, raw_cache=None, snaps=None):
        self.dir = tempfile.mkdtemp()
        self.cache = os.path.join(self.dir, "cache.json")
        self.store = os.path.join(self.dir, "extra.jsonl")
        if raw_cache is not None:
            open(self.cache, "w").write(raw_cache)
        elif cache is not None:
            with open(self.cache, "w") as f:
                json.dump(cache, f)
        if snaps is not None:
            open(self.store, "w").write("".join(json.dumps(s) + "\n" for s in snaps))
        self.env = dict(os.environ, TZ="UTC", CONSO_NOW=NOW, CONSO_CACHE=self.cache, CONSO_STORE=self.store,
                        CONSO_DIR=os.path.join(self.dir, "none"), CONSO_REFRESH_BIN=os.path.join(self.dir, "stub-refresh.sh"))
        self.env.pop("CONSO_STALE_AFTER", None)

    def stub_refresh(self, cache):
        """A refresh stub that writes `cache` and records that it ran."""
        src = os.path.join(self.dir, "fresh.json")
        with open(src, "w") as f:
            json.dump(cache, f)
        script = ("#!/bin/sh\nprintf 'args:%s\\n' \"$*\" >> \"@D@/refresh.calls\"\ncp \"@S@\" \"@C@\"\n"
                  .replace("@D@", self.dir).replace("@S@", src).replace("@C@", self.cache))
        with open(self.env["CONSO_REFRESH_BIN"], "w") as f:
            f.write(script)
        os.chmod(self.env["CONSO_REFRESH_BIN"], 0o755)

    def refresh_calls(self):
        p = os.path.join(self.dir, "refresh.calls")
        return open(p).read().splitlines() if os.path.exists(p) else []

    def run(self, *args):
        t = time.time()
        r = subprocess.run([sys.executable, os.path.join(HERE, "conso-report.py")] + list(args),
                           env=self.env, capture_output=True, text=True)
        r.elapsed = time.time() - t
        return r


class BilledDeltas(unittest.TestCase):
    def test_deltas_attributed_to_later_snapshot_day(self):
        s = [snap("2026-11-11T10:00:00Z", 1000), snap("2026-11-12T10:00:00Z", 1250), snap("2026-11-12T20:00:00Z", 1300)]
        self.assertEqual({k: round(v, 2) for k, v in cr.billed_per_day(s).items()}, {"2026-11-12": 3.0})

    def test_month_rollover_counts_new_value_in_full(self):
        s = [snap("2026-11-30T22:00:00Z", 5000), snap("2026-12-01T08:00:00Z", 120)]
        self.assertEqual(round(cr.billed_per_day(s)["2026-12-01"], 2), 1.2)

    def test_fewer_than_two_snapshots(self):
        self.assertEqual(cr.billed_per_day([]), {})
        self.assertEqual(cr.billed_per_day([snap("2026-11-12T10:00:00Z", 1000)]), {})
        b = cr.billed_summary([snap("2026-11-13T10:00:00Z", 1240)], TODAY)
        self.assertFalse(b["enough"])
        self.assertEqual(b["month_to_date"], 12.4)
        self.assertNotIn("last7", b)

    def test_decimal_places_respected(self):
        s = [snap("2026-11-12T10:00:00Z", 10, dp=0), snap("2026-11-13T10:00:00Z", 15, dp=0)]
        self.assertEqual(cr.billed_per_day(s)["2026-11-13"], 5.0)

    def test_torn_line_is_skipped(self):
        e = Env(snaps=[snap("2026-11-12T10:00:00Z", 100)])
        with open(e.store, "a") as f:
            f.write('{"ts": "2026-11-13T1\n' + json.dumps(snap("2026-11-13T10:00:00Z", 400)) + "\n")
        self.assertEqual(len(cr.load_snapshots(e.store)), 2)

    def test_summary_window_trend_and_previous_week(self):
        # snapshots every day for 15 days: +1.00 EUR/day in the previous week, +2.00 EUR/day in the last 7 days
        s, used = [], 0
        for i in range(14, -1, -1):
            d = TODAY - timedelta(days=i)
            used += 0 if i == 14 else (200 if i <= 6 else 100)
            s.append(snap(d.isoformat() + "T12:00:00Z", used))
        b = cr.billed_summary(s, TODAY)
        self.assertEqual(round(b["last7"], 2), 14.0)
        self.assertEqual(round(b["prev7"], 2), 7.0)
        self.assertEqual(round(b["change_pct"]), 100)
        self.assertTrue(b["last7_complete"])
        self.assertEqual(list(b["per_day"])[-1], "2026-11-13")
        self.assertEqual(len(b["sparkline"]), 7)

    def test_previous_week_unknown_when_history_short(self):
        s = [snap("2026-11-10T10:00:00Z", 100), snap("2026-11-13T10:00:00Z", 400)]
        b = cr.billed_summary(s, TODAY)
        self.assertIsNone(b["prev7"])
        self.assertFalse(b["last7_complete"])
        self.assertIn("·", b["sparkline"])  # days before the first snapshot are unknown, not zero
        self.assertEqual(round(b["last7"], 2), 3.0)

    def test_month_to_date_unknown_after_month_change_without_snapshot(self):
        b = cr.billed_summary([snap("2026-10-30T10:00:00Z", 100), snap("2026-10-31T10:00:00Z", 200)], TODAY)
        self.assertIsNone(b["month_to_date"])

    def test_sparkline_scale(self):
        self.assertEqual(cr.sparkline([0, 0]), "▁▁")
        self.assertEqual(cr.sparkline([0, 4, None, 8]), "▁▅·█")


class Window(unittest.TestCase):
    def test_default_window_is_today_plus_six_previous_days(self):
        rep = cr.build(make_cache(), [], "2026-11-07", "2026-11-13", "day", TODAY)
        self.assertEqual([r["period"] for r in rep["rows"]], cr.day_list(TODAY, 7))
        self.assertEqual(rep["rows"][0]["period"], "2026-11-07")
        self.assertEqual(rep["rows"][-1]["period"], "2026-11-13")

    def test_cli_default_is_seven_days(self):
        e = Env(cache=make_cache())
        out = json.loads(e.run("-j", "-n").stdout)
        self.assertEqual((out["since"], out["until"], len(out["rows"])), ("2026-11-07", "2026-11-13", 7))

    def test_d_and_range_and_granularities(self):
        e = Env(cache=make_cache())
        self.assertEqual(len(json.loads(e.run("-j", "-n", "-d", "3").stdout)["rows"]), 3)
        r = json.loads(e.run("-j", "-n", "-s", "2026-11-01", "-u", "2026-11-05").stdout)
        self.assertEqual([x["period"] for x in r["rows"]][0], "2026-11-01")
        self.assertEqual(len(json.loads(e.run("-j", "-n", "-g", "month", "-d", "10").stdout)["rows"]), 1)
        self.assertGreaterEqual(len(json.loads(e.run("-j", "-n", "-g", "week", "-d", "20").stdout)["rows"]), 3)

    def test_idle_days_get_a_zero_row(self):
        c = make_cache()
        del c["days"]["2026-11-11"]
        rep = cr.build(c, [], "2026-11-07", "2026-11-13", "day", TODAY)
        self.assertEqual(len(rep["rows"]), 7)
        self.assertEqual(rep["rows"][4]["cost"], 0.0)

    def test_model_breakdown_and_totals(self):
        rep = cr.build(make_cache(), [], "2026-11-12", "2026-11-13", "day", TODAY)
        self.assertEqual(rep["total"]["cost"], 10.0 + 11.0)
        self.assertEqual(rep["total"]["byModel"]["sonnet-5"], 4.0)


class Freshness(unittest.TestCase):
    def test_fresh_cache_reads_instantly_without_notice(self):
        e = Env(cache=make_cache("2026-11-13T11:55:00Z"), snaps=[])
        r = e.run()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("cache is", r.stdout.split("\n")[0])
        self.assertIn("cache 5m old", r.stdout)
        self.assertEqual(e.refresh_calls(), [])
        self.assertLess(r.elapsed, 1.0)

    def test_stale_cache_prints_one_line_notice_and_does_not_refresh(self):
        e = Env(cache=make_cache("2026-11-13T09:00:00Z"), snaps=[])
        r = e.run()
        self.assertEqual(r.returncode, 0)
        first = r.stdout.split("\n")[0]
        self.assertTrue(first.startswith("! cache is 3h00m old"), first)
        self.assertIn("conso --refresh", first)
        self.assertEqual(e.refresh_calls(), [])

    def test_threshold_follows_timer_interval_file_and_env(self):
        e = Env(cache=make_cache("2026-11-13T11:30:00Z"), snaps=[])  # 30 min old
        os.makedirs(e.env["CONSO_DIR"])
        open(os.path.join(e.env["CONSO_DIR"], "interval"), "w").write("600\n")   # 3 x 10 min = 30 min
        self.assertNotIn("! cache is", e.run().stdout)  # exactly at threshold: not stale
        e.env["CONSO_NOW"] = "2026-11-13T12:01:00Z"
        self.assertIn("! cache is", e.run().stdout)
        e.env["CONSO_STALE_AFTER"] = "2h"
        self.assertNotIn("! cache is", e.run().stdout)

    def test_missing_cache_runs_one_refresh(self):
        e = Env(snaps=[])
        e.stub_refresh(make_cache())
        r = e.run()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(e.refresh_calls()), 1)
        self.assertIn("building it once", r.stderr)
        self.assertIn("TOTAL", r.stdout)

    def test_missing_cache_offline_does_not_refresh(self):
        e = Env()
        e.stub_refresh(make_cache())
        os.remove(e.cache) if os.path.exists(e.cache) else None
        r = e.run("-n")
        self.assertEqual(r.returncode, 1)
        self.assertIn("missing", r.stderr)
        self.assertEqual(e.refresh_calls(), [])

    def test_malformed_json_is_treated_as_unreadable(self):
        for raw in ('{"schema": 1, "days": {', "", "[]", '{"schema": 2, "days": {}, "generated_at": "x"}',
                    '{"schema": 1, "days": {}, "generated_at": "not-a-date"}'):
            e = Env(raw_cache=raw)
            r = e.run("-n")
            self.assertEqual(r.returncode, 1, raw)
            self.assertIn("unreadable", r.stderr)
            self.assertNotIn("Traceback", r.stderr)

    def test_malformed_cache_triggers_rebuild_when_online(self):
        e = Env(raw_cache="{oops")
        e.stub_refresh(make_cache())
        r = e.run()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(e.refresh_calls()), 1)

    def test_refresh_flag_forces_refresh_then_reports(self):
        e = Env(cache=make_cache("2026-11-13T11:59:00Z"), snaps=[])
        e.stub_refresh(make_cache())
        r = e.run("--refresh", "-n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(e.refresh_calls(), ["args:-n"])

    def test_S_is_silent_refresh(self):
        e = Env(cache=make_cache(), snaps=[])
        e.stub_refresh(make_cache())
        r = e.run("-S")
        self.assertEqual((r.returncode, r.stdout), (0, ""))
        self.assertEqual(e.refresh_calls(), ["args:-q"])


class Output(unittest.TestCase):
    def test_json_includes_billed_figures_and_estimate_side_by_side(self):
        s, used = [], 0
        for i in range(8, -1, -1):
            used += 0 if i == 8 else 150
            s.append(snap((TODAY - timedelta(days=i)).isoformat() + "T12:00:00Z", used))
        e = Env(cache=make_cache(usage={"ok": True, "limits": [], "extra_usage": {"is_enabled": True}}), snaps=s)
        out = json.loads(e.run("-j").stdout)
        b = out["billed"]
        self.assertEqual((b["currency"], b["enough"], round(b["last7"], 2)), ("EUR", True, 10.5))
        self.assertAlmostEqual(b["month_to_date"], 12.0)
        self.assertEqual(round(out["rows"][-1]["billed"], 2), 1.5)
        self.assertEqual(out["rows"][-1]["cost"], 10.0)  # estimate next to billed on the same row
        self.assertIn("cache_age_seconds", out)

    def test_table_shows_billed_section_with_trend(self):
        s = [snap("2026-11-12T10:00:00Z", 100), snap("2026-11-13T10:00:00Z", 350)]
        e = Env(cache=make_cache(), snaps=s)
        t = e.run().stdout
        self.assertIn("Billed consumption", t)
        self.assertIn("month to date", t)
        self.assertIn("trend", t)
        self.assertIn("billed EUR", t)

    def test_single_snapshot_is_said_plainly(self):
        e = Env(cache=make_cache(), snaps=[snap("2026-11-13T10:00:00Z", 350)])
        t = e.run().stdout
        self.assertIn("only 1 snapshot so far", t)
        self.assertNotIn("billed EUR", t)

    def test_no_snapshot_at_all(self):
        e = Env(cache=make_cache(), snaps=[])
        self.assertIn("no snapshot yet", e.run().stdout)

    def test_plan_limits_from_cache(self):
        u = {"ok": True, "fetched_at": NOW, "extra_usage": None,
             "limits": [{"kind": "five_hour", "percent": 42, "severity": "ok", "resets_at": "2026-11-13T15:00:00Z"}]}
        e = Env(cache=make_cache(usage=u), snaps=[])
        t = e.run().stdout
        self.assertIn("five_hour", t)
        self.assertIn(" 42%", t)

    def test_no_token_like_string_in_output(self):
        e = Env(cache=make_cache(), snaps=[])
        r = e.run("-j")
        self.assertNotIn("sk-ant", r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=1)
