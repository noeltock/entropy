#!/bin/bash
# lib.sh - fixture for the entropy evals. Source it; do not run it.
# Everything happens under one temp root. Nothing here touches the real home folder, real
# processes, Docker or launchd: ENTROPY_* variables point the script at the fixture, and
# shims in $BIN hide everything else. Bash 3.2 compatible.

EVALS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL_DIR=$(cd "$EVALS_DIR/.." && pwd)
SCRIPT_REAL=$SKILL_DIR/scripts/entropy.sh
CULPRITS_REAL=$SKILL_DIR/references/culprits.tsv

FX_MARKER=""
FX_KEEP=${FX_KEEP:-}

fx_file() { # path size_kb: a file of real (non-sparse) bytes
  mkdir -p "$(dirname "$1")"
  dd if=/dev/zero of="$1" bs=1024 count="$2" 2>/dev/null
}

fx_age() { # path: make everything under it look old (2026-01-01)
  find "$1" -exec touch -t 202601010000 {} + 2>/dev/null
}

fx_git() { git -c user.name=fx -c user.email=fx@example.invalid -c init.defaultBranch=main "$@"; }

fx_create() { # creates the root and exports the environment; no processes yet
  ROOT=$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/entropy-eval.XXXXXX")" && pwd)
  touch "$ROOT/.entropy-eval-fixture"
  FX_MARKER="entropyfx$$x$RANDOM"
  TREE=$ROOT/tree; H=$TREE/home; TMPFX=$TREE/tmp; OUTSIDE=$ROOT/outside
  STATE=$ROOT/state; BIN=$ROOT/bin; ORIGIN=$ROOT/origin; OUT=$ROOT/out
  mkdir -p "$H" "$TMPFX" "$OUTSIDE" "$STATE" "$BIN" "$ORIGIN" "$OUT"
  local s
  for s in ps pgrep launchctl docker lsof; do ln -s "$EVALS_DIR/shims/$s" "$BIN/$s"; done
  ENTROPY_EVAL_REALPATH=$PATH
  export ENTROPY_EVAL_REALPATH
  PATH=$BIN:$PATH
  export PATH
  export ENTROPY_HOME=$H ENTROPY_TMP_ROOT=$TMPFX ENTROPY_DOCKER_DIR=$H/Library/Containers/com.docker.docker
  export ENTROPY_REPOS_DIR=$H/dev ENTROPY_WORKTREE_DIRS=$H/.codex/worktrees
  export ENTROPY_CULPRITS=$CULPRITS_REAL ENTROPY_NO_HISTORY=1 ENTROPY_MIN_MB=0 ENTROPY_MIN_PROC_AGE=0
  export ENTROPY_FX_MARKER=$FX_MARKER
  export LC_ALL=en_US.UTF-8 COLUMNS=220
  unset ENTROPY_ASCII ENTROPY_CULPRITS_EXTRA ENTROPY_CULPRITS_DATA ENTROPY_HOST ENTROPY_STATE_DIR
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
}

fx_build() { # disk content: caches, user data, Docker Desktop, scratch, repos and worktrees
  local d
  # caches (sizes differ so the ranking is stable)
  fx_file "$H/.npm/_cacache/content-v2/blob" 3072
  fx_file "$H/Library/pnpm/store/v3/blob" 2048
  fx_file "$H/.cache/uv/wheels/blob" 1024
  fx_file "$H/.cache/puppeteer/chrome/blob" 512
  fx_file "$H/Library/Caches/Yarn/v6/blob" 40
  # decoy: a cache location that is a symlink to data outside the fixture tree
  fx_file "$OUTSIDE/precious/irreplaceable.db" 256
  mkdir -p "$H/.bun/install"
  ln -s "$OUTSIDE/precious" "$H/.bun/install/cache"
  # user data
  fx_file "$H/backups/photos-2019.tar" 4096
  fx_file "$H/.Trash/old-download.zip" 1024
  # Docker Desktop disk, app not running
  fx_file "$ENTROPY_DOCKER_DIR/Data/vms/0/data/Docker.raw" 2048
  # old agent scratch, an old browser session file and a stale MCP browser profile
  fx_file "$TMPFX/claude-501/-fx-proj/oldsession/notes.txt" 300
  fx_file "$H/.agent-browser/old.config" 4
  fx_file "$H/Library/Caches/ms-playwright/mcp-chrome-abc/Default/Cookies" 300
  for d in "$TMPFX/claude-501" "$H/.agent-browser" "$H/Library/Caches/ms-playwright"; do fx_age "$d"; done
  # git: one repo with a pushed main, four linked worktrees, one broken worktree
  mkdir -p "$H/dev/alpha" "$H/dev/alpha-wt" "$H/.codex/worktrees/ab12/broken"
  fx_git init -q -b main --bare "$ORIGIN/alpha.git"
  fx_git init -q -b main "$H/dev/alpha"
  echo one > "$H/dev/alpha/file.txt"
  fx_git -C "$H/dev/alpha" add file.txt
  fx_git -C "$H/dev/alpha" commit -q -m one
  fx_git -C "$H/dev/alpha" remote add origin "$ORIGIN/alpha.git"
  fx_git -C "$H/dev/alpha" push -q origin main 2>/dev/null
  fx_git -C "$H/dev/alpha" fetch -q origin
  for d in clean dirty unpushed live; do
    fx_git -C "$H/dev/alpha" worktree add -q -b "wt-$d" "$H/dev/alpha-wt/$d" main
    eval "WT_$(printf '%s' "$d" | tr a-z A-Z)=\$H/dev/alpha-wt/$d"
  done
  echo changed >> "$WT_DIRTY/file.txt"
  echo two > "$WT_UNPUSHED/two.txt"
  fx_git -C "$WT_UNPUSHED" add two.txt
  fx_git -C "$WT_UNPUSHED" commit -q -m two
  echo "gitdir: $ROOT/does-not-exist/.git/worktrees/broken" > "$H/.codex/worktrees/ab12/broken/.git"
  WT_BROKEN=$H/.codex/worktrees/ab12/broken
  for d in "$H/dev/alpha" "$WT_CLEAN" "$WT_DIRTY" "$WT_UNPUSHED" "$WT_LIVE"; do
    fx_git -C "$d" status --porcelain >/dev/null 2>&1   # settle git's index refresh before anything is checksummed
  done
}

fx_pid() { # tag -> pid of the fixture process with that tag
  local i p
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    p=$(/bin/ps -Ao pid=,command= | awk -v m="$FX_MARKER $1 " 'index($0,m){print $1; exit}')
    [ -n "$p" ] && { echo "$p"; return 0; }
    sleep 0.25
  done
  return 1
}

# A dummy process is `sleep 600` with argv[0] rewritten to "<marker> <tag> <words>", so it looks like the
# real tool to ps but cannot do anything, and it ends by itself after ten minutes.
fx_spawn_child() { # tag words...: child of this shell, working directory $FX_CWD (default /)
  local tag=$1; shift
  ( cd "${FX_CWD:-/}" && exec -a "$FX_MARKER $tag $*" sleep 600 ) </dev/null >/dev/null 2>&1 &
  disown $! 2>/dev/null
}

fx_spawn_orphan() { # tag words...: adopted by launchd (parent 1) because the subshell that started it exits
  local tag=$1; shift
  ( ( exec -a "$FX_MARKER $tag $*" sleep 600 ) </dev/null >/dev/null 2>&1 & )
}

fx_spawn() { # chrome, a live and an orphaned MCP server, an editor working inside a worktree
  fx_spawn_child chrome "Google Chrome for Testing --headless=new"
  fx_spawn_child mcp-alive "node /opt/x/mcp-server-alive"
  fx_spawn_orphan mcp-orphan "node /opt/x/mcp-server-orphan"
  FX_CWD=$WT_LIVE fx_spawn_child live-editor "vim file.txt"
  PID_CHROME=$(fx_pid chrome) && PID_MCP_ALIVE=$(fx_pid mcp-alive) && PID_MCP_ORPHAN=$(fx_pid mcp-orphan) && PID_LIVE=$(fx_pid live-editor) || return 1
  FX_PIDS="$PID_CHROME $PID_MCP_ALIVE $PID_MCP_ORPHAN $PID_LIVE"
  printf '%s\n' $FX_PIDS > "$ROOT/pids"
  sleep 2   # entropy.sh reads process age in whole seconds; a process under one second old breaks its row (see README)
}

fx_checksum() { # names, contents and symlink targets of everything the script could touch
  ( cd "$ROOT" && {
      find tree outside -type f -exec shasum {} +
      find tree outside -print
      find tree outside -type l -exec readlink {} \;
    } 2>&1 | shasum | awk '{print $1}' )
}

fx_kill_pids() { # only pids that still carry the marker (or the canary marker) in their command line
  local p f
  for f in "$ROOT/pids" "$ROOT/canary.pid"; do
    [ -f "$f" ] || continue
    for p in $(cat "$f"); do
      /bin/ps -o command= -p "$p" 2>/dev/null | grep -q -e "entropyfx" -e "entropycanary" && kill "$p" 2>/dev/null
    done
  done
  return 0
}

fx_cleanup() { # kill own fixture processes, then remove the temp root (marker file required)
  fx_kill_pids
  [ -n "$FX_KEEP" ] && { echo "fixture kept: $ROOT" >&2; return 0; }
  case "$ROOT" in
    */entropy-eval.??????) [ -f "$ROOT/.entropy-eval-fixture" ] && rm -rf -- "$ROOT" ;;
  esac
  return 0
}

# ---- reading results (no jq needed) ----

# json_rows <file> items|held: TSV of id, category, key, what, size_kb, count, age_s, owner, priority, action, target, breaks
json_rows() {
  awk -v sect="$2" -v nxt="$([ "$2" = items ] && echo held || echo notes)" '
    function get(o, k,   v) { if (!match(o, "\"" k "\":(\"[^\"]*\"|[^,}]*)")) return ""
      v = substr(o, RSTART + length(k) + 3, RLENGTH - length(k) - 3)
      if (substr(v, 1, 1) == "\"") v = substr(v, 2, length(v) - 2)
      return v }
    { line = $0; a = index(line, "\"" sect "\":["); if (!a) exit
      line = substr(line, a + length(sect) + 4)
      e = index(line, "],\"" nxt "\":["); if (e) line = substr(line, 1, e - 1)
      while (match(line, /\{"id":[^{}]*\}/)) {
        o = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
        id = get(o, "id"); if (id == "null") id = "-"
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", id, get(o,"category"), get(o,"key"), get(o,"what"), get(o,"size_kb"), get(o,"count"), get(o,"age_s"), get(o,"owner"), get(o,"priority"), get(o,"action"), get(o,"target"), get(o,"breaks") } }' "$1"
}

# grid_rows <table file>: TSV of id, marker (G worth doing, D ask first, L low value), what, do, for every table row (held rows have do=keep)
grid_rows() {
  # markers are mapped to letters with sed first: the system awk cannot tell multibyte characters apart
  sed -e 's/●/G/' -e 's/◆/D/' -e 's/○/L/' -e "s/│/$(printf '\t')/g" "$1" | awk -F'\t' '
    function trim(s) { gsub(/^ +| +$/, "", s); return s }
    /^ / && NF >= 9 && $1 ~ /^ *$/ {
      id = trim($2); if (id == "ID") next
      m = trim($3); if (m == "") m = "-"
      print id "\t" m "\t" trim($4) "\t" trim($8) }'
}

run_ts() { sed -n 's/^  ENTROPY  run \([0-9]*\) .*/\1/p' "$1" | head -1; }
