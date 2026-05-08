# html-validate — W3C HTML Validation & Semantic Analysis

## Official Documentation

- **Official Site**: https://html-validate.org/
- **GitHub**: https://github.com/html-validate/html-validate
- **npm Package**: https://www.npmjs.com/package/@html-validate/cli
- **Rules Reference**: https://html-validate.org/rules/

## Overview

html-validate is an open-source HTML validator that:

- **Validates** against W3C HTML5 specification.
- **Detects** semantic errors (invalid nesting, missing required attributes).
- **Checks** 50+ configurable rules.
- **Reports** errors, warnings, and info messages.
- **Supports** custom rule configuration.
- **Outputs** JSON, stylish (pretty), codeframe (with context).

Common issues detected:

- **Void elements** (br, img, input) used incorrectly.
- **Heading hierarchy** (h1 → h3 without h2).
- **Missing attributes** (alt for img, name for form inputs).
- **Invalid nesting** (p inside button, form inside form).
- **Missing required elements** (DOCTYPE, lang attribute).
- **Deprecated elements** (font, center, marquee).
- **Duplicate IDs** (id attributes not unique).
- **Missing label associations** (form fields without label).

## Docker Image

**Options**:
1. Use `node:20-alpine` + `npm install -g @html-validate/cli` on-the-fly.
2. Use bundled `web-analysis` image (includes html-validate pre-installed).

### Quick run

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g @html-validate/cli && \
    html-validate https://example.com'
```

## Running html-validate

### Minimal example

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g @html-validate/cli && \
    html-validate https://example.com'
```

**Output**: CLI report (default reporter, human-readable).

### JSON output

```bash
docker run --rm \
  -v "$(pwd)/html-results:/results" \
  node:20-alpine \
  sh -c 'npm install -g @html-validate/cli && \
    html-validate https://example.com --format json > /results/validation.json'
```

**Output**: JSON file with structured validation results.

### Detailed codeframe output

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g @html-validate/cli && \
    html-validate https://example.com --format codeframe'
```

**Output**: Error messages with context (lines of code around issue).

## Flags Reference

### Output Formats

- **`--format=stylish`** — pretty-printed CLI output (default).
- **`--format=json`** — JSON (machine-readable).
- **`--format=codeframe`** — detailed code context (like ESLint).
- **`--format=checkstyle`** — CheckStyle XML (CI/CD tools).

### Configuration & Rules

- **`--config=/path/to/.htmlvalidate.json`** — custom rule config file.
- **`--rules`** — list all available rules and their status.
- **`--no-config`** — ignore config file, use defaults.
- **`--enum=<rule>=<value>`** — override a rule (e.g., `--enum=void-non-void=false`).

### Other Options

- **`--help`** — show help.
- **`--version`** — show version.
- **`--no-color`** — disable colored output.

## Output Format (JSON)

```json
{
  "valid": false,
  "results": [
    {
      "filePath": "https://example.com/index.html",
      "messages": [
        {
          "ruleId": "void-non-void",
          "severity": 2,
          "message": "Element <img> is a void element and must not have a closing tag",
          "line": 5,
          "column": 12,
          "size": 4,
          "selector": "img"
        },
        {
          "ruleId": "heading-level",
          "severity": 1,
          "message": "Heading skipped from h1 to h3",
          "line": 12,
          "column": 1,
          "size": 4,
          "selector": "h3"
        }
      ]
    }
  ]
}
```

### Field meanings

- **`valid`**: Overall result (true/false).
- **`ruleId`**: Name of the violated rule.
- **`severity`**: 0 = info, 1 = warning, 2 = error.
- **`message`**: Human-readable error description.
- **`line`** / **`column`**: Location in source.
- **`selector`**: CSS selector of the problematic element.

## Common Rules (50+)

### HTML Structure

| Rule | Purpose | Default |
|------|---------|---------|
| `no-dup-id` | Reject duplicate IDs | Error |
| `void-non-void` | Reject `/` in void elements | Error |
| `no-missing-doctype` | Require DOCTYPE | Error |
| `no-raw-unicode` | Reject raw Unicode in attributes | Error |
| `heading-level` | Enforce h1→h2→h3 hierarchy | Warning |

### Accessibility

| Rule | Purpose |
|------|---------|
| `require-img-alt` | img elements must have alt |
| `form-dup-name` | Form elements can't share names |
| `missing-required` | Missing required attributes |
| `attr-case` | Attribute names lowercase |

### Semantic HTML

| Rule | Purpose |
|------|---------|
| `no-inline-style` | Warn on inline `style` attribute |
| `no-dup-attr` | No duplicate attributes |
| `close-attr-new-line` | Enforce `>` closing on new line (optional) |

### Nesting

| Rule | Purpose |
|------|---------|
| `no-p-in-button` | `p` cannot be inside `button` |
| `no-form-in-form` | Forms cannot be nested |
| `no-textarea-resize` | Warn on textarea `resize` style |

## Common Use Cases

### Quick validation

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g @html-validate/cli && \
    html-validate https://example.com'
```

### Save JSON report

```bash
docker run --rm \
  -v "$(pwd)/results:/results" \
  node:20-alpine \
  sh -c 'npm install -g @html-validate/cli && \
    html-validate https://example.com --format json > /results/report.json'
```

### Get detailed error context

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g @html-validate/cli && \
    html-validate https://example.com --format codeframe'
```

### List available rules

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g @html-validate/cli && \
    html-validate --rules'
```

### Validate with custom config

Create `.htmlvalidate.json`:

```json
{
  "rules": {
    "heading-level": "off",
    "void-non-void": "error",
    "no-dup-id": "error",
    "require-img-alt": "error",
    "no-inline-style": "warn"
  }
}
```

Then run:

```bash
docker run --rm \
  -v "$(pwd):/work" \
  node:20-alpine \
  sh -c 'npm install -g @html-validate/cli && \
    html-validate https://example.com \
      --config=/work/.htmlvalidate.json \
      --format json'
```

## Configuration (.htmlvalidate.json)

### Rule levels

- **`"off"` / `false`**: Disable rule (0 severity).
- **`"warn"` / `1`**: Warning (1 severity).
- **`"error"` / `2` / `true`**: Error (2 severity).

### Example config (strict)

```json
{
  "rules": {
    "no-dup-id": "error",
    "void-non-void": "error",
    "no-missing-doctype": "error",
    "heading-level": "warn",
    "require-img-alt": "error",
    "form-dup-name": "error",
    "attr-case": "error",
    "no-inline-style": "warn",
    "no-p-in-button": "error"
  }
}
```

### Example config (permissive)

```json
{
  "rules": {
    "no-dup-id": "error",
    "void-non-void": "error",
    "no-missing-doctype": "off",
    "heading-level": "off",
    "require-img-alt": "warn",
    "form-dup-name": "error",
    "no-inline-style": "off"
  }
}
```

## Troubleshooting

### Error: `Error: Failed to fetch URL`

**Cause**: URL unreachable from container.

**Fix**: Verify URL is accessible:

```bash
docker run --rm alpine:latest \
  sh -c 'apk add curl && curl -I https://example.com'
```

### No errors reported, but HTML looks invalid

**Cause**: Rule disabled in config or not in rule set.

**Fix**: Check available rules:

```bash
docker run --rm \
  node:20-alpine \
  sh -c 'npm install -g @html-validate/cli && html-validate --rules' | grep -i "<rule_name>"
```

### Config file not being read

**Cause**: Path incorrect or config syntax invalid.

**Fix**: Validate JSON and check path:

```bash
docker run --rm \
  -v "$(pwd):/work" \
  node:20-alpine \
  sh -c 'npm install -g @html-validate/cli && \
    html-validate /work/test.html \
      --config=/work/.htmlvalidate.json \
      --no-color'
```

## Parsing JSON Output

### Count errors vs warnings

```bash
jq '[.results[].messages[]] | {errors: [.[] | select(.severity == 2)] | length, warnings: [.[] | select(.severity == 1)] | length}' report.json
```

### Extract all error messages

```bash
jq '.results[].messages[] | select(.severity == 2) | {ruleId, message}' report.json
```

### Find issues by rule type

```bash
jq '.results[].messages[] | select(.ruleId == "heading-level")' report.json
```

### Summary report

```bash
jq '{
  valid: .valid,
  total_issues: [.results[].messages[]] | length,
  errors: [.results[].messages[] | select(.severity == 2)] | length,
  warnings: [.results[].messages[] | select(.severity == 1)] | length,
  rules_violated: [.results[].messages[].ruleId] | unique
}' report.json
```

## Integration with CI/CD

### GitHub Actions

```yaml
- name: Validate HTML
  run: |
    docker run --rm \
      -v "${{ github.workspace }}/results:/results" \
      node:20-alpine \
      sh -c 'npm install -g @html-validate/cli && \
        html-validate ${{ env.TARGET_URL }} --format json > /results/validation.json'

- name: Check for errors
  run: |
    ERRORS=$(jq '[.results[].messages[] | select(.severity == 2)] | length' results/validation.json)
    if [ "$ERRORS" -gt 0 ]; then
      echo "Found $ERRORS HTML validation errors"
      jq '.results[].messages[] | select(.severity == 2)' results/validation.json
      exit 1
    fi
```

## Rules List (Complete)

Full list available at https://html-validate.org/rules/, includes:

- **Structure**: `no-dup-id`, `void-non-void`, `no-missing-doctype`, `heading-level`
- **Accessibility**: `require-img-alt`, `form-dup-name`, `missing-required`
- **Semantic**: `no-inline-style`, `attr-case`, `no-dup-attr`
- **Nesting**: `no-p-in-button`, `no-form-in-form`
- **Validation**: `attribute-boolean-style`, `unrecognized-attribute`

## Resources

- **html-validate Official**: https://html-validate.org/
- **GitHub**: https://github.com/html-validate/html-validate
- **Rules Reference**: https://html-validate.org/rules/
- **W3C HTML Spec**: https://html.spec.whatwg.org/
- **Semantic HTML Guide**: https://developer.mozilla.org/en-US/docs/Glossary/Semantics
