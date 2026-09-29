#!/bin/bash
# test_triage.sh - layer A: deterministic checks of what entropy.sh marks selectable, held or ask-first.
# No network, no LLM. Builds a fixture under mktemp -d, runs the script against it, asserts on the result.
#
#   test_triage.sh            run the cases
#   test_triage.sh --mutate   also run each safety case against a deliberately broken copy of the script
#                             (copies live in the temp root; the real script is never edited) and require it to fail
#   FX_KEEP=1                 keep the fixture folder for inspection
#
# Exit status: 0 when every case passed (and every mutation was caught, with --mutate).

. "$(dirname "$0")/lib.sh"

MUTATE=""; MUT_ONLY=${MUT_ONLY:-}
for a in "$@"; do case "$a" in --mutate) MUTATE=1 ;; *) echo "test_triage: unknown option $a" >&2; exit 2 ;; esac; done

[ "$(uname)" = Darwin ] || { echo "test_triage: macOS only (same as entropy.sh)" >&2; exit 2; }
START=$(date +%s)
fx_create
trap fx_cleanup EXIT
trap 'exit 130' INT TERM
fx_build
fx_spawn || { echo "test_triage: could not start the fixture processes" >&2; exit 2; }
echo "fixture: $ROOT (removed on exit)"

# ---- scans: one run of the script under test per named scenario ----
SCRIPT=$SCRIPT_REAL
PFX=""

scan_run() { # name: run $SCRIPT for that scenario; output to $OUT/$PFX<name>.out / .err
  local n=$1 st=$STATE/$PFX$1 o=$OUT/$PFX$1
  mkdir -p "$st"
  case $n in
    base_table)  ENTROPY_STATE_DIR=$st bash "$SCRIPT" --held ;;
    base_json)   ENTROPY_STATE_DIR=$st bash "$SCRIPT" --json ;;
    age10)       ENTROPY_STATE_DIR=$st ENTROPY_MIN_PROC_AGE=10 bash "$SCRIPT" --json ;;
    lsof_empty)  ENTROPY_STATE_DIR=$st ENTROPY_FX_LSOF=empty bash "$SCRIPT" --json ;;
    small_table) ENTROPY_STATE_DIR=$st ENTROPY_MIN_MB=1 bash "$SCRIPT" ;;
    all_table)   ENTROPY_STATE_DIR=$st ENTROPY_MIN_MB=1 bash "$SCRIPT" --all ;;
    deep_ro)     ENTROPY_STATE_DIR=$st bash "$SCRIPT" --deep --all --held ;;
  esac > "$o.out" 2> "$o.err"
  echo $? > "$o.rc"
}
scan() { local n; for n in "$@"; do scan_run "$n" & done; wait; }
f() { echo "$OUT/$PFX$1.out"; }

# ---- assertions ----
FAILMSG=""
fail() { FAILMSG="$FAILMSG    - $1"$'\n'; }
col() { awk -F'\t' -v c="$1" '{print $c}'; }
has_line() { grep -qF -- "$1"; }

# ---- cases ----

# 1a: worktrees. Only the clean, pushed, unused one is selectable; dirty, unpushed, in-use and unreadable ones are held with the right reason.
case_1a() {
  local items held p reason
  items=$(json_rows "$(f base_json)" items); held=$(json_rows "$(f base_json)" held)
  [ -n "$items" ] || fail "no items parsed from base_json (script failed? see $(f base_json))"
  printf '%s\n' "$items" | awk -F'\t' -v p="$WT_CLEAN" '$3=="wt:alpha" && $1!="-" && $11==p {f=1} END{exit !f}' ||
    fail "the selectable wt:alpha row is not exactly the clean worktree (a held one may have leaked in)"
  for p in "$WT_DIRTY:uncommitted changes" "$WT_UNPUSHED:commits not on any remote" "$WT_LIVE:in use by" "$WT_BROKEN:unreadable"; do
    reason=${p#*:}; p=${p%%:*}
    printf '%s\n' "$items" | col 11 | has_line "$p" && fail "held worktree ${p##*/} appears in a selectable row's target"
    printf '%s\n' "$held" | awk -F'\t' -v p="$p" -v r="$reason" '$11==p && $1=="-" && index($4,r) {f=1} END{exit !f}' ||
      fail "worktree ${p##*/} is not held with reason '$reason'"
  done
}

# 1b: when lsof gives nothing, live use cannot be checked, so nothing is offered (fail closed).
case_1b() {
  local items
  items=$(json_rows "$(f lsof_empty)" items)
  printf '%s\n' "$items" | awk -F'\t' '$3 ~ /^wt:/ {f=1} END{exit f}' || fail "worktrees are still selectable when the live-use check is unavailable"
  json_rows "$(f lsof_empty)" held | col 4 | has_line "live-use check unavailable" || fail "clean worktree not held as 'live-use check unavailable' without lsof"
}

# 2: the Docker Desktop disk is ask-first with the migrate verb, never worth-doing or low-value; the Docker rows are ask-first too.
case_2() {
  local g r
  g=$(grid_rows "$(f base_table)")
  r=$(printf '%s\n' "$g" | awk -F'\t' 'index($3,"Docker Desktop disk")')
  [ -n "$r" ] || fail "no Docker Desktop disk row in the table"
  [ "$(printf '%s' "$r" | col 2)" = D ] || fail "Docker Desktop disk marker is '$(printf '%s' "$r" | col 2)', expected ◆ (D)"
  [ "$(printf '%s' "$r" | col 4)" = migrate ] || fail "Docker Desktop disk DO is '$(printf '%s' "$r" | col 4)', expected migrate"
  printf '%s\n' "$g" | awk -F'\t' 'index($3,"images + build cache") && $2!="D" {b=1} END{exit b}' || fail "Docker reclaimable row is not ask-first (◆)"
}

# 3: user data (backups, Trash) is ask-first with the ask verb.
case_3() {
  local g w r
  g=$(grid_rows "$(f base_table)")
  for w in "backup folder" "Trash"; do
    r=$(printf '%s\n' "$g" | awk -F'\t' -v w="$w" '$3==w')
    [ -n "$r" ] || { fail "no '$w' row in the table"; continue; }
    [ "$(printf '%s' "$r" | col 2)" = D ] || fail "'$w' marker is '$(printf '%s' "$r" | col 2)', expected ◆ (D)"
    [ "$(printf '%s' "$r" | col 4)" = ask ] || fail "'$w' DO is '$(printf '%s' "$r" | col 4)', expected ask"
  done
}

# 4: process age threshold and orphan detection.
case_4() {
  local young items mcp
  young=$(json_rows "$(f age10)" items | col 11 | tr ' |' '\n\n')
  printf '%s\n' "$young" | grep -qx "$PID_CHROME" && fail "chrome younger than ENTROPY_MIN_PROC_AGE=10 minutes is still offered"
  json_rows "$(f age10)" items | col 3 | has_line proc:chrome-for-testing && fail "a chrome row exists at MIN_PROC_AGE=10 with only young processes"
  grep -qF "young agent processes skipped" "$(f age10)" || fail "the skipped-young note is missing at MIN_PROC_AGE=10"
  items=$(json_rows "$(f base_json)" items)
  printf '%s\n' "$items" | awk -F'\t' -v p="$PID_CHROME" '$3=="proc:chrome-for-testing" && index(" " $11 " ", " " p " ") {f=1} END{exit !f}' ||
    fail "chrome is not offered at MIN_PROC_AGE=0"
  mcp=$(printf '%s\n' "$items" | awk -F'\t' '$3=="proc:mcp-orphans"')
  [ -n "$mcp" ] || { fail "no orphaned MCP row"; return; }
  [ "$(printf '%s' "$mcp" | col 11)" = "$PID_MCP_ORPHAN" ] || fail "MCP row target is '$(printf '%s' "$mcp" | col 11)', expected only the orphan $PID_MCP_ORPHAN (live one is $PID_MCP_ALIVE)"
  printf '%s' "$mcp" | col 8 | has_line "parent gone" || fail "orphan is not flagged 'parent gone'"
}

# 5: containment. Every selectable row points inside the fixture tree (symlinks resolved) or at a fixture process.
case_5() {
  local rows row id key act tgt t real ok
  [ -L "$H/.bun/install/cache" ] || fail "fixture broken: the decoy symlink is missing"
  rows=$(json_rows "$(f base_json)" items)
  [ -n "$rows" ] || fail "no items parsed from base_json"
  printf '%s\n' "$rows" | while IFS=$'\t' read -r id _ key _ _ _ _ _ _ act tgt _; do
    [ "$id" = "-" ] && continue
    case "$key" in
      proc:*) for t in $tgt; do case " $FX_PIDS " in *" $t "*) ;; *) echo "$id $key pid $t is not a fixture process" ;; esac; done ;;
      docker:reclaimable|docker:running) case "$tgt" in docker\ *) ;; *) echo "$id $key target '$tgt' is not a docker command" ;; esac ;;
      *) echo "$tgt" | tr '|' '\n' | while IFS= read -r t; do
           [ -L "$t" ] && { echo "$id $key target ${t#$TREE/} is a symlink"; continue; }
           if [ -d "$t" ]; then real=$(cd -P "$t" && pwd); else real=$(cd -P "$(dirname "$t")" 2>/dev/null && pwd)/$(basename "$t"); fi
           case "$real" in "$TREE"/*) ;; *) echo "$id $key target ${t#$TREE/} is a symlink or resolves outside the fixture tree" ;; esac
         done ;;
    esac
  done > "$OUT/${PFX}c5.txt"
  while IFS= read -r row; do fail "$row"; done < "$OUT/${PFX}c5.txt"
}

# 6: read-only. The fixture tree (contents, names, symlink targets) is identical before and after a full run.
case_6() {
  local before after
  before=$(fx_checksum)
  scan deep_ro
  after=$(fx_checksum)
  grep -q '^  ENTROPY  run' "$(f deep_ro)" || fail "the run produced no table, so the checksum comparison proves nothing (see $(f deep_ro).err)"
  [ "$before" = "$after" ] || fail "the fixture tree changed during a run of the script"
}

# 7: --json parses, has no '?', and its IDs are the grid's IDs; the run file in runs/ holds the same IDs.
case_7() {
  local j=$(f base_json) t=$(f base_table) ts gids jids rids rfile
  plutil -convert json -o /dev/null "$j" >/dev/null 2>&1 || fail "--json output does not parse (plutil)"
  if command -v jq >/dev/null 2>&1; then jq -e . "$j" >/dev/null 2>&1 || fail "--json output does not parse (jq)"; fi
  grep -q '?' "$j" && fail "--json output contains a '?'"
  gids=$(grid_rows "$t" | awk -F'\t' '$4!="keep" && $1!="-" {print $1}')
  jids=$(json_rows "$j" items | awk -F'\t' '$1!="-" {print $1}')
  [ -n "$jids" ] || fail "no IDs in --json"
  [ "$gids" = "$jids" ] || fail "table IDs ($(echo $gids)) differ from --json IDs ($(echo $jids))"
  ts=$(run_ts "$t"); rfile=$STATE/${PFX}base_table/runs/$ts.json
  [ -f "$rfile" ] || { fail "run file runs/$ts.json was not written"; return; }
  rids=$(json_rows "$rfile" items | awk -F'\t' '$1!="-" {print $1}')
  [ "$rids" = "$gids" ] || fail "run file IDs ($(echo $rids)) differ from the table IDs ($(echo $gids))"
  # the IDs must also mean the same thing: what the table shows for an ID is what the run file says it is
  paste <(grid_rows "$t" | awk -F'\t' '$4!="keep" {print $1 "\t" $4}') <(json_rows "$rfile" items | awk -F'\t' '{print $1 "\t" $10}') |
    awk -F'\t' '$1!=$3 {print "ID " $1 " vs " $3; b=1} END{exit b}' >/dev/null || fail "IDs are in a different order in the run file than in the table"
}

# 8: tiny items are hidden (and get no ID) without --all, shown with it.
case_8() {
  local hidden shown
  grid_rows "$(f small_table)" | awk -F'\t' '$3=="Yarn cache" {f=1} END{exit f}' || fail "a 40 KB row is shown without --all at ENTROPY_MIN_MB=1"
  grep -q 'small items' "$(f small_table)" || fail "the '+ N small items' footer is missing without --all"
  grid_rows "$(f small_table)" | awk -F'\t' '$3=="npm package cache" {f=1} END{exit !f}' || fail "the 3 MB npm row is missing at ENTROPY_MIN_MB=1"
  shown=$(grid_rows "$(f all_table)" | awk -F'\t' '$3=="Yarn cache" && $1 ~ /^E[0-9]+$/ {f=1} END{exit !f}' && echo yes)
  [ "$shown" = yes ] || fail "--all does not show the 40 KB row with an ID"
}

CASES="1a 1b 2 3 4 5 6 7 8"
NEEDS_BASE="base_table base_json age10 lsof_empty small_table all_table"

run_cases() { # sets RESULT_<case>: PASS or the failure text
  local c
  for c in "$@"; do
    FAILMSG=""
    "case_$c"
    if [ -z "$FAILMSG" ]; then eval "RESULT_$c=PASS"; else eval "RESULT_$c=\$FAILMSG"; fi
  done
}

desc() {
  case $1 in
    1a) echo "worktrees: clean selectable; dirty, unpushed, in-use, unreadable held" ;;
    1b) echo "worktrees held when lsof is unavailable (fail closed)" ;;
    2) echo "Docker Desktop disk is ask-first (migrate), never worth-doing" ;;
    3) echo "backups and Trash are ask-first (ask)" ;;
    4) echo "process min age respected; orphan flagged 'parent gone'" ;;
    5) echo "containment: selectable rows stay inside the fixture" ;;
    6) echo "read-only: fixture checksum identical after a full run" ;;
    7) echo "--json parses, no '?', IDs match grid and run file" ;;
    8) echo "tiny items hidden without --all, shown with it" ;;
  esac
}

echo "running scans (each is one run of the script against the fixture)..."
scan $NEEDS_BASE
run_cases $CASES

FAILED=0
echo
echo "Layer A: triage tests"
for c in $CASES; do
  eval "r=\$RESULT_$c"
  if [ "$r" = PASS ]; then printf '  PASS  %-3s %s\n' "$c" "$(desc $c)"
  else printf '  FAIL  %-3s %s\n%s\n' "$c" "$(desc $c)" "$r"; FAILED=$((FAILED + 1)); fi
done

# ---- mutations: prove the safety cases bite ----
subst() { # file old new: literal, first-occurrence replace; aborts when the text is not found (a stale mutation proves nothing)
  OLD=$2 NEW=$3 perl -0777 -pi -e 'BEGIN { $o = $ENV{OLD}; $n = $ENV{NEW} } $c += s/\Q$o\E/$n/; END { exit($c ? 0 : 3) }' "$1" ||
    { echo "mutation target not found in $1: $2" >&2; exit 2; }
}

mutate() { # id case description scan-names -- edits (via functions below)
  local id=$1 c=$2 what=$3 scans=$4 dir=$ROOT/mut/$1 r
  mkdir -p "$dir"
  cp "$SCRIPT_REAL" "$dir/entropy.sh"
  cp "$CULPRITS_REAL" "$dir/culprits.tsv"
  "mut_$id" "$dir/entropy.sh" "$dir/culprits.tsv"
  MUT_RESULT_FILE=$dir/result
  (
    SCRIPT=$dir/entropy.sh; PFX=${id}_; ENTROPY_CULPRITS=$dir/culprits.tsv; export ENTROPY_CULPRITS
    [ "$scans" = - ] || scan $scans
    FAILMSG=""; "case_$c"
    printf '%s' "$FAILMSG" > "$dir/result"
  )
}

mut_1a() { subst "$1" 'if ($4==1) why=why "uncommitted changes, "; else if' 'if (0) why=why "uncommitted changes, "; else if'; }
mut_1b() { subst "$1" 'if ($5==1) why=why "commits not on any remote, "' 'if (0) why=why "commits not on any remote, "'; }
mut_1c() { subst "$1" 'if ($6!="-") why=why' 'if (0) why=why'; }
mut_1d() { subst "$1" '[ -n "$NOCWD" ] && live="live-use check unavailable"' ':'; }
mut_1e() { subst "$1" 'else if ($4=="?") why=why "git status unreadable, "' ''; }
mut_2() {
  subst "$1" 'f[11]=="inspect-and-ask" || ' ''
  subst "$1" ' || doverb(f)=="migrate") return "D"' ') return "D"'
  subst "$1" 'not in use (app not running, engine: ${ctx:-unknown}) [may hold unmigrated volumes]" "$kb" 0 "$age" "Docker Desktop" ask "inspect-and-ask"' 'not in use (app not running, engine: ${ctx:-unknown}) [may hold unmigrated volumes]" "$kb" 0 "$age" "Docker Desktop" normal "path"'
}
mut_3() { awk -F'\t' -v OFS='\t' '$2=="backups"||$2=="trash"{$3="caches"; $6="path"; $7="normal"} {print}' "$2" > "$2.new" && mv "$2.new" "$2"; }
mut_4() { subst "$1" '[ -n "$p" ] && [ ! -L "$p" ] || continue' '[ -n "$p" ] || continue'; }
mut_5() { subst "$1" '  render
}' "  render
  rm -f \"$H/backups/photos-2019.tar\"
}"; }

if [ -n "$MUTATE" ]; then
  echo
  echo "Mutations: each safety case must FAIL on a copy of the script with its guard removed"
  MUTS="1a:1a:worktree dirty guard removed:base_json
1b:1a:worktree unpushed guard removed:base_json
1c:1a:worktree in-use guard removed:base_json
1e:1a:unreadable-worktree guard removed:base_json
1d:1b:lsof-unavailable guard removed:lsof_empty
2:2:Docker Desktop disk treated as an ordinary cache:base_table
3:3:backups and Trash treated as ordinary caches:base_table
4:5:symlink guard on cache paths removed:base_json
5:6:script deletes a fixture file after rendering:-"
  echo "$MUTS" > "$ROOT/muts"
  while IFS=: read -r id c what scans; do [ -z "$MUT_ONLY" ] || [ "$MUT_ONLY" = "$id" ] || continue; mutate "$id" "$c" "$what" "$scans" & done < "$ROOT/muts"
  wait
  printf '  %-4s %-4s %-52s %s\n' mut case mutation result
  while IFS=: read -r id c what scans; do
    [ -z "$MUT_ONLY" ] || [ "$MUT_ONLY" = "$id" ] || continue
    r=$(cat "$ROOT/mut/$id/result" 2>/dev/null)
    if [ -n "$r" ]; then printf '  %-4s %-4s %-52s CAUGHT (%s)\n' "$id" "$c" "$what" "$(printf '%s' "$r" | head -1 | sed 's/^ *- //' | cut -c1-90)"
    else printf '  %-4s %-4s %-52s MISSED: the test still passes on the broken copy\n' "$id" "$c" "$what"; FAILED=$((FAILED + 1)); fi
  done < "$ROOT/muts"
fi

echo
echo "elapsed: $(( $(date +%s) - START ))s"
if [ $FAILED -eq 0 ]; then echo "LAYER A: PASS"; else echo "LAYER A: FAIL ($FAILED)"; exit 1; fi
