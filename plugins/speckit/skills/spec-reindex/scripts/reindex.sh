#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# reindex.sh — Spec & Fix Index Integrity Tool
#
# Maintains TWO independent index sequences:
#   - SPECS: specs/, specs/archive*/ (excluding fixes/ subdirs)
#   - FIXES: fixes/, specs/fixes/, specs/archive*/fixes/
#
# Each sequence is independently checked for duplicates, gaps, and format
# errors, then re-indexed into its own continuous [001..N] sequence.
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

extract_index() {
  local name
  name=$(basename "$1")
  echo "$name" | grep -oE '^[0-9]+' || echo ""
}

extract_name() {
  local name
  name=$(basename "$1")
  echo "$name" | sed -E 's/^[0-9]+-//'
}

is_archive_segment() {
  local seg="$1"
  local lower
  lower=$(printf '%s' "$seg" | tr '[:upper:]' '[:lower:]')
  [[ "$lower" == archive* ]]
}

# Classify a folder as "spec" or "fix" based on its parent directory name.
# specs/064-xxx         → parent="specs"    → spec
# fixes/045-xxx         → parent="fixes"    → fix
# specs/fixes/050-xxx   → parent="fixes"    → fix
# specs/archived/060-xx → parent="archived" → spec
# specs/archived/fixes/ → parent="fixes"    → fix
classify_family() {
  local dir="$1"
  local parent
  parent=$(basename "$(dirname "$dir")")
  if [[ "$parent" == "fixes" ]]; then
    echo "fix"
  else
    echo "spec"
  fi
}

location_label() {
  local path="$1"
  if [[ "$path" == fixes/* ]]; then
    echo "fixes/"
    return 0
  fi
  if [[ "$path" == specs/fixes/* ]]; then
    echo "specs/fixes/"
    return 0
  fi
  if [[ "$path" == specs/* ]]; then
    local rest="${path#specs/}"
    local first="${rest%%/*}"
    if [[ -n "$first" ]] && is_archive_segment "$first"; then
      local after_archive="${rest#"$first"/}"
      if [[ "$after_archive" == fixes/* ]]; then
        echo "specs/$first/fixes/"
      else
        echo "specs/$first/"
      fi
      return 0
    fi
  fi
  echo "specs/"
}

declare -a ARCHIVE_ROOTS=()

discover_archive_roots() {
  ARCHIVE_ROOTS=()
  [[ -d specs ]] || return 0
  local d
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    ARCHIVE_ROOTS+=("$d")
  done < <(find specs -mindepth 1 -maxdepth 1 -type d -iname 'archive*' 2>/dev/null | LC_ALL=C sort)
}

declare -a XREF_ROOTS=()

build_xref_roots() {
  XREF_ROOTS=()
  [[ -d specs ]] && XREF_ROOTS+=("specs")
  [[ -d fixes ]] && XREF_ROOTS+=("fixes")
  [[ -d specs/fixes ]] && XREF_ROOTS+=("specs/fixes")
  local ar
  for ar in "${ARCHIVE_ROOTS[@]}"; do
    [[ -d "$ar" ]] && XREF_ROOTS+=("$ar")
    [[ -d "$ar/fixes" ]] && XREF_ROOTS+=("$ar/fixes")
  done
}

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

get_created_date() {
  local dir="$1"
  local date=""
  date=$(read_created_date "$dir/stats.md")
  if [[ -z "$date" ]]; then
    date=$(read_created_date "$dir/spec.md")
  fi
  echo "$date"
}

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

discover_archive_roots

[[ -d specs ]] && scan_dir "specs"
[[ -d fixes ]] && scan_dir "fixes"
[[ -d specs/fixes ]] && scan_dir "specs/fixes"

for ar in "${ARCHIVE_ROOTS[@]}"; do
  scan_dir "$ar"
  [[ -d "$ar/fixes" ]] && scan_dir "$ar/fixes"
done

TOTAL=${#ALL_DIRS[@]}

if [[ $TOTAL -eq 0 ]]; then
  log_ok "No indexed folders found. Nothing to do."
  exit 0
fi

log_info "Found $TOTAL indexed folder(s)"

declare -a INV_PATH=()
declare -a INV_INDEX=()
declare -a INV_NAME=()
declare -a INV_LOCATION=()
declare -a INV_DATE=()
declare -a INV_ON_MAIN=()
declare -a INV_ON_STAGING=()
declare -a INV_FIRST_COMMIT=()
declare -a INV_FAMILY=()

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
  family=$(classify_family "$dir")

  INV_PATH+=("$dir")
  INV_INDEX+=("$idx_num")
  INV_NAME+=("$name")
  INV_LOCATION+=("$loc")
  INV_DATE+=("$created")
  INV_ON_MAIN+=("$on_main")
  INV_ON_STAGING+=("$on_staging")
  INV_FIRST_COMMIT+=("$fc")
  INV_FAMILY+=("$family")

  printf "  %-6s  %03d  %-40s  %-28s  %s\n" "[$family]" "$idx_num" "$name" "$loc" "${created:-<no date>}"
done

SPEC_COUNT=0
FIX_COUNT=0
for f in "${INV_FAMILY[@]}"; do
  [[ "$f" == "spec" ]] && ((SPEC_COUNT++)) || true
  [[ "$f" == "fix" ]]  && ((FIX_COUNT++))  || true
done

log_info "Specs: $SPEC_COUNT | Fixes: $FIX_COUNT"

# ── Step 2: Diagnostic (per family) ─────────────────────────────────────────

log_title "Step 2: Diagnostic"

TOTAL_DUPLICATES=0
TOTAL_GAPS=0
TOTAL_FORMAT_ERRORS=0

for family_name in "spec" "fix"; do
  family_label=$( [[ "$family_name" == "spec" ]] && echo "SPECS" || echo "FIXES" )

  family_indices=()
  family_entries=()
  for i in "${!INV_INDEX[@]}"; do
    if [[ "${INV_FAMILY[$i]}" == "$family_name" ]]; then
      family_indices+=("${INV_INDEX[$i]}")
      family_entries+=("$i")
    fi
  done

  if [[ ${#family_indices[@]} -eq 0 ]]; then
    log_info "[$family_label] No entries — skipping."
    continue
  fi

  echo -e "${BOLD}── $family_label (${#family_indices[@]} entries) ──${NC}"

  # Format check
  for i in "${family_entries[@]}"; do
    idx="${INV_INDEX[$i]}"
    raw_idx=$(extract_index "${INV_PATH[$i]}")
    expected=$(printf "%03d" "$idx")
    if [[ "$raw_idx" != "$expected" ]]; then
      log_warn "[$family_label] Format error: '$(basename "${INV_PATH[$i]}")' should start with '$expected'"
      ((TOTAL_FORMAT_ERRORS++)) || true
    fi
  done

  # Duplicates
  dup_indices=$(printf '%s\n' "${family_indices[@]}" | sort -n | uniq -d)
  local_dups=0
  if [[ -n "$dup_indices" ]]; then
    while IFS= read -r dup_idx; do
      count=$(printf '%s\n' "${family_indices[@]}" | grep -c "^${dup_idx}$")
      log_warn "[$family_label] DUPLICATE: index $(printf '%03d' "$dup_idx") used by $count folders"
      ((local_dups++)) || true
      ((TOTAL_DUPLICATES++)) || true
    done <<< "$dup_indices"
  fi

  # Gaps
  sorted_family=($(printf '%s\n' "${family_indices[@]}" | sort -un))
  local_gaps=0
  fam_expected=1
  for idx in "${sorted_family[@]}"; do
    while [[ $fam_expected -lt $idx ]]; do
      log_warn "[$family_label] GAP: index $(printf '%03d' "$fam_expected") is missing"
      ((local_gaps++)) || true
      ((TOTAL_GAPS++)) || true
      ((fam_expected++))
    done
    ((fam_expected++))
  done

  if [[ $local_dups -eq 0 && $local_gaps -eq 0 ]]; then
    max_fam="${sorted_family[${#sorted_family[@]}-1]}"
    log_ok "[$family_label] Indexation OK — continuous [001..$(printf '%03d' "$max_fam")], ${#family_indices[@]} entries"
  fi
done

if [[ $TOTAL_DUPLICATES -eq 0 && $TOTAL_GAPS -eq 0 && $TOTAL_FORMAT_ERRORS -eq 0 ]]; then
  log_ok "Both sequences are valid. Nothing to do."
  exit 0
fi

echo ""
log_info "Total anomalies: $TOTAL_DUPLICATES duplicate(s), $TOTAL_GAPS gap(s), $TOTAL_FORMAT_ERRORS format error(s)"

# ── Step 3: Priority sort (per family) ───────────────────────────────────────

log_title "Step 3: Priority Resolution"

# SORTED_ORDER encodes per-family ordering: "FAMILY:spec" marker, then
# indices into INV_*, then "FAMILY:fix" marker, then its indices.
declare -a SORTED_ORDER=()

for family_name in "spec" "fix"; do
  family_label=$( [[ "$family_name" == "spec" ]] && echo "SPECS" || echo "FIXES" )

  fam_sort_keys=()
  fam_count=0
  for i in "${!INV_INDEX[@]}"; do
    [[ "${INV_FAMILY[$i]}" == "$family_name" ]] || continue
    ((fam_count++)) || true

    orig_idx="${INV_INDEX[$i]}"
    date="${INV_DATE[$i]}"
    on_main="${INV_ON_MAIN[$i]}"
    on_staging="${INV_ON_STAGING[$i]}"
    fc="${INV_FIRST_COMMIT[$i]}"
    name="${INV_NAME[$i]}"

    sort_date="${date:-9999-99-99}"
    sort_date="${sort_date:0:10}"
    sort_main=$( [[ "$on_main" == "true" ]] && echo "0" || echo "1" )
    sort_staging=$( [[ "$on_staging" == "true" ]] && echo "0" || echo "1" )
    sort_fc="${fc:-9999-99-99T99:99:99}"
    sort_fc="${sort_fc:0:10}"

    key=$(printf "%06d|%s|%s|%s|%s|%s|%d" "$orig_idx" "$sort_date" "$sort_main" "$sort_staging" "$sort_fc" "$name" "$i")
    fam_sort_keys+=("$key")
  done

  if [[ $fam_count -eq 0 ]]; then
    continue
  fi

  log_info "Sorting $family_label ($fam_count entries)"

  fam_sorted=($(
    for k in "${fam_sort_keys[@]}"; do echo "$k"; done \
    | sort -t'|' -k1,1n -k2,2 -k3,3 -k4,4 -k5,5 -k6,6 \
    | while IFS='|' read -r _ _ _ _ _ _ orig_i; do echo "$orig_i"; done
  ))

  SORTED_ORDER+=("FAMILY:$family_name")
  for idx in "${fam_sorted[@]}"; do
    SORTED_ORDER+=("$idx")
  done
done

# ── Step 4: Build re-index plan (per family) ────────────────────────────────

log_title "Step 4: Re-index Plan"

declare -a PLAN_OLD_PATH=()
declare -a PLAN_NEW_INDEX=()
declare -a PLAN_ACTION=()
CHANGES=0

new_idx=0

for entry in "${SORTED_ORDER[@]}"; do
  if [[ "$entry" == FAMILY:* ]]; then
    family_name="${entry#FAMILY:}"
    family_label=$( [[ "$family_name" == "spec" ]] && echo "SPECS" || echo "FIXES" )
    echo -e "\n${BOLD}── $family_label ──${NC}"
    new_idx=1
    continue
  fi

  i="$entry"
  old_path="${INV_PATH[$i]}"
  old_idx="${INV_INDEX[$i]}"
  name="${INV_NAME[$i]}"
  loc="${INV_LOCATION[$i]}"

  new_idx_padded=$(printf "%03d" "$new_idx")
  old_idx_padded=$(printf "%03d" "$old_idx")

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

  printf "  %s  →  %s  %-40s  %-28s  %s\n" "$old_idx_padded" "$new_idx_padded" "$name" "$loc" "$action"

  ((new_idx++))
done

echo ""

if [[ $CHANGES -eq 0 ]]; then
  log_ok "No renames needed — sequences are already correct."
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

# Phase A: all folders → temporary names (avoids collisions in rename chains)

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

# Phase B: temporary names → final names

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

  log_info "Updating refs in $new_basename ($old_basename → $new_basename)"

  for f in spec.md plan.md stats.md tasks.md prompt.md review.md; do
    update_references_in_file "$new_path/$f" "$old_basename" "$new_basename"
  done
done

log_ok "$FILES_UPDATED file(s) updated"

# ── Step 8: Cross-reference check ───────────────────────────────────────────

log_title "Step 8: Cross-Reference Check"

XREF_UPDATES=0

build_xref_roots

for i in "${!RENAMED_FROM[@]}"; do
  old_basename=$(basename "${RENAMED_FROM[$i]}")
  new_basename=$(basename "${RENAMED_TO[$i]}")

  if [[ ${#XREF_ROOTS[@]} -eq 0 ]]; then
    continue
  fi

  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    [[ "$file" == "${RENAMED_TO[$i]}"/* ]] && continue

    if grep -q "$old_basename" "$file" 2>/dev/null; then
      sed -i.bak "s|$old_basename|$new_basename|g" "$file"
      rm -f "$file.bak"
      log_info "  Cross-ref updated: $file"
      ((XREF_UPDATES++)) || true
    fi
  done < <(find "${XREF_ROOTS[@]}" -name '*.md' -type f 2>/dev/null | LC_ALL=C sort -u)
done

log_ok "$XREF_UPDATES cross-reference(s) updated"

# ── Step 9: Validation (per family) ─────────────────────────────────────────

log_title "Step 9: Validation"

VALID=true
FINAL_TOTAL=0

collect_indices_for() {
  local root="$1"
  [[ -d "$root" ]] || return 0
  local d
  for d in "$root"/[0-9]*-*/; do
    [[ -d "$d" ]] || continue
    local idx
    idx=$(extract_index "$d")
    [[ -n "$idx" ]] || continue
    echo "$((10#$idx))"
  done
}

for family_name in "spec" "fix"; do
  family_label=$( [[ "$family_name" == "spec" ]] && echo "SPECS" || echo "FIXES" )

  fam_final=()

  if [[ "$family_name" == "spec" ]]; then
    while IFS= read -r idx; do
      [[ -n "$idx" ]] && fam_final+=("$idx")
    done < <(collect_indices_for "specs")
    for ar in "${ARCHIVE_ROOTS[@]}"; do
      while IFS= read -r idx; do
        [[ -n "$idx" ]] && fam_final+=("$idx")
      done < <(collect_indices_for "$ar")
    done
  else
    while IFS= read -r idx; do
      [[ -n "$idx" ]] && fam_final+=("$idx")
    done < <(collect_indices_for "fixes")
    while IFS= read -r idx; do
      [[ -n "$idx" ]] && fam_final+=("$idx")
    done < <(collect_indices_for "specs/fixes")
    for ar in "${ARCHIVE_ROOTS[@]}"; do
      [[ -d "$ar/fixes" ]] || continue
      while IFS= read -r idx; do
        [[ -n "$idx" ]] && fam_final+=("$idx")
      done < <(collect_indices_for "$ar/fixes")
    done
  fi

  if [[ ${#fam_final[@]} -eq 0 ]]; then
    continue
  fi

  sorted_fam=($(printf '%s\n' "${fam_final[@]}" | sort -n))
  fam_total=${#sorted_fam[@]}
  ((FINAL_TOTAL += fam_total)) || true

  fam_expected=1
  fam_prev=0
  fam_dups=0
  fam_gaps=0

  for idx in "${sorted_fam[@]}"; do
    if [[ $idx -eq $fam_prev ]]; then
      log_err "[$family_label] DUPLICATE still exists: $(printf '%03d' "$idx")"
      ((fam_dups++)) || true
      VALID=false
    fi
    while [[ $fam_expected -lt $idx ]]; do
      log_err "[$family_label] GAP still exists: $(printf '%03d' "$fam_expected")"
      ((fam_gaps++)) || true
      VALID=false
      ((fam_expected++))
    done
    fam_prev=$idx
    ((fam_expected++))
  done

  max_fam="${sorted_fam[${#sorted_fam[@]}-1]}"
  if [[ $fam_dups -eq 0 && $fam_gaps -eq 0 ]]; then
    log_ok "[$family_label] Valid — continuous [001..$(printf '%03d' "$max_fam")], $fam_total entries"
  fi
done

# ── Step 10: Report ─────────────────────────────────────────────────────────

log_title "Final Report"

echo "  Total indexed folders:    $FINAL_TOTAL"
echo "  Folders renamed:          $RENAME_COUNT"
echo "  Internal files updated:   $FILES_UPDATED"
echo "  Cross-references updated: $XREF_UPDATES"
echo ""

if $VALID; then
  log_ok "Re-indexation complete — both sequences are continuous and valid."
else
  log_err "Re-indexation completed with errors. Manual review required."
  exit 1
fi
