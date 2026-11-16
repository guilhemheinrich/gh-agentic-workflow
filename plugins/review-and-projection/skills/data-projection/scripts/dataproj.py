#!/usr/bin/env python3
"""Data projection — what a change does to a relational database.

Two questions, two artefacts, one engine:

``schema``
    Which tables the change touches and what moves structurally. Writes
    ``specs/NNN-*/schema-projection.md``.
``effects``
    What one use case does to the data — which rows match, which values are
    written, what refuses to write. Writes
    ``specs/NNN-*/effect-projection.md``.

Both are declared as a typed JSON block with closed operation vocabularies, and
rendered by this script. The topology of a report — section order, columns,
glyphs, step numbering, tallies — lives in code, so it cannot drift between two
models or two moods. Prose lives in exactly one place per line: the intent
column on the right.

``data-model.md`` is deliberately not parsed. A survey of the fleet found no
two specs sharing a heading scheme or a column table, so a parser over that
prose would invent findings. The anchors are elsewhere and they are real: task
ids must exist in ``tasks.md``, migration files must contain the DDL the schema
view declares, and every effect must cite the test that proves it.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import textwrap

DATA_START = "<!-- DATA-PROJECTION:DATA START -->"
DATA_END = "<!-- DATA-PROJECTION:DATA END -->"
RENDER_START = "<!-- DATA-PROJECTION:RENDER START -->"
RENDER_END = "<!-- DATA-PROJECTION:RENDER END -->"

WIDTH = 96

#: Ceiling for the shared intent column. A row wider than this keeps its prose
#: on the next line instead of shifting the whole report right.
MAX_INTENT_AT = 62

PLACEHOLDER = "TODO"

# --------------------------------------------------------------------------- #
# Closed vocabularies. An operation outside these sets is a validation error,
# never a line rendered on trust.
# --------------------------------------------------------------------------- #

TABLE_OPS = {"create-table", "drop-table", "rename-table", "alter-table", "referenced"}

OBJECT_OPS = {
    "add-column", "drop-column", "alter-type", "set-not-null", "drop-not-null",
    "set-default", "drop-default", "rename-column", "backfill",
    "add-index", "drop-index", "add-fk", "drop-fk", "add-check", "drop-check",
    "add-unique", "drop-unique", "add-trigger", "drop-trigger",
}

EFFECT_OPS = {"insert", "update", "upsert", "delete", "soft-delete", "read", "no-op"}

#: Cardinality of the row set an effect reaches.
ROW_COUNTS = {"one", "zero-or-one", "many", "one-per-input"}

#: How a field value arrives. The arrow is derived from this, never authored.
FIELD_KINDS = {"value": "→", "from-step": "←", "literal": "="}

WEIGHTS = {"heavy", "added", "touch"}

#: Ops that write rows, and the SQL keyword each contributes to the net-effect
#: tally. SQL keywords need neither translation nor pluralisation, which is why
#: the tally speaks SQL instead of prose.
WRITING_OPS = {
    "insert": "INSERT",
    "update": "UPDATE",
    "upsert": "UPSERT",
    "delete": "DELETE",
    "soft-delete": "SOFT-DELETE",
}


def glyph(op: str) -> str:
    """One glyph per operation class, derived from the op itself.

    The author picks the operation; the renderer picks the glyph. Nothing about
    a report's shape is left to taste.
    """
    if op.startswith(("add-", "create-")):
        return "+"
    if op.startswith("drop-"):
        return "-"
    return "~"


# --------------------------------------------------------------------------- #
# Chrome. The committed artefact is English; a translation exists only for the
# report pasted into a conversation, and never reaches the file.
# --------------------------------------------------------------------------- #

CHROME = {
    "en": {
        "migration": "migration", "reversible": "reversible", "tally": "tally",
        "not_touched": "deliberately NOT touched:", "yes": "yes", "no": "no",
        "tables": "tables", "objects": "objects", "created": "created",
        "dropped_t": "dropped", "added": "added", "altered": "altered",
        "dropped": "dropped", "unknown": "unknown",
        "use_case": "use case", "guard": "guard", "net_effect": "net effect",
        "rows": "rows", "where": "where", "step": "step",
        "rowcount": {"one": "one", "zero-or-one": "zero or one", "many": "many",
                     "one-per-input": "one per input"},
        "empty_schema": "(no table projected)",
        "empty_effects": "(no use case projected)",
        "unfilled": f"{PLACEHOLDER} — name what this change leaves alone.",
        "no_guard": f"{PLACEHOLDER} — state what refuses to write.",
    },
    "fr": {
        "migration": "migration", "reversible": "réversible", "tally": "décompte",
        "not_touched": "délibérément PAS touché :", "yes": "oui", "no": "non",
        "tables": "tables", "objects": "objets", "created": "créées",
        "dropped_t": "supprimées", "added": "ajoutés", "altered": "altérés",
        "dropped": "supprimés", "unknown": "inconnu",
        "use_case": "cas d'usage", "guard": "garde", "net_effect": "effet net",
        "rows": "lignes", "where": "où", "step": "étape",
        "rowcount": {"one": "une", "zero-or-one": "zéro ou une", "many": "plusieurs",
                     "one-per-input": "une par entrée"},
        "empty_schema": "(aucune table projetée)",
        "empty_effects": "(aucun cas d'usage projeté)",
        "unfilled": f"{PLACEHOLDER} — nommer ce que ce changement laisse tranquille.",
        "no_guard": f"{PLACEHOLDER} — énoncer ce qui refuse d'écrire.",
    },
    "es": {
        "migration": "migración", "reversible": "reversible", "tally": "recuento",
        "not_touched": "deliberadamente NO tocado:", "yes": "sí", "no": "no",
        "tables": "tablas", "objects": "objetos", "created": "creadas",
        "dropped_t": "eliminadas", "added": "añadidos", "altered": "alterados",
        "dropped": "eliminados", "unknown": "desconocido",
        "use_case": "caso de uso", "guard": "guarda", "net_effect": "efecto neto",
        "rows": "filas", "where": "donde", "step": "paso",
        "rowcount": {"one": "una", "zero-or-one": "cero o una", "many": "varias",
                     "one-per-input": "una por entrada"},
        "empty_schema": "(ninguna tabla proyectada)",
        "empty_effects": "(ningún caso de uso proyectado)",
        "unfilled": f"{PLACEHOLDER} — nombrar lo que este cambio deja intacto.",
        "no_guard": f"{PLACEHOLDER} — indicar qué se niega a escribir.",
    },
}

#: High-signal markers that prose was written in the conversation's language
#: instead of English. Same probe as the change-projection skill.
FOREIGN_MARKERS = {
    "ajoute", "ajouter", "archivo", "au", "aux", "avec", "cette", "champ",
    "dans", "del", "des", "du", "ecran", "fichier", "la", "las", "le", "les",
    "ligne", "lignes", "los", "nouveau", "nouvelle", "para", "pour", "que",
    "qui", "ses", "sont", "supprime", "une",
}
ACCENTED_RE = re.compile(r"[àâäçéèêëîïôöùûüÿñáíóú]", re.IGNORECASE)
WORD_RE = re.compile(r"[A-Za-zÀ-ÿ]+")

TASK_ID_RE = re.compile(r"\bT(\d{3,4})\b")


# --------------------------------------------------------------------------- #
# Small shared helpers
# --------------------------------------------------------------------------- #


def read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def foreign_words(text: str) -> list[str]:
    """Markers that a line was written in the caller's language."""
    hits = [word for word in WORD_RE.findall(text or "") if word.lower() in FOREIGN_MARKERS]
    accent = ACCENTED_RE.search(text or "")
    if accent:
        hits.append(accent.group(0))
    return sorted(set(hits))


def task_range(tasks: list[str]) -> str:
    """Render a task list as a range when it is contiguous, else as a list."""
    if not tasks:
        return ""
    numbers = sorted(int(t[1:]) for t in tasks if TASK_ID_RE.fullmatch(t))
    if len(numbers) > 2 and numbers == list(range(numbers[0], numbers[-1] + 1)):
        return f"T{numbers[0]:03d}-T{numbers[-1]:03d}"
    return ", ".join(sorted(tasks))


def bare_table(name: str) -> str:
    """Drop the schema prefix and the quoting, for SQL matching."""
    return name.replace('"', "").replace("`", "").split(".")[-1].strip().lower()


def column(rows: list[list[str]], gutter: int = 2) -> list[str]:
    """Left-align a fixed grid. Only the last cell carries prose.

    Rows are padded to a common length first: a grid built from heterogeneous
    effects (an insert has no `before` value) must still align.
    """
    if not rows:
        return []
    span = max(len(row) for row in rows)
    padded = [list(row) + [""] * (span - len(row)) for row in rows]
    widths = [max(len(row[i]) for row in padded) for i in range(span - 1)]
    out: list[str] = []
    for row in padded:
        head = "".join(cell.ljust(widths[i] + gutter) for i, cell in enumerate(row[:-1]))
        out.append((head + row[-1]).rstrip())
    return out


def emit_row(head: str, guide: str, text: str, intent_at: int) -> list[str]:
    """Place one grid row and its prose in the shared intent column.

    A row wider than the column keeps its prose on the next line rather than
    pushing every other row to the right — a long translated value must not
    reshape the whole report.
    """
    if not text:
        return [head.rstrip()]
    if len(head) + 2 > intent_at:
        pad = guide.ljust(intent_at) if len(guide) < intent_at else guide + " "
        room = max(28, WIDTH - intent_at)
        return [head.rstrip()] + [pad + piece
                                  for piece in textwrap.wrap(text, width=room) or [text]]
    return wrap_into(head.ljust(intent_at), guide, text)


def wrap_into(prefix: str, guide: str, text: str) -> list[str]:
    """Emit `prefix + text`, wrapping continuations under the intent column.

    The guide is what a continuation line carries in the prefix's place — the
    open branch bar, or spaces. Getting this wrong is the one thing a human
    never gets right by hand.
    """
    if not text:
        return [prefix.rstrip()]
    room = max(28, WIDTH - len(prefix))
    pieces = textwrap.wrap(text, width=room) or [text]
    lines = [prefix + pieces[0]]
    pad = guide.ljust(len(prefix)) if len(guide) < len(prefix) else guide + " "
    lines.extend(pad + piece for piece in pieces[1:])
    return lines


# --------------------------------------------------------------------------- #
# Artefact I/O
# --------------------------------------------------------------------------- #

VIEWS = {
    "schema": ("schema-projection.md", "Schema projection"),
    "effects": ("effect-projection.md", "Effect projection"),
}


def artefact_path(spec_dir: str, view: str) -> str:
    return os.path.join(spec_dir.rstrip("/"), VIEWS[view][0])


def split_document(text: str) -> dict:
    try:
        payload = text.split(DATA_START, 1)[1].split(DATA_END, 1)[0]
    except IndexError:
        raise SystemExit("no DATA-PROJECTION:DATA block — regenerate it with init")
    payload = payload.strip()
    if payload.startswith("```"):
        payload = payload.split("\n", 1)[1].rsplit("```", 1)[0]
    try:
        return json.loads(payload)
    except json.JSONDecodeError as error:
        raise SystemExit(f"the DATA-PROJECTION:DATA block is not valid JSON: {error}")


def load(spec_dir: str, view: str) -> dict:
    path = artefact_path(spec_dir, view)
    if not os.path.exists(path):
        raise SystemExit(f"{path} does not exist — run `{view} init --write` first")
    return split_document(read(path))


def document(data: dict, view: str, rendered: str) -> str:
    headline = VIEWS[view][1]
    payload = json.dumps(data, indent=2, ensure_ascii=False)
    return "\n".join(
        [
            f"# {headline} — {data.get('title', 'change')}",
            "",
            "Declared as the JSON block below, rendered by",
            "`skills/data-projection/scripts/dataproj.py`. The JSON is the source of truth;",
            "the report under it is generated — edit the JSON, then re-render.",
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
# Validation of the closed vocabularies
# --------------------------------------------------------------------------- #


def validate_schema(data: dict) -> list[str]:
    """Reject anything outside the vocabulary, before it reaches a renderer."""
    errors: list[str] = []
    for table in data.get("tables", []):
        name = table.get("name", "?")
        if table.get("op") not in TABLE_OPS:
            errors.append(f"{name}: table op {table.get('op')!r} outside "
                          f"{sorted(TABLE_OPS)}")
        if table.get("weight", "touch") not in WEIGHTS:
            errors.append(f"{name}: weight {table.get('weight')!r} outside {sorted(WEIGHTS)}")
        for obj in table.get("objects", []):
            if obj.get("op") not in OBJECT_OPS:
                errors.append(f"{name}.{obj.get('name', '?')}: object op "
                              f"{obj.get('op')!r} outside the vocabulary")
    return errors


def validate_effects(data: dict) -> list[str]:
    errors: list[str] = []
    seen: set[str] = set()
    for case in data.get("use_cases", []):
        name = case.get("name", "?")
        if name in seen:
            errors.append(f"{name}: duplicate use-case name — names address the overlay")
        seen.add(name)
        for index, effect in enumerate(case.get("effects", []), start=1):
            where = f"{name} step {index}"
            if effect.get("op") not in EFFECT_OPS:
                errors.append(f"{where}: op {effect.get('op')!r} outside {sorted(EFFECT_OPS)}")
            if effect.get("rows") not in ROW_COUNTS:
                errors.append(f"{where}: rows {effect.get('rows')!r} outside "
                              f"{sorted(ROW_COUNTS)}")
            for field in effect.get("fields", []):
                kind = field.get("kind", "value")
                if kind not in FIELD_KINDS:
                    errors.append(f"{where}: field {field.get('name', '?')} kind "
                                  f"{kind!r} outside {sorted(FIELD_KINDS)}")
                elif kind == "from-step" and not str(field.get("after", "")).isdigit():
                    # A structural slot holds a step number, never prose. The
                    # explanation belongs in `intent`, which is translatable.
                    errors.append(f"{where}: field {field['name']} is from-step, so "
                                  f"`after` must be the step number, not "
                                  f"{field.get('after')!r}")
    return errors


# --------------------------------------------------------------------------- #
# Overlays — translated prose, applied to one render, never stored
# --------------------------------------------------------------------------- #


def overlay_schema(data: dict, overlay: dict) -> dict:
    merged = json.loads(json.dumps(data))
    tables = overlay.get("tables", {})
    for table in merged.get("tables", []):
        patch = tables.get(table["name"], {})
        if "intent" in patch:
            table["intent"] = patch["intent"]
        objects = patch.get("objects", {})
        for obj in table.get("objects", []):
            if obj["name"] in objects:
                obj["intent"] = objects[obj["name"]]
    reasons = overlay.get("not_touched", {})
    for item in merged.get("not_touched", []):
        if item["name"] in reasons:
            item["why"] = reasons[item["name"]]
    notes = overlay.get("migrations", {})
    for migration in merged.get("migrations", []):
        if migration["path"] in notes:
            migration["note"] = notes[migration["path"]]
    return merged


def overlay_effects(data: dict, overlay: dict) -> dict:
    merged = json.loads(json.dumps(data))
    cases = overlay.get("use_cases", {})
    for case in merged.get("use_cases", []):
        patch = cases.get(case["name"], {})
        if not patch:
            continue
        # Effects and guards are addressed by position: the step order is part
        # of the declaration, so it is a stable key.
        patched_effects = patch.get("effects", [])
        for index, effect in enumerate(case.get("effects", [])):
            if index >= len(patched_effects):
                break
            effect_patch = patched_effects[index] or {}
            if "where" in effect_patch:
                effect["where"] = effect_patch["where"]
            intents = effect_patch.get("fields", {})
            values = effect_patch.get("values", {})
            for field in effect.get("fields", []):
                if field["name"] in intents:
                    field["intent"] = intents[field["name"]]
                if field["name"] in values:
                    field["after"] = values[field["name"]]
        patched_guards = patch.get("guards", [])
        for index, guard in enumerate(case.get("guards", [])):
            if index >= len(patched_guards) or not patched_guards[index]:
                continue
            guard.update({key: value for key, value in patched_guards[index].items()
                          if key in ("when", "then")})
        if patch.get("name"):
            case["name"] = patch["name"]
    return merged


# --------------------------------------------------------------------------- #
# Rendering — view A, the schema
# --------------------------------------------------------------------------- #


def schema_tally(data: dict, chrome: dict) -> str:
    """Counts, summed by the script. Nobody writes this line.

    Table-level and object-level counts stay apart: a created table and an
    added column are not the same unit, and adding them together produces a
    number that means nothing.
    """
    tables = data.get("tables", [])
    created = sum(1 for table in tables if table["op"] == "create-table")
    removed = sum(1 for table in tables if table["op"] == "drop-table")
    counts = {"+": 0, "~": 0, "-": 0}
    for table in tables:
        for obj in table.get("objects", []):
            counts[glyph(obj["op"])] += 1
    return (f"{len(tables)} {chrome['tables']} ({created} {chrome['created']}, "
            f"{removed} {chrome['dropped_t']}) · {counts['+']} {chrome['objects']} "
            f"{chrome['added']} · {counts['~']} {chrome['altered']} · "
            f"{counts['-']} {chrome['dropped']}")


def render_schema(data: dict, lang: str = "en", overlay: dict | None = None) -> str:
    chrome = CHROME.get(lang, CHROME["en"])
    if overlay:
        data = overlay_schema(data, overlay)
    blocks: list[str] = []
    tables = data.get("tables", [])
    if not tables:
        blocks.append(chrome["empty_schema"])
    # One grid for every table and every object, so the intent column sits at
    # the same offset in the whole report. Per-block widths read as ragged.
    entries: list[dict] = []
    for table in tables:
        mark = "★" if table.get("weight") == "heavy" else glyph(table["op"])
        entries.append({"cells": [table["name"], mark, ""], "guide": "", "opens": True,
                        "intent": (table.get("intent") or PLACEHOLDER).strip()})
        objects = table.get("objects", [])
        for index, obj in enumerate(objects):
            last = index == len(objects) - 1
            entries.append({
                "cells": [("└── " if last else "├── ") + obj["name"],
                          glyph(obj["op"]), obj.get("shape", "")],
                "guide": "" if last else "│",
                "opens": False,
                "intent": (obj.get("intent") or PLACEHOLDER).strip(),
            })
    if entries:
        heads = column([entry["cells"] for entry in entries])
        intent_at = min(MAX_INTENT_AT, max(len(head) for head in heads) + 2)
        lines: list[str] = []
        for index, entry in enumerate(entries):
            if entry["opens"] and index:
                lines.append("")
            lines.extend(emit_row(heads[index], entry["guide"], entry["intent"],
                                  intent_at))
        blocks.append("\n".join(lines))
    trailer: list[list[str]] = []
    for migration in data.get("migrations", []):
        tasks = task_range(migration.get("tasks", []))
        # The task list rides with the path, not in a third column: padding it
        # to the width of the tally line would strand it 60 characters away.
        trailer.append([chrome["migration"],
                        migration["path"] + (f"  ({tasks})" if tasks else "")])
        state = migration.get("reversible")
        label = chrome["yes"] if state is True else \
            chrome["no"] if state is False else chrome["unknown"]
        note = (migration.get("note") or "").strip()
        trailer.append([chrome["reversible"], label + (f" — {note}" if note else "")])
    trailer.append([chrome["tally"], schema_tally(data, chrome)])
    blocks.append("\n".join(column(trailer)))
    lines = [chrome["not_touched"]]
    not_touched = data.get("not_touched", [])
    if not_touched:
        for item in not_touched:
            why = (item.get("why") or "").strip()
            lines.append(f"  {item['name']}" + (f" — {why}" if why else ""))
    else:
        lines.append(f"  {chrome['unfilled']}")
    blocks.append("\n".join(lines))
    return "\n\n".join(blocks) + "\n"


# --------------------------------------------------------------------------- #
# Rendering — view B, the effects
# --------------------------------------------------------------------------- #


def net_effect(case: dict) -> str:
    """Sum the effects per table. Deletes are always reported, even at zero.

    A reader's first question about a use case is what disappears; a tally that
    silently omits it when the answer is "nothing" fails to answer it.
    """
    per_table: dict[str, dict[str, list[str]]] = {}
    for effect in case.get("effects", []):
        noun = WRITING_OPS.get(effect["op"])
        if not noun:
            continue
        per_table.setdefault(effect["table"], {}).setdefault(noun, []).append(effect["rows"])
    parts: list[str] = []
    for table, keywords in per_table.items():
        pieces = []
        for keyword, cardinalities in keywords.items():
            amount = str(len(cardinalities)) \
                if all(card == "one" for card in cardinalities) else "N"
            pieces.append(f"{keyword} ×{amount}")
        parts.append(f"{table}: " + " · ".join(pieces))
    deletes = any(keyword.endswith("DELETE") for keywords in per_table.values()
                  for keyword in keywords)
    tally = " · ".join(parts) if parts else "DELETE ×0"
    # The parenthesis is global, not attached to the last table: "what
    # disappears" is the reader's first question and deserves its own answer.
    return tally if deletes else f"{tally}   (DELETE ×0)"


def render_effects(data: dict, lang: str = "en", overlay: dict | None = None) -> str:
    chrome = CHROME.get(lang, CHROME["en"])
    if overlay:
        data = overlay_effects(data, overlay)
    cases = data.get("use_cases", [])
    if not cases:
        return chrome["empty_effects"] + "\n"
    blocks: list[str] = []
    for case in cases:
        tags = " · ".join(filter(None, [
            " ".join(case.get("requirements", [])),
            task_range(case.get("tasks", [])),
        ]))
        label = chrome["use_case"]
        lines = [f"{label}  {case['name'].ljust(44)}{tags}".rstrip(), ""]
        effects = case.get("effects", [])
        # One grid for every field of every step, so the intent column sits at
        # the same offset for the whole use case.
        grid: list[list[str]] = []
        guides: list[str] = []
        for effect in effects:
            fields = effect.get("fields", [])
            for index, field in enumerate(fields):
                last = index == len(fields) - 1
                kind = field.get("kind", "value")
                after = str(field.get("after", ""))
                if kind == "from-step":
                    after = f"{chrome['step']} {after}"
                grid.append([
                    ("     └── " if last else "     ├── ") + field["name"],
                    field.get("before", ""),
                    f"{FIELD_KINDS.get(kind, FIELD_KINDS['value'])} {after}",
                ])
                guides.append("     " if last else "     │")
        heads = column(grid) if grid else []
        intent_at = min(MAX_INTENT_AT, max(len(head) for head in heads) + 2) if heads else 0
        cursor = 0
        for step, effect in enumerate(effects, start=1):
            # The predicate lives on its own line, always. Inlining it makes a
            # header whose width depends on how long the author's WHERE is,
            # and the topology stops being predictable.
            lines.append("".join([
                f"  {step}  ",
                effect["op"].upper().ljust(8),
                effect["table"].ljust(30),
                f"{chrome['rows']}: {chrome['rowcount'].get(effect.get('rows'), effect.get('rows', '?'))}",
            ]).rstrip())
            predicate = effect.get("where", "").strip()
            if predicate:
                lines.extend(wrap_into(f"     {chrome['where']}  ", "     ", predicate))
            fields = effect.get("fields", [])
            for index, field in enumerate(fields):
                slot = cursor + index
                lines.extend(emit_row(heads[slot], guides[slot],
                                      (field.get("intent") or "").strip(), intent_at))
            cursor += len(fields)
            lines.append("")
        guards = case.get("guards", [])
        if guards:
            conditions = [(guard.get("when") or PLACEHOLDER).strip() for guard in guards]
            arrow_at = max(len(condition) for condition in conditions) + 2
            for guard, condition in zip(guards, conditions):
                prefix = f"  {chrome['guard']}  {condition.ljust(arrow_at)}→ "
                lines.extend(wrap_into(prefix, " " * (4 + len(chrome["guard"])),
                                       (guard.get("then") or PLACEHOLDER).strip()))
        else:
            lines.append(f"  {chrome['guard']}  {chrome['no_guard']}")
        lines.append("")
        lines.append(f"  {chrome['net_effect']}  {net_effect(case)}")
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks) + "\n"


RENDERERS = {"schema": render_schema, "effects": render_effects}
VALIDATORS = {"schema": validate_schema, "effects": validate_effects}
OVERLAYS = {"schema": overlay_schema, "effects": overlay_effects}


# --------------------------------------------------------------------------- #
# The SQL anchor
# --------------------------------------------------------------------------- #

#: Markers that a migration file carries DDL this script can read at all.
#: Their absence means "unverifiable", which is never reported as "contradicted".
DDL_MARKERS = re.compile(
    r"(alter\s+table|create\s+table|drop\s+table|create\s+(unique\s+)?index|"
    r"drop\s+index|create\s+trigger|op\.(add_column|drop_column|alter_column|"
    r"create_table|drop_table|create_index|drop_index|create_foreign_key|execute))",
    re.IGNORECASE,
)


def sql_patterns(table: str, obj: str, op: str) -> list[str]:
    """Regexes proving one declared operation exists in a migration.

    Covers raw SQL (Prisma, golang-migrate, plain psql), the SQL that TypeORM
    inlines inside `queryRunner.query`, and Alembic's `op.*` helpers. Django and
    ActiveRecord migrations are out of reach; the report says so rather than
    claiming a contradiction.
    """
    tbl, name = re.escape(table), re.escape(obj)
    alter = rf"alter\s+table\s+[\"`]?(\w+\.)?{tbl}[\"`]?\s+"
    # Alembic folds type, nullability, default and rename into one helper, so
    # every column-modifier op accepts it as proof.
    alembic_alter = rf"op\.alter_column\(\s*[\"']{tbl}[\"']\s*,\s*[\"']{name}[\"']"
    per_op = {
        "add-column": [alter + rf"add\s+(column\s+)?[\"`]?{name}", rf"op\.add_column\(\s*[\"']{tbl}[\"']\s*,\s*sa\.Column\(\s*[\"']{name}[\"']", rf"create\s+table\s+[\"`]?(\w+\.)?{tbl}[\"`]?[\s\S]{{0,4000}}?[\"`]?{name}[\"`]?\s"],
        "drop-column": [alter + rf"drop\s+(column\s+)?[\"`]?{name}", rf"op\.drop_column\(\s*[\"']{tbl}[\"']\s*,\s*[\"']{name}[\"']"],
        "alter-type": [alter + rf"alter\s+(column\s+)?[\"`]?{name}[\"`]?\s+(set\s+data\s+)?type", alembic_alter],
        "set-not-null": [alter + rf"alter\s+(column\s+)?[\"`]?{name}[\"`]?\s+set\s+not\s+null", alembic_alter],
        "drop-not-null": [alter + rf"alter\s+(column\s+)?[\"`]?{name}[\"`]?\s+drop\s+not\s+null", alembic_alter],
        "set-default": [alter + rf"alter\s+(column\s+)?[\"`]?{name}[\"`]?\s+set\s+default", alembic_alter],
        "drop-default": [alter + rf"alter\s+(column\s+)?[\"`]?{name}[\"`]?\s+drop\s+default", alembic_alter],
        "rename-column": [alter + rf"rename\s+(column\s+)?[\"`]?{name}", alembic_alter],
        "backfill": [rf"update\s+[\"`]?(\w+\.)?{tbl}[\"`]?\s+set", rf"insert\s+into\s+[\"`]?(\w+\.)?{tbl}", r"op\.execute\("],
        "add-index": [rf"create\s+(unique\s+)?index\s+(concurrently\s+)?(if\s+not\s+exists\s+)?[\"`]?{name}", rf"op\.create_index\(\s*[\"']{name}[\"']"],
        "drop-index": [rf"drop\s+index\s+(concurrently\s+)?(if\s+exists\s+)?[\"`]?{name}", rf"op\.drop_index\(\s*[\"']{name}[\"']"],
        "add-fk": [alter + rf"add\s+constraint\s+[\"`]?{name}", alter + r"add\s+foreign\s+key", r"op\.create_foreign_key\("],
        "add-check": [alter + rf"add\s+constraint\s+[\"`]?{name}", alter + r"add\s+check"],
        "add-unique": [alter + rf"add\s+constraint\s+[\"`]?{name}", alter + r"add\s+unique"],
        "add-trigger": [rf"create\s+(or\s+replace\s+)?trigger\s+[\"`]?{name}"],
    }
    for family in ("drop-fk", "drop-check", "drop-unique", "drop-trigger"):
        per_op[family] = [alter + rf"drop\s+constraint\s+[\"`]?{name}",
                          rf"drop\s+trigger\s+(if\s+exists\s+)?[\"`]?{name}"]
    return per_op.get(op, [])


def table_patterns(table: str, op: str) -> list[str]:
    tbl = re.escape(table)
    return {
        "create-table": [rf"create\s+table\s+(if\s+not\s+exists\s+)?[\"`]?(\w+\.)?{tbl}",
                         rf"op\.create_table\(\s*[\"']{tbl}[\"']"],
        "drop-table": [rf"drop\s+table\s+(if\s+exists\s+)?[\"`]?(\w+\.)?{tbl}",
                       rf"op\.drop_table\(\s*[\"']{tbl}[\"']"],
        "rename-table": [rf"alter\s+table\s+[\"`]?(\w+\.)?{tbl}[\"`]?\s+rename"],
    }.get(op, [])


def audit_sql(data: dict, repo_root: str) -> tuple[list[str], list[str], int]:
    """Compare every declared operation against the migration files it names.

    Returns (findings, notes, confirmed). A missing statement in a file that
    holds readable DDL is a contradiction. A file this script cannot parse
    yields a note, never a finding.
    """
    findings: list[str] = []
    notes: list[str] = []
    confirmed = 0
    texts: list[str] = []
    for migration in data.get("migrations", []):
        path = os.path.join(repo_root, migration["path"])
        if not os.path.exists(path):
            findings.append(f"missing migration: {migration['path']} is declared, not on disk")
            continue
        texts.append(read(path))
    if not texts:
        notes.append("no migration file read — the SQL anchor did not run")
        return findings, notes, 0
    blob = "\n".join(texts)
    if not DDL_MARKERS.search(blob):
        notes.append("unverifiable: the migrations carry no DDL this script can read "
                     "(Django and ActiveRecord are out of reach)")
        return findings, notes, 0
    for table in data.get("tables", []):
        tbl = bare_table(table["name"])
        checks = [(table["name"], table["op"], table_patterns(tbl, table["op"]))]
        for obj in table.get("objects", []):
            checks.append((f"{table['name']}.{obj['name']}", obj["op"],
                           sql_patterns(tbl, obj["name"], obj["op"])))
        for label, op, patterns in checks:
            if not patterns:
                continue
            if any(re.search(pattern, blob, re.IGNORECASE) for pattern in patterns):
                confirmed += 1
            else:
                findings.append(f"contradicted: {label} declares {op}, "
                                "no matching statement in the migrations")
    return findings, notes, confirmed


# --------------------------------------------------------------------------- #
# Subcommands
# --------------------------------------------------------------------------- #

SKELETONS = {
    "schema": {
        "migrations": [{"path": "db/migrations/NNN_name.sql", "tasks": [],
                        "reversible": None, "note": ""}],
        "tables": [{"name": "public.table_name", "op": "alter-table", "weight": "touch",
                    "intent": "", "tasks": [],
                    "objects": [{"name": "column_name", "op": "add-column",
                                 "shape": "varchar(9) NULL", "intent": ""}]}],
        "not_touched": [],
    },
    "effects": {
        "use_cases": [{"name": "the use case, in domain words", "requirements": [],
                       "tasks": [],
                       "effects": [{"op": "update", "table": "public.table_name",
                                    "where": "", "rows": "one", "test": "",
                                    "fields": [{"name": "column_name", "before": "NULL",
                                                "after": "'value'", "kind": "value",
                                                "intent": ""}]}],
                       "guards": []}],
    },
}


def spec_title(spec_dir: str) -> str:
    for name in ("spec.md", "plan.md"):
        candidate = os.path.join(spec_dir, name)
        if not os.path.exists(candidate):
            continue
        for line in read(candidate).splitlines():
            if line.startswith("# "):
                return line[2:].split(":", 1)[-1].strip()
    return os.path.basename(spec_dir.rstrip("/"))


def cmd_init(args: argparse.Namespace) -> int:
    """Write the skeleton, preserving whatever prose already exists."""
    spec_dir = args.spec.rstrip("/")
    path = artefact_path(spec_dir, args.view)
    data = split_document(read(path)) if os.path.exists(path) else \
        json.loads(json.dumps(SKELETONS[args.view]))
    data.setdefault("spec", spec_dir)
    data["spec"] = spec_dir
    data.setdefault("title", spec_title(spec_dir))
    text = document(data, args.view, RENDERERS[args.view](data))
    if args.write:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        print(f"wrote {path}", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


def cmd_render(args: argparse.Namespace) -> int:
    """Regenerate the report. English to the file, any language to the chat."""
    spec_dir = args.spec.rstrip("/")
    data = load(spec_dir, args.view)
    errors = VALIDATORS[args.view](data)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        raise SystemExit("the declaration is outside the vocabulary — refusing to render")
    translated = args.lang != "en" or bool(args.overlay)
    if args.write and translated:
        raise SystemExit(
            "refusing to write a translated report: the committed artefact is English. "
            "Drop --write to render for the conversation, or drop --lang/--overlay."
        )
    if args.lang not in CHROME:
        print(f"note: no chrome for --lang {args.lang}, falling back to English",
              file=sys.stderr)
    overlay = json.loads(read(args.overlay)) if args.overlay else None
    if args.write:
        with open(artefact_path(spec_dir, args.view), "w", encoding="utf-8") as handle:
            handle.write(document(data, args.view, RENDERERS[args.view](data)))
        print(f"re-rendered {artefact_path(spec_dir, args.view)}", file=sys.stderr)
    else:
        sys.stdout.write(RENDERERS[args.view](data, lang=args.lang, overlay=overlay))
    return 0


def known_tasks(spec_dir: str) -> set[str]:
    path = os.path.join(spec_dir, "tasks.md")
    if not os.path.exists(path):
        return set()
    return {"T" + number for number in TASK_ID_RE.findall(read(path))}


def check_prose(data: dict, view: str, skip: bool) -> list[str]:
    """Every intent filled, and written in English."""
    findings: list[str] = []

    def probe(label: str, text: str, required: bool = True) -> None:
        value = (text or "").strip()
        if required and (not value or value.startswith(PLACEHOLDER)):
            findings.append(f"no intent: {label} — one line, in domain words")
            return
        markers = [] if skip else foreign_words(value)
        if markers:
            findings.append(f"not English: {label} — {', '.join(markers)}. "
                            "The committed artefact is English; translate at render time.")

    if view == "schema":
        for table in data.get("tables", []):
            probe(table["name"], table.get("intent"))
            for obj in table.get("objects", []):
                probe(f"{table['name']}.{obj['name']}", obj.get("intent"))
        for item in data.get("not_touched", []):
            probe(f"not_touched {item['name']}", item.get("why"))
    else:
        for case in data.get("use_cases", []):
            for effect in case.get("effects", []):
                for field in effect.get("fields", []):
                    probe(f"{case['name']} / {effect['table']}.{field['name']}",
                          field.get("intent"), required=False)
            for guard in case.get("guards", []):
                probe(f"{case['name']} guard", guard.get("then"))
    return findings


def cmd_check(args: argparse.Namespace) -> int:
    """The commit gate: vocabulary, anchors, prose, and the mandatory sections."""
    spec_dir = args.spec.rstrip("/")
    data = load(spec_dir, args.view)
    findings = VALIDATORS[args.view](data)
    notes: list[str] = []
    tasks = known_tasks(spec_dir)

    def check_tasks(label: str, declared: list[str]) -> None:
        if not declared:
            findings.append(f"no task: {label} — cite the task that implements it")
            return
        for task in declared:
            if tasks and task not in tasks:
                findings.append(f"unknown task: {label} cites {task}, absent from tasks.md")

    if args.view == "schema":
        for migration in data.get("migrations", []):
            check_tasks(f"migration {migration['path']}", migration.get("tasks", []))
            if migration.get("reversible") is None:
                findings.append(f"reversibility unstated: {migration['path']} — "
                                "say yes or no, and how the down path behaves")
        sql_findings, sql_notes, confirmed = audit_sql(data, args.repo_root)
        findings += sql_findings
        notes += sql_notes
        if confirmed:
            notes.append(f"SQL anchor: {confirmed} declared operation(s) confirmed "
                         "in the migrations")
        if not data.get("not_touched"):
            findings.append("no 'not touched' section — non-negotiable, it carries "
                            "the reassurance")
    else:
        schema_path = artefact_path(spec_dir, "schema")
        schema_tables: set[str] = set()
        if os.path.exists(schema_path):
            schema_data = split_document(read(schema_path))
            schema_tables = {bare_table(t["name"]) for t in schema_data.get("tables", [])}
            schema_tables |= {bare_table(t["name"]) for t in schema_data.get("not_touched", [])}
        else:
            notes.append("no schema-projection.md — table names were not cross-checked")
        for case in data.get("use_cases", []):
            check_tasks(f"use case {case['name']}", case.get("tasks", []))
            if not case.get("effects"):
                findings.append(f"no effect: {case['name']} — a use case that writes "
                                "nothing is a read, say so with op read")
            if not case.get("guards"):
                findings.append(f"no guard: {case['name']} — non-negotiable, state what "
                                "refuses to write")
            for index, effect in enumerate(case.get("effects", []), start=1):
                label = f"{case['name']} step {index}"
                if schema_tables and bare_table(effect["table"]) not in schema_tables:
                    findings.append(f"unknown table: {label} writes {effect['table']}, "
                                    "absent from the schema projection")
                if effect["op"] in ("read", "no-op"):
                    continue
                reference = (effect.get("test") or "").strip()
                if not reference:
                    message = f"no test: {label} — cite the test that proves this effect"
                    (notes if args.skip_test_anchor else findings).append(message)
                    continue
                path, _, name = reference.partition("::")
                full = os.path.join(args.repo_root, path)
                if not os.path.exists(full):
                    findings.append(f"missing test: {label} cites {path}, not on disk")
                elif name and name not in read(full):
                    findings.append(f"missing test case: {label} cites {name!r} "
                                    f"in {path}, not found in it")
    findings += check_prose(data, args.view, args.skip_language)
    if args.json:
        print(json.dumps({"findings": findings, "notes": notes}, indent=2,
                         ensure_ascii=False))
    else:
        for note in notes:
            print(f"note: {note}")
        for finding in findings:
            print(finding)
        if not findings:
            print(f"{args.view} projection honest")
    return 1 if findings else 0


def cmd_verify(args: argparse.Namespace) -> int:
    """The after-shot: re-run the SQL anchor once the migrations are written."""
    spec_dir = args.spec.rstrip("/")
    data = load(spec_dir, "schema")
    findings, notes, confirmed = audit_sql(data, args.repo_root)
    report = {"spec": spec_dir, "confirmed": confirmed, "drift": findings, "notes": notes}
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(f"after-shot — {spec_dir}: {confirmed} operation(s) confirmed in the migrations")
        for note in notes:
            print(f"  note: {note}")
        for finding in findings:
            print(f"  {finding}")
        if not findings:
            print("  no drift: every declared operation exists in the migrations")
    return 1 if findings else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="dataproj.py",
                                     description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", default=".", help="repository root (default: .)")
    views = parser.add_subparsers(dest="view", required=True)
    for view in VIEWS:
        actions = views.add_parser(view, help=VIEWS[view][1].lower()).add_subparsers(
            dest="action", required=True
        )

        def add(name: str, handler, help_text: str) -> argparse.ArgumentParser:
            sub = actions.add_parser(name, help=help_text)
            sub.add_argument("--spec", required=True, help="spec directory")
            sub.set_defaults(handler=handler, view=view)
            return sub

        starter = add("init", cmd_init, "write the declaration skeleton")
        starter.add_argument("--write", action="store_true", help="write in place")

        renderer = add("render", cmd_render, "regenerate the report from the JSON")
        renderer.add_argument("--write", action="store_true",
                              help="write in place (English only)")
        renderer.add_argument("--lang", default="en", metavar="CODE",
                              help=f"chrome language: {', '.join(CHROME)}")
        renderer.add_argument("--overlay", metavar="FILE",
                              help="JSON of translated prose, for this render only")

        checker = add("check", cmd_check, "vocabulary, anchors, prose — the commit gate")
        checker.add_argument("--json", action="store_true", help="machine-readable")
        checker.add_argument("--skip-language", action="store_true",
                             help="do not probe the prose for non-English words")
        checker.add_argument("--skip-test-anchor", action="store_true",
                             help="report effects without a cited test as notes")

        if view == "schema":
            auditor = add("verify", cmd_verify, "re-run the SQL anchor after the fact")
            auditor.add_argument("--json", action="store_true", help="machine-readable")

    args = parser.parse_args(argv)
    for flag in ("skip_language", "skip_test_anchor", "json", "lang", "overlay", "write"):
        if not hasattr(args, flag):
            setattr(args, flag, False if flag != "lang" else "en")
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main())
