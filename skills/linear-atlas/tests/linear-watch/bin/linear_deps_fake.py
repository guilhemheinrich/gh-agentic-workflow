#!/usr/bin/env python3
"""Fake `linear_deps.py` for the lw graph tests (LW-11).

Takes the arguments lw passes to the real renderer:

    linear_deps_fake.py PROJECT_URL -o SVG --json-out JSON

and writes a tiny SVG and JSON. Controlled by the environment:

  FAKE_DEPS_LOG        file to append one JSON line per call to: argv, cwd and
                       whether LINEAR_API_KEY reached the process. The key
                       value itself is never written.
  FAKE_DEPS_FAIL       "1": write half an SVG to -o, then exit 1 with an error
                       on stderr (a renderer that dies mid-way)
  FAKE_DEPS_LEAK_KEY   "1": echo LINEAR_API_KEY on stderr then fail, to prove
                       lw scrubs it from what it records
  FAKE_DEPS_WAIT_FILE  block until this file exists (at most 20 s), after
                       writing FAKE_DEPS_STARTED
  FAKE_DEPS_STARTED    file created as soon as the call starts
  FAKE_DEPS_DELAY      seconds to sleep before writing the output
"""

import json
import os
import sys
import time
from pathlib import Path


def main() -> int:
    argv = sys.argv[1:]
    log = os.environ.get("FAKE_DEPS_LOG")
    if log:
        with open(log, "a") as fh:
            fh.write(json.dumps({
                "argv": argv,
                "cwd": os.getcwd(),
                "key_received": bool(os.environ.get("LINEAR_API_KEY")),
            }) + "\n")
    started = os.environ.get("FAKE_DEPS_STARTED")
    if started:
        Path(started).write_text("started\n")
    wait_file = os.environ.get("FAKE_DEPS_WAIT_FILE")
    if wait_file:
        deadline = time.monotonic() + 20
        while not Path(wait_file).exists() and time.monotonic() < deadline:
            time.sleep(0.02)
    delay = float(os.environ.get("FAKE_DEPS_DELAY") or 0)
    if delay:
        time.sleep(delay)

    url, svg, out_json = None, None, None
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg == "-o":
            svg = args.pop(0)
        elif arg == "--json-out":
            out_json = args.pop(0)
        elif not arg.startswith("-"):
            url = arg
    if not url or not svg:
        sys.stderr.write("error: fake needs PROJECT_URL and -o\n")
        return 2
    if os.environ.get("FAKE_DEPS_LEAK_KEY") == "1":
        sys.stderr.write(f"error: request failed with key {os.environ.get('LINEAR_API_KEY')}\n")
        return 1
    if os.environ.get("FAKE_DEPS_FAIL") == "1":
        Path(svg).write_text("<svg>half a gra")
        if out_json:
            Path(out_json).write_text('{"nodes": [')
        sys.stderr.write("error: Linear API returned HTTP 500\n")
        return 1
    calls = len(Path(log).read_text().splitlines()) if log else 1
    Path(svg).write_text(f"<svg>fake graph of {url} #{calls}</svg>\n")
    if out_json:
        Path(out_json).write_text(json.dumps({"project": url, "run": calls}) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
