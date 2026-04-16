#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# reindex.sh — Spec & Fix Index Integrity Tool
#
# Scans specs/, fixes/, and specs/archive/ for indexed folders.
# Detects duplicates, gaps, and format errors.
# Resolves conflicts using a priority cascade (dates, git branches).
# Re-indexes everything into a continuous [001..N] sequence.
#
# Usage:
#   ./reindex.sh [--dry-run] [--no-confirm] [--no-git]
#
# Options:
#   --dry-run      Show what would be done without making changes
#   --no-confirm   Skip interactive confirmation prompt
#   --no-git       Skip git-based priority resolution (P3-P6)
# =============================================================================

DRY_RUN=false
NO_CONFIRM=false
NO_GIT=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=true ;;
    --no-confirm) NO_CONFIRM=true ;;
    --no-git)     NO_GIT=true ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--no-confirm] [--no-git]"
      echo ""
      echo "  --dry-run      Show plan without making changes"
      echo "  --no-confirm   Skip confirmation prompt"
      echo "  --no-git       Skip git-based priority (P3-P6)"
      exit 0
      ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_title() { echo -e "\n${BOLD}═══ $* ═══${NC}\n"; }

# Extract the NNN prefix from a folder name like "042-feature-name"
extract_index() {
  local name
  name=$(basename "$1")
  echo "$name" | grep -oE '^[0-9]+' || echo ""
}

# Extract the semantic name (everything after NNN-)
extract_name() {
  local name
  name=$(basename "$1")
  echo "$name" | sed -E 's/^[0-9]+-//'
}

# Determine the parent location category for display
location_label() {
  local path="$1"
  if [[ "$path" == specs/archive/* ]] || [[ "$path" == specs/Archive/* ]]; then
    echo "specs/archive/"
  elif [[ "$path" == fixes/* ]]; then
    echo "fixes/"
  else
    echo "specs/"
  fi
}

# Read "Created" date from a markdown file header (YAML-like frontmatter or inline)
read_created_date() {
  local file="$1"
  [[ -f "$file" ]] || { echo ""; return 0; }
  grep -iE '^\*?\*?Created\*?\*?\s*[:=|]\s*' "$file" \
    | head -1 \
    | sed -E 's/.*[:=|]\s*//' \
    | sed -E 's/\s*\|.*//' \
    | tr -d '`*' \
    | xargs \
    || echo ""
}

# Get the created date for a spec folder: stats.md > spec.md > empty
get_created_date() {
  local dir="$1"
  local date=""
  date=$(read_created_date "$dir/stats.md")
  if [[ -z "$date" ]]; then
    date=$(read_created_date "$dir/spec.md")
  fi
  echo "$date"
}

# Check if a folder path exists on a given git branch
exists_on_branch() {
  local branch="$1"
  local path="$2"
  $NO_GIT && { echo "false"; return 0; }
  git rev-parse --verify "$branch" &>/dev/null || { echo "false"; return 0; }
  if git ls-tree -d --name-only "$branch" -- "$path" 2>/dev/null | grep -q .; then
    echo "true"
  else
    echo "false"
  fi
}

# Get the date of the first commit that added this folder
first_commit_date() {
  local path="$1"
  $NO_GIT && { echo ""; return 0; }
  git log --all --diff-filter=A --format="%aI" -- "$path" 2>/dev/null \
    | tail -1 \
    || echo ""
}

# ── Step 1: Inventory ───────────────────────────────────────────────────────

log_title "Step 1: Inventory"

declare -a ALL_DIRS=()
declare -a ALL_PATHS=()

scan_dir() {
  local base="$1"
  [[ -d "$base" ]] || return 0
  for d in "$base"/[0-9]*-*/; do
    [[ -d "$d" ]] || continue
    local idx
    idx=$(extract_index "$d")
    [[ -n "$idx" ]] || continue
    ALL_DIRS+=("$d")
    ALL_PATHS+=("$d")
  done
}

scan_dir "specs"
scan_dir "fixes"
scan_dir "specs/archive"
scan_dir "specs/Archive"

TOTAL=${#ALL_DIRS[@]}

if [[ $TOTAL -eq 0 ]]; then
  log_ok "No indexed folders found. Nothing to do."
  exit 0
fi

log_info "Found $TOTAL indexed folder(s)"

# Build inventory arrays (parallel arrays for POSIX compat)
declare -a INV_PATH=()
declare -a INV_INDEX=()
declare -a INV_NAME=()
declare -a INV_LOCATION=()
declare -a INV_DATE=()
declare -a INV_ON_MAIN=()
declare -a INV_ON_STAGING=()
declare -a INV_FIRST_COMMIT=()

for i in "${!ALL_DIRS[@]}"; do
  dir="${ALL_DIRS[$i]}"
  dir="${dir%/}"

  idx=$(extract_index "$dir")
  idx_num=$((10#$idx))
  name=$(extract_name "$dir")
  loc=$(location_label "$dir")
  created=$(get_created_date "$dir")
  on_main=$(exists_on_branch "main" "$dir")
  on_staging=$(exists_on_branch "staging" "$dir")
  fc=$(first_commit_date "$dir")

  INV_PATH+=("$dir")
  INV_INDEX+=("$idx_num")
  INV_NAME+=("$name")
  INV_LOCATION+=("$loc")
  INV_DATE+=("$created")
  INV_ON_MAIN+=("$on_main")
  INV_ON_STAGING+=("$on_staging")
  INV_FIRST_COMMIT+=("$fc")

  printf "  %03d  %-40s  %-16s  %s\n" "$idx_num" "$name" "$loc" "${created:-<no date>}"
done

# ── Step 2: Detect anomalies ────────────────────────────────────────────────

log_title "Step 2: Diagnostic"

DUPLICATES=0
FORMAT_ERRORS=0

for i in "${!INV_INDEX[@]}"; do
  idx="${INV_INDEX[$i]}"

  raw_idx=$(extract_index "${INV_PATH[$i]}")
  expected=$(printf "%03d" "$idx")
  if [[ "$raw_idx" != "$expected" ]]; then
    log_warn "Format error: '$(basename "${INV_PATH[$i]}")' should start with '$expected'"
    ((FORMAT_ERRORS++)) || true
  fi
done

dup_indices=$(printf '%s\n' "${INV_INDEX[@]}" | sort -n | uniq -d)
if [[ -n "$dup_indices" ]]; then
  while IFS= read -r dup_idx; do
    count=$(printf '%s\n' "${INV_INDEX[@]}" | grep -c "^${dup_idx}$")
    log_warn "DUPLICATE: index $(printf '%03d' "$dup_idx") used by $count folders"
    ((DUPLICATES++)) || true
  done <<< "$dup_indices"
fi

# Check for gaps
sorted_indices=($(printf '%s\n' "${INV_INDEX[@]}" | sort -un))
GAPS=0
if [[ ${#sorted_indices[@]} -gt 0 ]]; then
  expected=1
  for idx in "${sorted_indices[@]}"; do
    while [[ $expected -lt $idx ]]; do
      log_warn "GAP: index $(printf '%03d' "$expected") is missing"
      ((GAPS++)) || true
      ((expected++))
    done
    ((expected++))
  done
fi

if [[ $DUPLICATES -eq 0 && $GAPS -eq 0 && $FORMAT_ERRORS -eq 0 ]]; then
  max_idx="${sorted_indices[${#sorted_indices[@]}-1]}"
  log_ok "Indexation OK — continuous sequence [001..$(printf '%03d' "$max_idx")], $TOTAL folders"
  exit 0
fi

echo ""
log_info "Anomalies: $DUPLICATES duplicate(s), $GAPS gap(s), $FORMAT_ERRORS format error(s)"

# ── Step 3: Sort by priority ────────────────────────────────────────────────

log_title "Step 3: Priority Resolution"

# Build a sort key for each entry.
# Priority cascade: P1 date(stats/spec) > P3 on_main > P4 on_staging > P6 first_commit > name
# We encode this as a comparable string:
#   {original_index}|{date_or_9999}|{on_main_inv}|{on_staging_inv}|{first_commit_or_9999}|{name}
#
# Lower original index = earlier in sequence.
# Earlier date = earlier in sequence.
# on_main=true → 0 (sorts before 1).

declare -a SORT_KEYS=()

for i in "${!INV_INDEX[@]}"; do
  orig_idx="${INV_INDEX[$i]}"
  date="${INV_DATE[$i]}"
  on_main="${INV_ON_MAIN[$i]}"
  on_staging="${INV_ON_STAGING[$i]}"
  fc="${INV_FIRST_COMMIT[$i]}"
  name="${INV_NAME[$i]}"

  # Normalize date to sortable format (empty → "9999-99-99")
  sort_date="${date:-9999-99-99}"
  sort_date="${sort_date:0:10}"

  # Boolean inversion for sort (true=0 sorts before false=1)
  sort_main=$( [[ "$on_main" == "true" ]] && echo "0" || echo "1" )
  sort_staging=$( [[ "$on_staging" == "true" ]] && echo "0" || echo "1" )

  sort_fc="${fc:-9999-99-99T99:99:99}"
  sort_fc="${sort_fc:0:10}"

  # Composite key: original_index first (stable sort), then priority cascade
  key=$(printf "%06d|%s|%s|%s|%s|%s|%d" "$orig_idx" "$sort_date" "$sort_main" "$sort_staging" "$sort_fc" "$name" "$i")
  SORT_KEYS+=("$key")
done

# Sort the keys and extract the original array indices
SORTED_ORDER=($(
  for k in "${SORT_KEYS[@]}"; do echo "$k"; done \
  | sort -t'|' -k1,1n -k2,2 -k3,3 -k4,4 -k5,5 -k6,6 \
  | while IFS='|' read -r _ _ _ _ _ _ orig_i; do echo "$orig_i"; done
))

# ── Step 4: Build re-index plan ─────────────────────────────────────────────

log_title "Step 4: Re-index Plan"

declare -a PLAN_OLD_PATH=()
declare -a PLAN_NEW_INDEX=()
declare -a PLAN_ACTION=()
CHANGES=0

new_idx=1
for i in "${SORTED_ORDER[@]}"; do
  old_path="${INV_PATH[$i]}"
  old_idx="${INV_INDEX[$i]}"
  name="${INV_NAME[$i]}"
  loc="${INV_LOCATION[$i]}"

  new_idx_padded=$(printf "%03d" "$new_idx")
  old_idx_padded=$(printf "%03d" "$old_idx")

  # Determine the parent directory for the new path
  parent_dir=$(dirname "$old_path")
  new_dir="$parent_dir/$new_idx_padded-$name"

  if [[ "$old_path" == "${new_dir%/}" ]] || [[ "$old_path/" == "$new_dir/" ]]; then
    action="—"
  else
    action="RENAME"
    ((CHANGES++)) || true
  fi

  PLAN_OLD_PATH+=("$old_path")
  PLAN_NEW_INDEX+=("$new_idx")
  PLAN_ACTION+=("$action")

  printf "  %s  →  %s  %-16s  %s\n" "$old_idx_padded" "$new_idx_padded" "$name" "$action"

  ((new_idx++))
done

echo ""

if [[ $CHANGES -eq 0 ]]; then
  log_ok "No renames needed — sequence is already correct after gap removal."
  exit 0
fi

log_info "$CHANGES folder(s) to rename"

# ── Step 5: Confirm ─────────────────────────────────────────────────────────

if $DRY_RUN; then
  log_info "[DRY RUN] No changes made."
  exit 0
fi

if ! $NO_CONFIRM; then
  echo ""
  echo -e "${BOLD}Proceed with re-indexation? [y/N]${NC} "
  read -r answer
  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    log_info "Aborted by user."
    exit 0
  fi
fi

# ── Step 6: Execute renames ─────────────────────────────────────────────────

log_title "Step 6: Executing Renames"

# Phase A: Move all folders to temporary names to avoid any collision.
# This is the only safe approach when chains of renames can collide.

declare -a TMP_PATHS=()
RENAME_COUNT=0

for i in "${!PLAN_OLD_PATH[@]}"; do
  [[ "${PLAN_ACTION[$i]}" == "RENAME" ]] || continue

  old_path="${PLAN_OLD_PATH[$i]%/}"
  parent_dir=$(dirname "$old_path")
  tmp_path="$parent_dir/.tmp-reindex-$i"

  log_info "Phase A: mv '$old_path' → '$tmp_path'"
  mv "$old_path" "$tmp_path"
  TMP_PATHS[$i]="$tmp_path"
done

# Phase B: Move from temporary names to final names.

declare -a RENAMED_FROM=()
declare -a RENAMED_TO=()

for i in "${!PLAN_OLD_PATH[@]}"; do
  [[ "${PLAN_ACTION[$i]}" == "RENAME" ]] || continue

  old_path="${PLAN_OLD_PATH[$i]%/}"
  new_idx=${PLAN_NEW_INDEX[$i]}
  new_idx_padded=$(printf "%03d" "$new_idx")
  name=$(extract_name "$old_path")
  parent_dir=$(dirname "$old_path")
  new_path="$parent_dir/$new_idx_padded-$name"
  tmp_path="${TMP_PATHS[$i]}"

  log_info "Phase B: mv '$tmp_path' → '$new_path'"
  mv "$tmp_path" "$new_path"

  RENAMED_FROM+=("$old_path")
  RENAMED_TO+=("$new_path")
  ((RENAME_COUNT++)) || true
done

log_ok "$RENAME_COUNT folder(s) renamed"

# ── Step 7: Update internal file references ─────────────────────────────────

log_title "Step 7: Updating Internal References"

FILES_UPDATED=0

update_references_in_file() {
  local file="$1"
  local old_prefix="$2"
  local new_prefix="$3"

  [[ -f "$file" ]] || return 0

  if grep -q "$old_prefix" "$file" 2>/dev/null; then
    sed -i.bak "s|$old_prefix|$new_prefix|g" "$file"
    rm -f "$file.bak"
    log_info "  Updated: $file"
    ((FILES_UPDATED++)) || true
  fi
}

for i in "${!RENAMED_FROM[@]}"; do
  old_path="${RENAMED_FROM[$i]}"
  new_path="${RENAMED_TO[$i]}"

  old_basename=$(basename "$old_path")
  new_basename=$(basename "$new_path")

  old_idx=$(extract_index "$old_path")
  new_idx=$(extract_index "$new_path")

  old_prefix_dash="$old_idx-"
  new_prefix_dash="$new_idx-"

  log_info "Updating refs in $new_basename ($old_basename → $new_basename)"

  for f in spec.md plan.md stats.md tasks.md prompt.md review.md; do
    update_references_in_file "$new_path/$f" "$old_basename" "$new_basename"
  done
done

log_ok "$FILES_UPDATED file(s) updated"

# ── Step 8: Cross-reference check ───────────────────────────────────────────

log_title "Step 8: Cross-Reference Check"

XREF_UPDATES=0

for i in "${!RENAMED_FROM[@]}"; do
  old_basename=$(basename "${RENAMED_FROM[$i]}")
  new_basename=$(basename "${RENAMED_TO[$i]}")

  for search_dir in specs fixes; do
    [[ -d "$search_dir" ]] || continue

    while IFS= read -r file; do
      [[ -f "$file" ]] || continue
      # Skip files inside the already-renamed folder itself
      [[ "$file" == "${RENAMED_TO[$i]}"/* ]] && continue

      if grep -q "$old_basename" "$file" 2>/dev/null; then
        sed -i.bak "s|$old_basename|$new_basename|g" "$file"
        rm -f "$file.bak"
        log_info "  Cross-ref updated: $file"
        ((XREF_UPDATES++)) || true
      fi
    done < <(find "$search_dir" -name '*.md' -type f 2>/dev/null)
  done
done

log_ok "$XREF_UPDATES cross-reference(s) updated"

# ── Step 9: Validation ──────────────────────────────────────────────────────

log_title "Step 9: Validation"

declare -a FINAL_INDICES=()
VALID=true

for search_dir in specs fixes "specs/archive" "specs/Archive"; do
  [[ -d "$search_dir" ]] || continue
  for d in "$search_dir"/[0-9]*-*/; do
    [[ -d "$d" ]] || continue
    idx=$(extract_index "$d")
    [[ -n "$idx" ]] || continue
    FINAL_INDICES+=("$((10#$idx))")
  done
done

sorted_final=($(printf '%s\n' "${FINAL_INDICES[@]}" | sort -n))
FINAL_TOTAL=${#sorted_final[@]}

expected=1
FINAL_GAPS=0
FINAL_DUPS=0

prev=0
for idx in "${sorted_final[@]}"; do
  if [[ $idx -eq $prev ]]; then
    log_err "DUPLICATE still exists: $(printf '%03d' "$idx")"
    ((FINAL_DUPS++)) || true
    VALID=false
  fi
  while [[ $expected -lt $idx ]]; do
    log_err "GAP still exists: $(printf '%03d' "$expected")"
    ((FINAL_GAPS++)) || true
    VALID=false
    ((expected++))
  done
  prev=$idx
  ((expected++))
done

# ── Step 10: Report ─────────────────────────────────────────────────────────

log_title "Final Report"

echo "  Total indexed folders:    $FINAL_TOTAL"
echo "  Sequence:                 [001..$(printf '%03d' "${sorted_final[${#sorted_final[@]}-1]}")]"
echo "  Folders renamed:          $RENAME_COUNT"
echo "  Internal files updated:   $FILES_UPDATED"
echo "  Cross-references updated: $XREF_UPDATES"
echo "  Remaining duplicates:     $FINAL_DUPS"
echo "  Remaining gaps:           $FINAL_GAPS"
echo ""

if $VALID; then
  log_ok "Re-indexation complete — sequence is continuous and valid."
else
  log_err "Re-indexation completed with errors. Manual review required."
  exit 1
fi
