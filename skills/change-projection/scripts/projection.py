#!/usr/bin/env python3
"""Change projection — the spatial view of a change that is about to be written.

A ``tasks.md`` orders work by execution. A human reviewing scope thinks in
space: which parts of the repository does this touch, and how deeply. This
module produces that second projection of the same change, then diffs it
against the real one once the code lands.

Four subcommands:

``scaffold``
    Derive the file set from ``tasks.md``, cross-check it against ``plan.md``,
    and write ``projection.md`` with one empty intent line per file plus an
    objective weight hint. Re-runnable: intents already written are preserved.
``render``
    Rewrite the human-readable tree from the canonical JSON block.
``check``
    Assert the projection is honest — every file it claims is claimed by a
    task, every task path appears, no intent is still a placeholder, and the
    "not touched" section is not empty.
``verify``
    The after-shot. Projected set versus the paths the change actually touched:
    unplanned scope on one side, silently skipped tasks on the other.

The JSON block between the ``DATA`` sentinels is the source of truth. The tree
between the ``RENDER`` sentinels is derived from it and rewritten in place, so
editing the tree by hand is always wasted work.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import textwrap

DATA_START = "<!-- PROJECTION:DATA START -->"
DATA_END = "<!-- PROJECTION:DATA END -->"
RENDER_START = "<!-- PROJECTION:RENDER START -->"
RENDER_END = "<!-- PROJECTION:RENDER END -->"

#: Total render width. Chosen so the tree survives a chat transcript and an
#: 80-column terminal side by side without reflowing mid-intent.
WIDTH = 92

#: Annotation column ceiling. Past this the intent starts on its own line
#: rather than pushing every other line to the right.
MAX_LABEL = 46

#: Weight vocabulary. Plain Unicode on purpose — a Nerd Font icon reaches a
#: chat transcript as a replacement box.
GLYPHS = {"heavy": "★", "added": "+", "touch": "~"}

PLACEHOLDER = "TODO"

#: The fixed strings the renderer owns, per language. The committed artefact is
#: always English; a translation exists only for the tree pasted into a
#: conversation, and never reaches the file.
CHROME = {
    "en": {
        "bookkeeping": "bookkeeping — not part of the change:",
        "not_touched": "deliberately NOT touched:",
        "new": "NEW",
        "empty": "(no logic file projected)",
        "unfilled": f"{PLACEHOLDER} — name what this change leaves alone.",
    },
    "fr": {
        "bookkeeping": "intendance — ne fait pas partie du changement :",
        "not_touched": "délibérément PAS touché :",
        "new": "NOUVEAU",
        "empty": "(aucun fichier de logique projeté)",
        "unfilled": f"{PLACEHOLDER} — nommer ce que ce changement laisse tranquille.",
    },
    "es": {
        "bookkeeping": "administrativo — no forma parte del cambio:",
        "not_touched": "deliberadamente NO tocado:",
        "new": "NUEVO",
        "empty": "(ningún archivo de lógica proyectado)",
        "unfilled": f"{PLACEHOLDER} — nombrar lo que este cambio deja intacto.",
    },
}

#: High-signal markers that an intent was written in the conversation's
#: language instead of English. Deliberately short: every word here is absent
#: from ordinary English prose, so a hit is worth reporting.
FOREIGN_MARKERS = {
    "ajoute", "ajouter", "archivo", "au", "aux", "avec", "cette", "champ",
    "dans", "del", "des", "du", "ecran", "fichier", "la", "las", "le", "les",
    "ligne", "lignes", "los", "nouveau", "nouvelle", "para", "pour", "que",
    "qui", "ses", "sont", "supprime", "une",
}
ACCENTED_RE = re.compile(r"[àâäçéèêëîïôöùûüÿñáíóú]", re.IGNORECASE)
WORD_RE = re.compile(r"[A-Za-zÀ-ÿ]+")

BOOKKEEPING_NAMES = {
    "PROGRESS.md",
    "CHANGELOG.md",
    "devit-log.md",
    "stats.md",
    "tasks.md",
    "checklist.md",
    "review.md",
    "analyze.md",
    "context-keep.md",
    "projection.md",
}
BOOKKEEPING_SUFFIXES = (".lock", ".lock.json", "-lock.json", "-lock.yaml")

TEST_DIR_PARTS = {"tests", "test", "__tests__", "e2e", "cypress"}
TEST_NAME_RE = re.compile(r"(^test_|_test\.|\.test\.|\.spec\.|_spec\.)", re.IGNORECASE)

INLINE_CODE_RE = re.compile(r"`([^`\n]+)`")
TASK_ID_RE = re.compile(r"\bT(\d{3,4})\b")
TREE_CONNECTOR_RE = re.compile(r"(├──|└──|\|--|`--)\s*")
TREE_ROOT_RE = re.compile(r"^([A-Za-z0-9_.@][^\s#`|]*/)\s*(#.*)?$")
BRACE_RE = re.compile(r"\{([^{}/]+)\}")
EXTENSION_RE = re.compile(r"\.[A-Za-z0-9]{1,8}$")
SPEC_DIR_RE = re.compile(r"^specs/[^/]+/")


# --------------------------------------------------------------------------- #
# Path candidates
# --------------------------------------------------------------------------- #


def normalise(token: str) -> str:
    """Strip the decorations a path picks up inside prose."""
    tok = token.strip().strip(",;:")
    tok = tok.lstrip("/")
    while tok.startswith("./"):
        tok = tok[2:]
    return tok


def looks_like_path(tok: str, repo_root: str) -> bool:
    """Decide whether an inline-code token is a repository path.

    Deliberately conservative. A false positive plants a file in the projection
    that no task will ever edit, and ``check`` would then report a divergence
    that does not exist — a fabricated finding is worse than a missed path.
    """
    if not tok or any(c.isspace() for c in tok):
        return False
    if tok.startswith(("-", "$", "#", "@", "http://", "https://", "~")):
        return False
    if any(c in tok for c in "|<>*\"'="):
        return False
    if "/" not in tok:
        return False
    if tok.endswith("/"):
        return True
    if os.path.exists(os.path.join(repo_root, tok)):
        return True
    return bool(EXTENSION_RE.search(tok))


def expand_braces(path: str) -> list[str]:
    """Expand ``{a,b,c}`` groups, as used for locale bundles.

    ``src/i18n/locales/{fr,en,es}/common.json`` stays one line in the
    projection — it carries one intent — but matches three real paths in
    ``verify``.
    """
    match = BRACE_RE.search(path)
    if not match:
        return [path]
    out: list[str] = []
    for alt in match.group(1).split(","):
        tail = path[match.end():]
        out.extend(expand_braces(path[: match.start()] + alt.strip() + tail))
    return out


def classify_role(path: str) -> str:
    """Split logic from tests from bookkeeping.

    Bookkeeping is listed apart so the reader is not counting ``PROGRESS.md``
    as part of the change.
    """
    name = path.rstrip("/").split("/")[-1]
    parts = path.strip("/").split("/")
    if name in BOOKKEEPING_NAMES or path.endswith(BOOKKEEPING_SUFFIXES):
        return "bookkeeping"
    if SPEC_DIR_RE.match(path):
        return "bookkeeping"
    if TEST_NAME_RE.search(name) or TEST_DIR_PARTS & set(parts):
        return "test"
    return "logic"


def suggest_weight(task_count: int) -> str:
    """Weight hint from an objective count, not from a feeling.

    The number of tasks landing in a file is a proxy for how much of the change
    lives there. It is a starting point the author is expected to correct.
    """
    if task_count >= 4:
        return "heavy"
    if task_count >= 2:
        return "added"
    return "touch"


# --------------------------------------------------------------------------- #
# Extraction from the spec artefacts
# --------------------------------------------------------------------------- #


def paths_from_tasks(text: str, repo_root: str) -> dict[str, list[str]]:
    """Map every path a task names to the task ids that name it."""
    found: dict[str, list[str]] = {}
    for line in text.splitlines():
        ids = TASK_ID_RE.findall(line)
        if not ids:
            continue
        task_ids = ["T" + i for i in ids]
        for raw in INLINE_CODE_RE.findall(line):
            tok = normalise(raw)
            if not looks_like_path(tok, repo_root):
                continue
            found.setdefault(tok, [])
            for tid in task_ids:
                if tid not in found[tok]:
                    found[tok].append(tid)
    return found


def paths_from_plan(text: str, repo_root: str) -> tuple[set[str], bool]:
    """Collect the paths ``plan.md`` names, for cross-checking only.

    Two sources: the inline code spans, and the ASCII trees under Project
    Structure. Tree parsing is best-effort by construction — a plan is prose,
    and its tree is drawn for humans. The second return value says whether any
    tree was parsed at all, so a silent parser failure cannot be reported as a
    divergence with the task list.
    """
    out: set[str] = set()
    for raw in INLINE_CODE_RE.findall(text):
        tok = normalise(raw)
        if looks_like_path(tok, repo_root):
            out.add(tok)
    parsed_any = False
    in_fence = False
    base = ""
    stack: dict[int, str] = {}
    for line in text.splitlines():
        if line.strip().startswith("```"):
            in_fence = not in_fence
            base, stack = "", {}
            continue
        if not in_fence:
            continue
        body = line.split("#", 1)[0].rstrip()
        if not body.strip():
            continue
        match = TREE_CONNECTOR_RE.search(body)
        if not match:
            root = TREE_ROOT_RE.match(body.strip())
            if root:
                base, stack = root.group(1), {}
            continue
        parsed_any = True
        depth = len(body[: match.start()]) // 4
        name = body[match.end():].strip().strip("`")
        if not name or any(c.isspace() for c in name):
            continue
        parent = "".join(stack.get(level, "") for level in range(depth))
        full = re.sub(r"/{2,}", "/", base + parent + name)
        if name.endswith("/"):
            stack[depth] = name
            for deeper in [level for level in stack if level > depth]:
                del stack[deeper]
        out.add(full)
    return out, parsed_any


def read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def spec_title(spec_dir: str) -> str:
    """The feature name, taken from the spec rather than from the branch."""
    for name in ("spec.md", "plan.md"):
        candidate = os.path.join(spec_dir, name)
        if not os.path.exists(candidate):
            continue
        for line in read(candidate).splitlines():
            if line.startswith("# "):
                return line[2:].split(":", 1)[-1].strip()
    return os.path.basename(spec_dir.rstrip("/"))


# --------------------------------------------------------------------------- #
# projection.md I/O
# --------------------------------------------------------------------------- #


def split_document(text: str) -> dict:
    """Return the canonical JSON payload of a projection document."""
    try:
        payload = text.split(DATA_START, 1)[1].split(DATA_END, 1)[0]
    except IndexError:
        raise SystemExit(
            "projection.md carries no PROJECTION:DATA block — regenerate it with scaffold"
        )
    payload = payload.strip()
    if payload.startswith("```"):
        payload = payload.split("\n", 1)[1].rsplit("```", 1)[0]
    try:
        return json.loads(payload)
    except json.JSONDecodeError as error:
        raise SystemExit(f"the PROJECTION:DATA block is not valid JSON: {error}")


def load(spec_dir: str) -> dict:
    path = os.path.join(spec_dir, "projection.md")
    if not os.path.exists(path):
        raise SystemExit(f"{path} does not exist — run scaffold --write first")
    return split_document(read(path))


def document(data: dict, rendered: str) -> str:
    """Assemble the file. The tree is always regenerated from the JSON."""
    payload = json.dumps(data, indent=2, ensure_ascii=False)
    return "\n".join(
        [
            f"# Projection — {data.get('title', 'change')}",
            "",
            "The spatial view of this change: where it lands, how deeply, and what it",
            "leaves alone. Derived from `tasks.md`. The JSON block below is the source of",
            "truth; the tree under it is generated — edit the JSON, then re-render.",
            "",
            DATA_START,
            "",
            "```json",
            payload,
            "```",
            "",
            DATA_END,
            "",
            RENDER_START,
            "",
            "```text",
            rendered.rstrip(),
            "```",
            "",
            RENDER_END,
            "",
        ]
    )


# --------------------------------------------------------------------------- #
# Rendering
# --------------------------------------------------------------------------- #


class Branch:
    """A directory or a file in the rendered tree.

    ``is_dir`` is carried explicitly rather than inferred from the children,
    because a projected entry may itself be a directory — ``T047`` editing
    ``skills/grievances/scripts/`` is both an annotated line and a parent of
    two annotated files.
    """

    __slots__ = ("name", "children", "entry", "is_dir")

    def __init__(self, name: str, is_dir: bool = False) -> None:
        self.name = name
        self.children: dict[str, "Branch"] = {}
        self.entry: dict | None = None
        self.is_dir = is_dir


def common_prefix(paths: list[str]) -> str:
    """Deepest directory every path shares. The tree is drawn under it."""
    if not paths:
        return ""
    split = [p.split("/")[:-1] for p in paths]
    shared: list[str] = []
    for parts in zip(*split):
        if len(set(parts)) != 1:
            break
        shared.append(parts[0])
    return "/".join(shared) + "/" if shared else ""


def build_tree(entries: list[dict], root: str) -> Branch:
    tree = Branch(root or "./", is_dir=True)
    for entry in entries:
        rest = entry["path"][len(root):] if root else entry["path"]
        parts = [part for part in rest.split("/") if part]
        if not parts:
            continue
        cursor = tree
        for part in parts[:-1]:
            cursor = cursor.children.setdefault(part, Branch(part, is_dir=True))
            cursor.is_dir = True
        leaf = cursor.children.setdefault(
            parts[-1], Branch(parts[-1], is_dir=entry["path"].endswith("/"))
        )
        leaf.is_dir = leaf.is_dir or entry["path"].endswith("/")
        leaf.entry = entry
    return tree


def collapse(branch: Branch) -> None:
    """Fold every single-child directory chain into one line.

    ``app/`` → ``(public)/`` → ``enroll/`` → ``[token]/`` carries no
    information as four lines. It becomes ``app/(public)/enroll/[token]/``.
    """
    for child in list(branch.children.values()):
        collapse(child)
    if branch.entry is not None:
        return
    while len(branch.children) == 1:
        only, = branch.children.values()
        if not only.is_dir or only.entry is not None:
            break
        # `only.name`, never the dict key: the child was collapsed first, so
        # the key is its original single segment while the name already
        # carries the whole folded chain.
        branch.name = f"{branch.name.rstrip('/')}/{only.name}" if branch.name else only.name
        branch.children = only.children
        branch.is_dir = True


def sorted_children(branch: Branch) -> list[Branch]:
    kids = list(branch.children.values())
    kids.sort(key=lambda child: (not child.is_dir, child.name.lower()))
    return kids


def file_annotation(entry: dict, chrome: dict) -> str:
    glyph = GLYPHS.get(entry.get("weight", "touch"), "~")
    intent = (entry.get("intent") or PLACEHOLDER).strip()
    prefix = f"{chrome['new']} — " if entry.get("new") else ""
    hint = (entry.get("size_hint") or "").strip()
    tail = f" {hint}" if hint and hint not in intent else ""
    return f"{glyph} {prefix}{intent}{tail}"


def collect_lines(branch: Branch, guide: str, dirs: dict[str, str], base: str,
                  records: list[dict], chrome: dict) -> None:
    kids = sorted_children(branch)
    for index, child in enumerate(kids):
        last = index == len(kids) - 1
        connector = "└── " if last else "├── "
        cont = guide + ("    " if last else "│   ")
        name = child.name
        if child.is_dir and not name.endswith("/"):
            name += "/"
        path = base + name
        if child.entry is not None:
            annot = file_annotation(child.entry, chrome)
        elif child.is_dir:
            note = dirs.get(path) or dirs.get(path.rstrip("/"))
            annot = f"← {note}" if note else ""
        else:
            annot = ""
        records.append({"label": guide + connector + name, "cont": cont, "annot": annot})
        if child.children:
            collect_lines(child, cont, dirs, path, records, chrome)


def lay_out(records: list[dict]) -> list[str]:
    """Place every annotation in one column, wrapping under the right guide.

    This is the reason the tree is generated rather than typed: the
    continuation lines of a wrapped intent must carry the vertical bars of the
    branches still open above them, and a human gets that wrong every time.
    """
    if not records:
        return []
    col = max(18, min(MAX_LABEL, max(len(r["label"]) for r in records) + 2))
    out: list[str] = []
    for index, record in enumerate(records):
        label, annot, cont = record["label"], record["annot"], record["cont"]
        if not annot:
            out.append(label.rstrip())
            continue
        wrapped = textwrap.wrap(annot, width=max(28, WIDTH - col)) or [annot]
        if len(label) + 2 > col:
            out.append(label.rstrip())
            rest = wrapped
        else:
            out.append(label.ljust(col) + wrapped[0])
            rest = wrapped[1:]
        pad = cont.ljust(col) if len(cont) < col else cont + " "
        for extra in rest:
            out.append(pad + extra)
        following = records[index + 1] if index + 1 < len(records) else None
        if rest and following:
            # Breathing room after a wrapped intent, drawn at the shallower of
            # the two depths so the bar belongs to a branch still open.
            deeper = len(following["cont"]) >= len(cont)
            separator = (cont if deeper else following["cont"]).rstrip()
            if separator:
                out.append(separator)
    return out


def apply_overlay(data: dict, overlay: dict) -> dict:
    """Substitute translated intents, for one render, without storing them.

    The overlay lives outside the repository — a scratchpad file. The committed
    artefact stays English; only the tree pasted into the conversation speaks
    the caller's language.
    """
    merged = json.loads(json.dumps(data))
    per_file = overlay.get("files", {})
    for entry in merged.get("files", []):
        if entry["path"] in per_file:
            entry["intent"] = per_file[entry["path"]]
            # The translated line carries its own size hint. Keeping the
            # English one appends "~15 lines." under "~15 lignes.".
            entry.pop("size_hint", None)
    per_dir = overlay.get("dirs", {})
    merged["dirs"] = {**merged.get("dirs", {}), **per_dir}
    per_reason = overlay.get("not_touched", {})
    for item in merged.get("not_touched", []):
        if item["path"] in per_reason:
            item["why"] = per_reason[item["path"]]
    return merged


def render(data: dict, lang: str = "en", overlay: dict | None = None) -> str:
    """Produce the whole plain-text projection: tree, bookkeeping, not touched.

    No ANSI, no OSC 8 hyperlink, no icon font. Each of those is a terminal
    feature that reaches a chat transcript as literal garbage.
    """
    chrome = CHROME.get(lang, CHROME["en"])
    if overlay:
        data = apply_overlay(data, overlay)
    files = data.get("files", [])
    logic = [f for f in files if f.get("role", "logic") in ("logic", "test")]
    books = [f for f in files if f.get("role") == "bookkeeping"]
    paths = sorted(f["path"] for f in logic)
    blocks: list[str] = []
    if paths:
        root = common_prefix(paths)
        tree = build_tree(sorted(logic, key=lambda f: f["path"]), root)
        collapse(tree)
        records: list[dict] = []
        collect_lines(tree, "", data.get("dirs", {}), root, records, chrome)
        # A projected directory can be the common prefix itself — a task
        # editing `skills/g/scripts/` beside the files under it. Its intent
        # belongs on the root line, which build_tree cannot carry.
        root_entry = next((f for f in logic if f["path"] == root), None)
        if root_entry:
            note = file_annotation(root_entry, chrome)
        else:
            note = data.get("dirs", {}).get(root, "")
            note = f"← {note}" if note else ""
        header = (root or "./") + (f"    {note}" if note else "")
        blocks.append("\n".join([header, "│"] + lay_out(records)))
    else:
        blocks.append(chrome["empty"])
    if books:
        lines = [chrome["bookkeeping"]]
        for entry in sorted(books, key=lambda f: f["path"]):
            note = (entry.get("intent") or "").strip()
            lines.append(f"  {entry['path']}" + (f" — {note}" if note else ""))
        blocks.append("\n".join(lines))
    lines = [chrome["not_touched"]]
    not_touched = data.get("not_touched", [])
    if not_touched:
        for item in not_touched:
            why = (item.get("why") or "").strip()
            lines.append(f"  {item['path']}" + (f" — {why}" if why else ""))
    else:
        lines.append(f"  {chrome['unfilled']}")
    blocks.append("\n".join(lines))
    return "\n\n".join(blocks) + "\n"


# --------------------------------------------------------------------------- #
# Subcommands
# --------------------------------------------------------------------------- #


def cmd_scaffold(args: argparse.Namespace) -> int:
    """Derive the projection skeleton from the task list.

    The file set comes from ``tasks.md`` alone, never from ``plan.md``: a
    projection may not claim a file no task edits. ``plan.md`` is read only to
    report what it names and no task carries out.
    """
    spec_dir = args.spec.rstrip("/")
    tasks_path = os.path.join(spec_dir, "tasks.md")
    if not os.path.exists(tasks_path):
        raise SystemExit(f"{tasks_path} not found — a projection is derived, never invented")
    task_paths = paths_from_tasks(read(tasks_path), args.repo_root)

    previous: dict[str, dict] = {}
    data: dict = {}
    out_path = os.path.join(spec_dir, "projection.md")
    if os.path.exists(out_path):
        data = split_document(read(out_path))
        previous = {f["path"]: f for f in data.get("files", [])}

    files: list[dict] = []
    for path in sorted(task_paths):
        old = previous.get(path, {})
        entry = {
            "path": path,
            "role": old.get("role") or classify_role(path),
            "weight": old.get("weight") or suggest_weight(len(task_paths[path])),
            "new": not os.path.exists(os.path.join(args.repo_root, path)),
            "tasks": task_paths[path],
            "intent": old.get("intent", ""),
        }
        if old.get("size_hint"):
            entry["size_hint"] = old["size_hint"]
        files.append(entry)

    data.update(
        {
            "spec": spec_dir,
            "title": data.get("title") or spec_title(spec_dir),
            "dirs": data.get("dirs", {}),
            "files": files,
            "not_touched": data.get("not_touched", []),
        }
    )
    rendered = render(data)
    text = document(data, rendered)
    if args.write:
        with open(out_path, "w", encoding="utf-8") as handle:
            handle.write(text)
        print(f"wrote {out_path} — {len(files)} file(s) projected", file=sys.stderr)
    else:
        sys.stdout.write(text)

    dropped = sorted(set(previous) - set(task_paths))
    for path in dropped:
        print(f"scope shrank: {path} is no longer edited by any task", file=sys.stderr)
    if os.path.exists(os.path.join(spec_dir, "plan.md")):
        plan_paths, parsed = paths_from_plan(read(os.path.join(spec_dir, "plan.md")),
                                             args.repo_root)
        orphans = sorted(p for p in plan_paths - set(task_paths)
                         if classify_role(p) != "bookkeeping" and not p.endswith("/"))
        if not parsed:
            print("note: no ASCII tree parsed in plan.md — cross-check is code-spans only",
                  file=sys.stderr)
        for path in orphans:
            print(f"divergence: plan.md names {path}, no task edits it", file=sys.stderr)
    return 0


def cmd_render(args: argparse.Namespace) -> int:
    """Regenerate the tree from the JSON block.

    Two destinations, two languages. ``--write`` rewrites the committed
    artefact, which is English by definition. Without it the tree goes to
    stdout for the conversation, where ``--lang`` and ``--overlay`` put it in
    the caller's language. The two are mutually exclusive on purpose: a
    translated tree must never reach the file.
    """
    spec_dir = args.spec.rstrip("/")
    data = load(spec_dir)
    translated = args.lang != "en" or bool(args.overlay)
    if args.write and translated:
        raise SystemExit(
            "refusing to write a translated tree: the committed artefact is English. "
            "Drop --write to render for the conversation, or drop --lang/--overlay."
        )
    if args.lang not in CHROME:
        print(f"note: no chrome for --lang {args.lang}, falling back to English",
              file=sys.stderr)
    overlay = json.loads(read(args.overlay)) if args.overlay else None
    if args.write:
        with open(os.path.join(spec_dir, "projection.md"), "w", encoding="utf-8") as handle:
            handle.write(document(data, render(data)))
        print(f"re-rendered {spec_dir}/projection.md", file=sys.stderr)
    else:
        sys.stdout.write(render(data, lang=args.lang, overlay=overlay))
    return 0


def foreign_words(text: str) -> list[str]:
    """Markers that a line was written in the conversation's language.

    The committed artefact is English. The realistic failure is an agent
    chatting in French and writing the intents the same way, so this probe
    exists to catch it before the file is committed.
    """
    hits = [word for word in WORD_RE.findall(text) if word.lower() in FOREIGN_MARKERS]
    if ACCENTED_RE.search(text):
        hits.append(ACCENTED_RE.search(text).group(0))
    return sorted(set(hits))


def cmd_check(args: argparse.Namespace) -> int:
    """Assert the projection cannot lie about the task list.

    A divergence between ``tasks.md`` and the projection is itself the finding
    this command exists to surface. Passing this command is the commit gate:
    the artefact reaches a commit once, in its final state, and never as a
    scaffold full of ``TODO``.
    """
    spec_dir = args.spec.rstrip("/")
    data = load(spec_dir)
    task_paths = paths_from_tasks(read(os.path.join(spec_dir, "tasks.md")), args.repo_root)
    projected = {f["path"]: f for f in data.get("files", [])}
    findings: list[str] = []
    for path in sorted(set(projected) - set(task_paths)):
        findings.append(f"claimed but unclaimed: {path} — no task edits it")
    for path in sorted(set(task_paths) - set(projected)):
        findings.append(f"omitted: {path} — task(s) {', '.join(task_paths[path])} edit it")
    for path, entry in sorted(projected.items()):
        if entry.get("role") == "bookkeeping":
            continue
        intent = (entry.get("intent") or "").strip()
        if not intent or intent.startswith(PLACEHOLDER):
            findings.append(f"no intent: {path} — one line, in domain words")
            continue
        markers = [] if args.skip_language else foreign_words(intent)
        if markers:
            findings.append(
                f"not English: {path} — {', '.join(markers)}. "
                "The committed artefact is English; translate at render time."
            )
    for item in data.get("not_touched", []):
        markers = [] if args.skip_language else foreign_words(item.get("why") or "")
        if markers:
            findings.append(f"not English: not_touched {item['path']} — {', '.join(markers)}")
    if not data.get("not_touched"):
        findings.append("no 'not touched' section — non-negotiable, it carries the reassurance")
    if args.json:
        print(json.dumps({"findings": findings}, indent=2, ensure_ascii=False))
    else:
        for finding in findings:
            print(finding)
        if not findings:
            print(f"projection honest: {len(projected)} file(s), all claimed by a task")
    return 1 if findings else 0


def changed_paths(args: argparse.Namespace) -> list[str]:
    """The paths the change actually touched.

    ``--changed-from`` is the canonical route: this script runs inside a
    Python image that carries no git, so the caller pipes ``git diff
    --name-only`` in. The subprocess fallback exists for the rare host where
    both are available.
    """
    if args.changed_from:
        text = sys.stdin.read() if args.changed_from == "-" else read(args.changed_from)
        return [normalise(line) for line in text.splitlines() if line.strip()]
    command = ["git", "-C", args.repo_root, "diff", "--name-only"]
    command += [args.range] if args.range else []
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"cannot read the change set: {error}. Use --changed-from -")
    return [line for line in result.stdout.splitlines() if line.strip()]


def cmd_verify(args: argparse.Namespace) -> int:
    """The after-shot: projection versus reality.

    Files touched but not projected are unplanned scope. Files projected but
    untouched are tasks silently skipped. Both are drift, and both cost about
    one ``git diff --name-only`` to detect.
    """
    spec_dir = args.spec.rstrip("/")
    data = load(spec_dir)
    actual = set(changed_paths(args))
    projected_dirs: set[str] = set()
    projected_files: dict[str, str] = {}
    for entry in data.get("files", []):
        for path in expand_braces(entry["path"]):
            if path.endswith("/"):
                projected_dirs.add(path)
            else:
                projected_files[path] = entry["path"]

    def is_projected(path: str) -> bool:
        return path in projected_files or any(path.startswith(d) for d in projected_dirs)

    ignored = [f"{spec_dir}/*"] + list(args.ignore or [])
    unplanned = sorted(
        path
        for path in actual
        if not is_projected(path)
        and not any(fnmatch.fnmatch(path, pattern) for pattern in ignored)
    )
    skipped = sorted(
        {
            source
            for path, source in projected_files.items()
            if path not in actual
        }
    )
    touched_dirs = sorted(d for d in projected_dirs if any(p.startswith(d) for p in actual))
    skipped += sorted(d for d in projected_dirs if d not in touched_dirs)
    report = {
        "spec": spec_dir,
        "actual": len(actual),
        "unplanned": unplanned,
        "skipped": sorted(set(skipped)),
        "ignored_globs": ignored,
    }
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(f"after-shot — {spec_dir}: {len(actual)} path(s) changed")
        for path in unplanned:
            print(f"  unplanned scope: {path} — touched, never projected")
        for path in report["skipped"]:
            print(f"  skipped: {path} — projected, never touched")
        if not unplanned and not report["skipped"]:
            print("  no drift: the change landed exactly where the projection said")
    return 1 if unplanned or report["skipped"] else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="projection.py", description=__doc__.splitlines()[0]
    )
    parser.add_argument("--repo-root", default=".", help="repository root (default: .)")
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add(name: str, handler, help_text: str) -> argparse.ArgumentParser:
        sub = subparsers.add_parser(name, help=help_text)
        sub.add_argument("--spec", required=True, help="spec directory, e.g. specs/071-siren")
        sub.set_defaults(handler=handler)
        return sub

    scaffold = add("scaffold", cmd_scaffold, "derive the skeleton from tasks.md")
    scaffold.add_argument("--write", action="store_true", help="write projection.md in place")

    renderer = add("render", cmd_render, "regenerate the tree from the JSON block")
    renderer.add_argument("--write", action="store_true",
                          help="write projection.md in place (English only)")
    renderer.add_argument("--lang", default="en", metavar="CODE",
                          help=f"language of the rendered chrome: {', '.join(CHROME)}")
    renderer.add_argument("--overlay", metavar="FILE",
                          help="JSON of translated intents, applied to this render only")

    checker = add("check", cmd_check, "assert the projection matches tasks.md")
    checker.add_argument("--json", action="store_true", help="machine-readable findings")
    checker.add_argument("--skip-language", action="store_true",
                         help="do not probe the intents for non-English prose")

    verifier = add("verify", cmd_verify, "diff the projection against the real change")
    verifier.add_argument("--changed-from", metavar="FILE",
                          help="read changed paths from FILE, or - for stdin")
    verifier.add_argument("--range", help="git range, used only without --changed-from")
    verifier.add_argument("--ignore", action="append", metavar="GLOB",
                          help="path glob excluded from unplanned scope (repeatable)")
    verifier.add_argument("--json", action="store_true", help="machine-readable report")

    args = parser.parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main())
