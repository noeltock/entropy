#!/usr/bin/env bash
# Exercise the production worktree aggregation and JSON writer with fixed records.
# No real repositories, processes or Docker are inspected. Keep fixtures for review.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${ENTROPY_TEST_SCRIPT:-$HERE/../scripts/entropy.sh}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/entropy-wt-sizes.XXXXXX")
export ENTROPY_STATE_DIR=$ROOT/state ENTROPY_REPOS_DIR=$ROOT/repos
export ENTROPY_WORKTREE_DIRS=$ROOT/none ENTROPY_MIN_MB=0 ENTROPY_NO_HISTORY=1
mkdir -p "$ENTROPY_STATE_DIR/work" "$ENTROPY_REPOS_DIR/alpha/.git"
# Load definitions without starting a machine scan.
sed '$d' "$SCRIPT" > "$ROOT/definitions.sh"
source "$ROOT/definitions.sh"
W=$ENTROPY_STATE_DIR/work
JSON=1; ALL=1; NOCWD=""
export W TMO NOCWD ALL ENTROPY_MIN_MB
git() { printf 'worktree /fixture/main\n\nworktree /fixture/linked\n'; }
T() { shift; "$@"; }
inspect_wt() { cat "$W/fixture.tsv"; }
export -f T inspect_wt
: > "$W/machine.tsv"; : > "$W/notes"
now=$(date +%s)
mt=$((now - 3600))
for scenario in known unknown mixed zero; do
  : > "$W/fixture.tsv"
  case "$scenario" in
    known) printf 'alpha\t/fixture/known\t1024\t0\t0\t-\t%s\tmain\n' "$mt" ;;
    unknown) printf 'alpha\t/fixture/unknown\t?\t0\t0\t-\t%s\tHEAD\n' "$mt" ;;
    mixed)
      printf 'alpha\t/fixture/known\t1024\t0\t0\t-\t%s\tmain\n' "$mt"
      printf 'alpha\t/fixture/unknown\t?\t0\t0\t-\t%s\tHEAD\n' "$mt" ;;
    zero) printf 'alpha\t/fixture/zero\t0\t0\t0\t-\t0\tHEAD\n' ;;
  esac > "$W/fixture.tsv"
  : > "$W/i.wt"
  phase_worktrees
  render > "$ROOT/$scenario.json"
  # Validate every position before checking the serialized row.
  awk -F'\t' -v s="$scenario" -v mt="$mt" -v now="$now" '
    NF!=12 || $3!="wt:alpha" || $8!="alpha" {exit 1}
    s=="known" && ($5!=1024 || $6!=1 || $11!="/fixture/known") {exit 1}
    s=="unknown" && ($5!="?" || $6!=1 || $11!="/fixture/unknown" || !index($4,"1 not sized")) {exit 1}
    s=="mixed" && ($5!="?" || $6!=2 || $11!="/fixture/known|/fixture/unknown" || !index($4,"1 not sized")) {exit 1}
    s=="zero" && ($5!=0 || $6!=1 || $11!="/fixture/zero") {exit 1}
    s!="zero" && ($7<now-mt || $7>now-mt+10) {exit 1}
  ' "$W/i.wt"
  plutil -convert json -o /dev/null "$ROOT/$scenario.json"
  case "$scenario" in
    unknown|mixed) grep -q '"size_kb":-1' "$ROOT/$scenario.json" ;;
    known) grep -q '"size_kb":1024' "$ROOT/$scenario.json" ;;
    zero) grep -q '"size_kb":0' "$ROOT/$scenario.json" ;;
  esac
  printf 'PASS worktree size: %s\n' "$scenario"
done
printf 'Fixtures: %s\n' "$ROOT"
