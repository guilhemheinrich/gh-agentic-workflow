#!/usr/bin/env bash
# smell-grep.sh - list CANDIDATE state-management and rendering smells.
#
# These are text patterns, not findings. Each hit is a place to open and read
# against references/state-and-rendering-smells.md; many hits are legitimate.
# A pattern with zero hits proves nothing either: the smell may be written in a
# way the pattern does not match. Read-only, POSIX grep only, no Docker needed.
#
# Usage: smell-grep.sh <source-dir> [max-hits-per-smell, default 15]
set -uo pipefail

src="${1:-}"
max="${2:-15}"
if [ -z "$src" ] || [ ! -d "$src" ]; then
  echo "usage: smell-grep.sh <source-dir> [max-hits-per-smell]" >&2
  exit 2
fi

INCLUDES=(--include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.mjs'
  --include='*.vue' --include='*.svelte' --include='*.html')
EXCLUDES=(--exclude-dir=node_modules --exclude-dir=dist --exclude-dir=build --exclude-dir=coverage
  --exclude-dir=.next --exclude-dir=.nuxt --exclude-dir=.svelte-kit --exclude-dir=.angular --exclude-dir=.git
  --exclude='*.min.js' --exclude='*.d.ts' --exclude='*.test.*' --exclude='*.spec.*' --exclude='*.stories.*')

# scan <smell-id> <what a hit may mean> <extended regex>
scan() {
  local id="$1" why="$2" pattern="$3" hits count
  hits="$(cd "$src" && grep -rnE "${INCLUDES[@]}" "${EXCLUDES[@]}" -e "$pattern" . 2>/dev/null)"
  count="$(printf '%s' "$hits" | grep -c . )"
  printf '\n## %s  (%s candidate%s)\n   %s\n' "$id" "$count" "$([ "$count" = 1 ] || echo s)" "$why"
  if [ "$count" -gt 0 ]; then
    printf '%s\n' "$hits" | head -n "$max" | sed 's/^/   /'
    [ "$count" -gt "$max" ] && printf '   ... %s more\n' "$((count - max))"
  fi
}

echo "# smell candidates in $src (patterns, not findings)"

scan S02-whole-store \
  "component subscribes to the entire store: re-renders on any store write" \
  'use([A-Z][A-Za-z]*)?Store\(\s*\)|useSelector\(\s*\(?\s*(state|s)\s*\)?\s*=>\s*(state|s)\s*\)|useContext\(\s*[A-Z][A-Za-z]*(Store|State)Context\s*\)'

scan S03-selector-new-ref \
  "selector builds a new array/object on every call: defeats equality checks, can loop" \
  'use([A-Z][A-Za-z]*)?(Store|Selector)\(.*=>\s*(\(\s*\{|\[|.*\.(map|filter|slice|concat|sort|flatMap|reduce)\(|Object\.(keys|values|entries)\(|new (Map|Set)\()'

scan S03-destructured-store \
  "destructuring a store: whole-store subscription (zustand) or lost reactivity (pinia without storeToRefs)" \
  '(const|let)\s*\{[^}]+\}\s*=\s*use([A-Z][A-Za-z]*)?Store\(\s*\)'

scan S04-prop-mirrored-in-state \
  "prop copied into local state: goes stale, usually followed by a syncing effect" \
  'useState\(\s*props\.|ref\(\s*props\.|signal\(\s*this\.[a-zA-Z]+\(\)\s*\)|\$state\(\s*\$props'

scan S06-watch-writes-state \
  "watcher/effect whose job may be to copy state into other state (derived data stored)" \
  'watch(Effect)?\(|\$effect\(|\beffect\(\s*\(\)\s*=>|createEffect\('

scan S09-unstable-key \
  "list key that is an index or a fresh value: state attaches to the wrong row or rows remount" \
  'key=\{\s*(i|idx|index|[^}]*(Math\.random|Date\.now|uuid|nanoid|randomUUID))[^}]*\}|:key="\s*(i|idx|index)\s*"|track \$index|\{#each [^}]*\}\s*$'

scan S09-ngfor-without-trackby \
  "Angular *ngFor without trackBy: every row is destroyed and recreated on a new array" \
  '\*ngFor="[^"]*"'

scan S10-list-rendering \
  "list rendering sites: check the largest realistic length; over ~100 complex rows needs virtualization" \
  '\.map\(\s*\(?[a-zA-Z_, ]*\)?\s*=>\s*\(?\s*<|v-for=|\{#each |@for \(|\*ngFor=|repeat\('

scan S11-geometry-read \
  "layout-forcing reads: harmless alone, thrashing when interleaved with style writes or run per item/per scroll" \
  '\.(offset(Width|Height|Top|Left)|client(Width|Height)|scroll(Width|Height|Top|Left))\b|getBoundingClientRect\(|getComputedStyle\('

scan S11-unthrottled-listener \
  "scroll/resize/mousemove listener: check for passive:true and rAF/throttle" \
  "addEventListener\(\s*['\"](scroll|resize|mousemove|pointermove|touchmove|wheel)['\"]"

scan S12-two-way-sync \
  "paired update channel: look for a watcher that writes back what it listens to" \
  "emit\(\s*['\"]update:|v-model:|\[\(ngModel\)\]|bind:value=|onChange=\{.*set[A-Z]"

scan S13-deep-clone \
  "deep clone: O(size) on every call and breaks referential equality downstream" \
  'JSON\.parse\(\s*JSON\.stringify\(|structuredClone\(|cloneDeep\('

scan S13-template-call \
  "Angular template calling a function: runs on every change detection pass" \
  '\{\{\s*[a-zA-Z_.]+\([^)]*\)\s*(\|[^}]*)?\}\}'

scan S14-leak-candidates \
  "subscriptions and timers: each needs a matching teardown in the same component" \
  '\.subscribe\(|setInterval\(|new (ResizeObserver|IntersectionObserver|MutationObserver)\(|addEventListener\('

scan S14-teardown-sites \
  "teardown sites, to compare with the count above" \
  'unsubscribe\(|clearInterval\(|\.disconnect\(\)|removeEventListener\(|takeUntilDestroyed|onCleanup\(|onUnmounted\(|onDestroy\(|disconnectedCallback'

scan S15-sync-storage \
  "synchronous storage access: blocks the main thread, costly inside subscribers and render paths" \
  'localStorage\.(setItem|getItem)|sessionStorage\.(setItem|getItem)'

scan S16-async-write-sites \
  "async result written into state: check that a stale response cannot overwrite a newer one" \
  '\.then\(.*(\bset[A-Z][A-Za-z]*\(|\.value\s*=|\.set\()|await .*;\s*set[A-Z][A-Za-z]*\(|use(Effect|LayoutEffect)\(\s*(async|\(\)\s*=>\s*\{?\s*(fetch|axios))|watch(Effect)?\(.*async'

scan S16-guard-sites \
  "cancellation and stale-response guards, to compare with the sites above" \
  'AbortController|\.abort\(\)|signal:|onCleanup\(|onWatcherCleanup\(|switchMap\(|takeLatest|use(Suspense)?Query\(|useSWR\(|createResource\(|rxResource\(|(ignore|cancell?ed|stale|active)\s*=\s*(true|false)'

echo
echo "# virtualization libraries declared (empty = none)"
grep -hoE '"(@tanstack/(react|vue|solid|svelte)-virtual|react-window|react-virtualized|react-virtuoso|vue-virtual-scroller|@angular/cdk|@lit-labs/virtualizer|svelte-virtual-list|virtua)"' \
  "$src/package.json" "$src/../package.json" 2>/dev/null | sort -u | sed 's/^/   /'
exit 0
