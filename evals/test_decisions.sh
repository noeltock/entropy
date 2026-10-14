#!/usr/bin/env bash
# Fixed decision/coverage cases. No real user data, services, or cleanup actions.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${ENTROPY_TEST_SCRIPT:-$HERE/../scripts/entropy.sh}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/entropy-decisions.XXXXXX")
export ENTROPY_HOME=$ROOT/home ENTROPY_STATE_DIR=$ROOT/state ENTROPY_NO_HISTORY=1
mkdir -p "$ENTROPY_HOME" "$ENTROPY_STATE_DIR/work"
sed '$d' "$SCRIPT" > "$ROOT/definitions.sh"
source "$ROOT/definitions.sh"
W=$ENTROPY_STATE_DIR/work; export W TMO
export -f T size_job
JSON=1; ALL=1; NOCWD=""; HELD=""
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s (fixture %s)\n' "$1" "$ROOT" >&2; exit 1; }
# Every case is required; baseline lacking the helper fails rather than skipping.
declare -F prepare_decisions >/dev/null || fail 'decision evidence unavailable'

# Batch metadata: 4000 old tiny files, one fresh file, one symlink.
mkdir -p "$ENTROPY_HOME/.agent-browser" "$ROOT/bin"
for ((i=0;i<4000;i++)); do printf x > "$ENTROPY_HOME/.agent-browser/old $i.config"; done
touch -t 202601010000 "$ENTROPY_HOME/.agent-browser/"*.config
printf x > "$ENTROPY_HOME/.agent-browser/fresh.config"
ln -s "$ENTROPY_HOME/.agent-browser/old 0.config" "$ENTROPY_HOME/.agent-browser/link.config"
cat > "$ROOT/bin/stat" <<'SH'
#!/bin/bash
printf 'call\n' >> "$ENTROPY_TEST_STAT_CALLS"
exec /usr/bin/stat "$@"
SH
chmod +x "$ROOT/bin/stat"
export ENTROPY_TEST_STAT_CALLS=$ROOT/stat.calls
PATH=$ROOT/bin:$PATH; export PATH
CUL=$W/culprits.tsv; export CUL
printf 'path\tagent-browser-sessions\tagent scratch\told session files\t~/.agent-browser/*.config\tpath\tnormal\trecreated\t1\n' > "$CUL"
: > "$W/notes"
phase_paths
[ "$(wc -l < "$W/path.sizes" | tr -d ' ')" = 4000 ] || fail 'all eligible files measured'
[ "$(wc -l < "$ENTROPY_TEST_STAT_CALLS" | tr -d ' ')" -le 21 ] || fail 'metadata must be batched'
awk -F'\t' '$2!=4 {exit 1}' "$W/path.sizes" || fail 'allocated KiB preserved'
grep -q 'old 3999.config' "$W/path.sizes" || fail 'spaces preserved'
! grep -Eq 'fresh.config|link.config' "$W/path.sizes" || fail 'fresh files and symlinks excluded'
pass '4000 files measured in <=21 metadata calls; fresh files/symlinks excluded'

# Synthetic ancestry: same signature, two separate roots; one owned by a live agent.
printf 'proc\thttp-server\tagent processes\tstatic servers\tpython3 -m http.server\tany\tnormal\tserver stops\n' > "$CUL"
cat > "$W/ps.snap" <<'PS'
100 1 2-00:00:00 1000 0.0 /usr/local/bin/claude
101 100 2-00:00:00 1000 0.0 python3 -m http.server 8000
102 101 2-00:00:00 1000 0.0 helper
200 1 2-00:00:00 1000 0.0 python3 -m http.server 9000
201 200 2-00:00:00 1000 0.0 helper
PS
printf '101\tpython\t/fixture/live\n200\tpython\t/fixture/detached\n' > "$W/cwds.tsv"
phase_procs
awk -F'\t' '$3=="proc:http-server:101" && $1==9 && $9=="held" && $11=="102 101" {ok=1} END{exit !ok}' "$W/i.procs" || fail 'live ancestor held, children first'
awk -F'\t' '$3=="proc:http-server:200" && $9=="ask" && $11=="201 200" {ok=1} END{exit !ok}' "$W/i.procs" || fail 'detached root needs review'
[ "$(wc -l < "$W/i.procs" | tr -d ' ')" = 2 ] || fail 'roots kept separate'
pass 'process roots separate; live ancestry held; PPID 1 review-only'

# Decision and overlap accounting, including an active cache and unknown size.
: > "$W/items.tsv"
OUT=$W/items.tsv
emit 2 caches path:npm npm 1048576 1 864000 npm normal 'npm cache clean --force' /cache/npm downloads
emit 2 caches path:pnpm pnpm 2097152 1 864000 pnpm normal 'pnpm store prune' /cache/pnpm downloads
emit 2 caches path:playwright playwright 4096000 1 864000 playwright low clean /cache/playwright downloads
emit 2 caches path:playwright-mcp-profiles profiles 1024000 2 864000 profiles normal path '/cache/playwright/mcp-a|/cache/playwright/mcp-b' logins
emit 2 caches path:xcode-derived-data xcode 3145728 1 3600 xcode normal path /cache/xcode rebuild
emit 2 caches path:bun bun 1048576 1 864000 bun normal clean /cache/bun downloads
emit 2 caches path:pip pip '?' 1 864000 pip normal clean /cache/pip downloads
emit 2 'agent worktrees' wt:legacy legacy 1024 1 864000 legacy normal remove /fixture/legacy files
printf '250\tnode\t/cache/bun/subdir\n' >> "$W/cwds.tsv"
printf 'path:xcode-derived-data\tCrewClock 2.3 GiB; ModuleCache 759 MiB\n' > "$W/details.tsv"
RUN_TS=$(date +%s)
printf '{"ts":%s,"key":"path:npm","size_kb":524288}\n' "$((RUN_TS-90000))" > "$ENTROPY_STATE_DIR/history.jsonl"
printf '{"ts":%s,"key":"path:npm","size_kb":1048576}\n' "$((RUN_TS-60))" >> "$ENTROPY_STATE_DIR/history.jsonl"
printf '{"ts":%s,"key":"wt:legacy","size_kb":1791943399}\n' "$((RUN_TS-90000))" >> "$ENTROPY_STATE_DIR/history.jsonl"
prepare_decisions
awk -F'\t' '$1=="path:npm" && $2=="high" && $6==1048576 && $5 ~ /\+512 MiB/ {ok=1} END{exit !ok}' "$W/decisions.tsv" || fail 'cache evidence and day-over-day growth'
awk -F'\t' '$1=="path:pnpm" && $2!="high" && $6==-1 {ok=1} END{exit !ok}' "$W/decisions.tsv" || fail 'prune savings unknown'
awk -F'\t' '$1=="path:pip" && $2=="unknown" && $6==-1 {ok=1} END{exit !ok}' "$W/decisions.tsv" || fail 'unknown size excluded'
awk -F'\t' '$3=="path:bun" && $1==9 && $9=="held" {ok=1} END{exit !ok}' "$W/items.tsv" || fail 'active cache held'
awk -F'\t' '$1=="path:xcode-derived-data" && $2!="high" && $4 ~ /CrewClock/ {ok=1} END{exit !ok}' "$W/decisions.tsv" || fail 'specific build detail, not recommended'
awk -F'\t' '$1=="path:playwright-mcp-profiles" && $7=="path:playwright" {ok=1} END{exit !ok}' "$W/decisions.tsv" || fail 'nested size linked to parent'
pass 'confidence, live cache gate, unknown savings, named details, comparable history'
awk -F'\t' '$1=="wt:legacy" && $5=="-" {ok=1} END{exit !ok}' "$W/decisions.tsv" || fail 'legacy corrupt worktree history reused'
pass 'legacy worktree size history excluded from growth claims'

# A partial ownership snapshot must never support a confident recommendation.
cp "$W/items.tsv" "$ROOT/items-before-partial.tsv"
NOCWD=1
prepare_decisions
! awk -F'\t' '$2=="high" {found=1} END{exit !found}' "$W/decisions.tsv" || fail 'partial ownership check promoted a recommendation'
NOCWD=""
cp "$ROOT/items-before-partial.tsv" "$W/items.tsv"
prepare_decisions
pass 'partial ownership evidence suppresses confident picks'
# An install can use a global cache while its cwd is in a project.
printf '300 1 00:01:00 1000 0.0 npm install\n' >> "$W/ps.snap"
prepare_decisions
awk -F'\t' '$3=="path:npm" && $1==9 {ok=1} END{exit !ok}' "$W/items.tsv" || fail 'active package install not held'
sed '$d' "$W/ps.snap" > "$W/ps.clean"
mv "$W/ps.clean" "$W/ps.snap"
cp "$ROOT/items-before-partial.tsv" "$W/items.tsv"
prepare_decisions
pass 'active package installation holds the global cache'


# A du that emits a plausible number and then fails is incomplete evidence.
(
  T() { shift; "$@"; }
  du() { printf '4096\t%s\n' "$ENTROPY_HOME"; return 1; }
  unset PATH_DEADLINE
  size_job "npm$TAB$ENTROPY_HOME"
) > "$ROOT/partial-size.tsv"
awk -F'\t' '$2!="?" {exit 1}' "$ROOT/partial-size.tsv" || fail 'partial du output treated as measured size'
pass 'failed sizing cannot promote partial output to a measurement'

# Render the fixed rows alone and check arithmetic in the emitted summary.
cp "$W/items.tsv" "$W/i.fixed"
for f in "$W"/i.*; do [ "$f" = "$W/i.fixed" ] || : > "$f"; done
: > "$W/machine.tsv"
render > "$ROOT/result.json"
render_table > "$ROOT/table.txt"
plutil -convert json -o /dev/null "$ROOT/result.json"
# npm 1 + pnpm 2 + browser 3.90625 + Xcode 3 = 9.90625 GiB, rounded 10.
# Nested profile 0.97656 GiB and held bun 1 GiB are excluded.
grep -q 'measured paths 10 GiB (overlaps excluded)' "$ROOT/table.txt" || fail 'deduplicated occupied total'
[ "$(grep -c 'RECOMMEND ' "$ROOT/table.txt")" = 1 ] || fail 'only supported cache recommended'
! grep -q 'safe now' "$ROOT/table.txt" || fail 'no guaranteed recovery total'
pass 'deduplicated totals and evidence-based picks render correctly'
printf 'Fixtures retained: %s\n' "$ROOT"
