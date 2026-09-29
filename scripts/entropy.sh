#!/usr/bin/env bash
# entropy.sh - read-only triage of agent and developer mess on a Mac.
# Prints one ranked, padded-grid table. It never kills, stops, moves or deletes anything.
#
#   entropy.sh [--json] [--deep] [--held] [--all] [--host <ssh-host>]
#
# Detection is data-driven: process and path signatures live in
# ../references/culprits.tsv, so new culprits need no code change.
# Bash 3.2 compatible (the macOS system bash). No dependencies beyond macOS.

# ===== DEFAULTS: every machine-specific value is here; override with env vars =====
: "${ENTROPY_HOME:=$HOME}"                                # base for ~ in the culprit table and for the defaults below (tests point it at a fixture)
: "${ENTROPY_TMP_ROOT:=/private/tmp}"                     # replaces /private/tmp in culprit paths (agent scratch lives under it)
: "${ENTROPY_DOCKER_DIR:=$ENTROPY_HOME/Library/Containers/com.docker.docker}"  # Docker Desktop data folder
: "${ENTROPY_REPOS_DIR:=$ENTROPY_HOME/dev}"                              # parent folder of your git repos (one level down)
: "${ENTROPY_WORKTREE_DIRS:=$ENTROPY_HOME/.codex/worktrees}"     # extra folders whose children are git worktrees (colon-separated)
: "${ENTROPY_HOST:=}"                                    # ssh host used by a bare --host
: "${ENTROPY_STATE_DIR:=$ENTROPY_HOME/.local/state/entropy}"     # history.jsonl and last.json live here
: "${ENTROPY_CULPRITS:=}"                                # culprit table (default: ../references/culprits.tsv)
: "${ENTROPY_CULPRITS_EXTRA:=}"                          # optional file of extra culprit rows, same columns
: "${ENTROPY_ASCII:=}"                                   # set to 1 for + - | borders (automatic when the locale is not UTF-8)
: "${ENTROPY_STALE_DAYS:=1}"                             # "stale" process = running this many days
: "${ENTROPY_LAUNCH_RUNS:=100}"                          # launch agent with this many starts and a non-zero exit is flagged
: "${ENTROPY_LISTEN_IGNORE:=^/(System|usr|sbin|bin|Applications|Library/Apple)/}"  # listener executables to ignore
: "${ENTROPY_WT_BUDGET:=12}"                             # seconds allowed for the worktree scan
: "${ENTROPY_PATH_BUDGET:=12}"                           # seconds allowed for sizing cache and scratch paths
: "${ENTROPY_MIN_MB:=50}"                                # disk rows smaller than this are summarised in one footer line (--all shows them)
: "${ENTROPY_MIN_PROC_AGE:=10}"                          # minutes: younger browser/agent processes are skipped as likely in use
: "${ENTROPY_NO_HISTORY:=}"                              # set to 1 to skip writing history.jsonl
# ===== end of defaults =====

TAB=$(printf '\t')
SELF=$0

if command -v timeout >/dev/null 2>&1; then TMO=timeout
elif command -v gtimeout >/dev/null 2>&1; then TMO=gtimeout
else TMO=""; fi

# T <seconds> <command...>: run a command with a hard time limit.
T() {
  local s=$1
  shift
  if [ -n "$TMO" ]; then "$TMO" "$s" "$@"; else perl -e 'alarm shift; exec @ARGV' "$s" "$@"; fi
}

clean() { printf '%s' "$1" | tr '\t\n\r"\\' '      '; }
note() { printf '%s\n' "$1" >> "$W/notes"; }
mach() { printf '%s\t%s\n' "$1" "$2" >> "$W/machine.tsv"; }
etime_s() {
  awk -v e="$1" 'BEGIN{d=0; if(index(e,"-")){split(e,p,"-"); d=p[1]; e=p[2]} n=split(e,q,":"); if(n==3)s=q[1]*3600+q[2]*60+q[3]; else s=q[1]*60+q[2]; print d*86400+s}'
}
owner_of() { # pid -> project folder name from the process's working directory
  local c
  c=$(awk -F'\t' -v p="$1" '$1==p{print $3; exit}' "$W/cwds.tsv" 2>/dev/null)
  case "$c" in ""|"/") printf '%s' "-" ;; *) basename "$c" ;; esac
}

# emit <tier> <category> <key> <what> <size_kb> <count> <age_s> <owner> <priority> <action> <target> <breaks>
# tier: 0 exposed, 1 running now, 2 disk, 3 low-priority disk, 5 deep scan, 9 held
emit() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$2" "$(clean "$3")" "$(clean "$4")" "${5:--1}" "${6:-0}" "${7:--1}" \
    "$(clean "${8:--}")" "$9" "$(clean "${10:--}")" "$(clean "${11:--}")" "$(clean "${12:--}")" >> "$OUT"
}

# cul <kind> <id> <fieldno>: one field of a culprit row, "-" when empty
cul() { awk -F'\t' -v k="$1" -v i="$2" -v f="$3" '$1==k&&$2==i{v=$f; if(v=="")v="-"; print v; exit}' "$CUL"; }

# ---------- machine state ----------
phase_machine() {
  local cores l1 l5 l15 sw sw_total sw_used boot now disk vol spot
  now=$(date +%s)
  mach host "$(hostname -s)"
  mach os "$(sw_vers -productVersion 2>/dev/null)"
  cores=$(T 5 sysctl -n hw.ncpu 2>/dev/null)
  if [ -z "$cores" ]; then note "sysctl not responding: the machine may be starved of memory (a hang is itself a finding)"; return; fi
  mach cores "$cores"
  read -r _ l1 l5 l15 _ <<EOF
$(T 5 sysctl -n vm.loadavg 2>/dev/null)
EOF
  mach load1 "${l1:-0}"
  mach load_ratio "$(awk -v l="${l1:-0}" -v c="$cores" 'BEGIN{printf "%.2f", l/c}')"
  sw=$(T 5 sysctl -n vm.swapusage 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="total")t=$(i+2); if($i=="used")u=$(i+2)} gsub("M","",t); gsub("M","",u); print t+0, u+0}')
  sw_total=${sw%% *}; sw_used=${sw##* }
  mach swap_total_mb "${sw_total:-0}"
  mach swap_used_mb "${sw_used:-0}"
  mach swap_pct "$(awk -v t="${sw_total:-0}" -v u="${sw_used:-0}" 'BEGIN{if(t>0)printf "%.0f", u*100/t; else print 0}')"
  boot=$(T 5 sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p')
  [ -n "$boot" ] && mach uptime_days "$(awk -v n="$now" -v b="$boot" 'BEGIN{printf "%.1f", (n-b)/86400}')"
  vol=/System/Volumes/Data; [ -d "$vol" ] || vol=/
  disk=$(df -k "$vol" 2>/dev/null | awk 'NR==2{print $3, $4}')
  mach disk_free_kb "${disk##* }"
  mach disk_used_pct "$(awk -v u="${disk%% *}" -v a="${disk##* }" 'BEGIN{if(u+a>0)printf "%.0f", u*100/(u+a); else print 0}')"
  spot=$(T 5 mdutil -s "$vol" 2>&1 | awk 'NR>1{gsub(/^[ \t]+|[ \t.]+$/,""); print; exit}')
  mach spotlight "${spot:-unknown}"
  ps -Ao pcpu=,comm= | awk '{p=$1; sub(/^ *[0-9.]+ +/,""); path=$0; i=index(path,".app/");
      if(i>0){n=substr(path,1,i+3); sub(/.*\//,"",n); sub(/\.app$/,"",n)} else {n=path; sub(/.*\//,"",n)}
      c[n]+=p} END{for(k in c) if(c[k]>=5) printf "%s\t%.0f\n", k, c[k]}' |
    sort -t "$TAB" -k2,2nr | head -5 | while IFS="$TAB" read -r app pc; do mach topcpu "$app$TAB$pc"; done
}

# ---------- agent processes (from the culprit table) ----------
PROC_AWK='
function secs(e,   d,p,n,q,s) { d=0; if (index(e,"-")) { split(e,p,"-"); d=p[1]; e=p[2] } n=split(e,q,":"); if (n==3) s=q[1]*3600+q[2]*60+q[3]; else s=q[1]*60+q[2]; return d*86400+s }
function mine(pid,   p,d) { p=pid; for (d=0; d<40 && p>1; d++) { if (p==self) return 1; p=pp[p] } return 0 }
function tree(root, r,   qh,qt,q,cur,n,ka,i,k,j) {
  qh=1; qt=1; q[1]=root; inr[r,root]=1
  while (qh<=qt) { cur=q[qh]; qh++; n=split(kids[cur], ka, " ")
    for (i=1;i<=n;i++) { k=ka[i]; if (inr[r,k] || ((k in claim) && claim[k]!=r)) continue; inr[r,k]=1; qt++; q[qt]=k } }
  for (j=qt; j>=1; j--) { k=q[j]; cnt[r]++; rss[r]+=prss[k]; pids[r]=pids[r] " " k; if (page[k]>maxage[r]) maxage[r]=page[k] }
  if (!(r in best) || page[root]>page[best[r]]) best[r]=root
}
BEGIN { FS="\t" }
FNR==NR { if ($1=="proc") { nr++; rid[nr]=$2; rcat[nr]=$3; rlabel[nr]=$4; rmatch[nr]=$5; rwhen[nr]=$6; rprio[nr]=$7; rbreaks[nr]=$8 } next }
{
  if (!match($0, /^ *[0-9]+ +[0-9]+ +[^ ]+ +[0-9]+ +[0-9.]+ +/)) next
  split(substr($0,1,RLENGTH), f, " "); cmd=substr($0,RLENGTH+1)
  pid=f[1]; np++; order[np]=pid; pp[pid]=f[2]; page[pid]=secs(f[3]); prss[pid]=f[4]; pcmd[pid]=cmd
  kids[f[2]]=kids[f[2]] " " pid
}
END {
  for (i=1;i<=np;i++) { pid=order[i]
    for (r=1;r<=nr;r++) {
      if (pcmd[pid] !~ rmatch[r]) continue
      if (rwhen[r]=="orphan" && pp[pid]!=1) continue
      if (rwhen[r]=="stale" && page[pid]<stale) continue
      if (rwhen[r]=="any" && rprio[r]!="expose" && page[pid]<minage) { if (!mine(pid)) young++; break }
      if (mine(pid)) break
      claim[pid]=r; break } }
  for (i=1;i<=np;i++) { pid=order[i]
    if (!(pid in claim)) continue
    r=claim[pid]; if ((pp[pid] in claim) && claim[pp[pid]]==r) continue
    tree(pid, r) }
  if (young>0) print "YOUNG\t" young
  for (r=1;r<=nr;r++) if (cnt[r]>0) {
    b=rbreaks[r]; if (b=="") b="-"
    print rid[r] "\t" rcat[r] "\t" rlabel[r] "\t" rprio[r] "\t" b "\t" cnt[r] "\t" rss[r] "\t" maxage[r] "\t" best[r] "\t" (pp[best[r]]==1 ? "1" : "0") "\t" substr(pids[r],2) }
}'

phase_procs() {
  OUT=$W/i.procs
  awk -v self=$$ -v stale=$((ENTROPY_STALE_DAYS * 86400)) -v minage=$((ENTROPY_MIN_PROC_AGE * 60)) "$PROC_AWK" "$CUL" "$W/ps.snap" |
    while IFS="$TAB" read -r id cat label prio breaks cnt rss age root orph pids; do
      local owner tier=1
      if [ "$id" = YOUNG ]; then note "$cat young agent processes skipped (<${ENTROPY_MIN_PROC_AGE}m, likely in use)"; continue; fi
      owner=$(owner_of "$root")
      [ "$orph" = 1 ] && owner="$owner (parent gone)"
      [ "$prio" = expose ] && tier=0
      emit "$tier" "$cat" "proc:$id" "$label ($cnt process(es))" "$rss" "$cnt" "$age" "$owner" "$prio" "kill-tree" "$pids" "$breaks"
    done
}

# ---------- launch agents that keep restarting ----------
phase_launch() {
  OUT=$W/i.launch
  local uid
  uid=$(id -u)
  T 5 launchctl list 2>/dev/null |
    awk -F'\t' 'NR>1 && $2!="0" && $3!~/^(com\.apple\.|application\.|0x)/ {print $3 "\t" $1}' |
    while IFS="$TAB" read -r label pid; do
      local info runs code path age=-1
      info=$(T 3 launchctl print "gui/$uid/$label" 2>/dev/null) || continue
      runs=$(printf '%s\n' "$info" | awk '$1=="runs"&&$2=="="{print $3; exit}')
      [ "${runs:-0}" -ge "$ENTROPY_LAUNCH_RUNS" ] 2>/dev/null || continue
      code=$(printf '%s\n' "$info" | awk '/last exit code =/{print $NF; exit}')
      path=$(printf '%s\n' "$info" | sed -n 's/^[[:space:]]*path = //p' | head -1)
      if [ "$pid" != "-" ]; then age=$(etime_s "$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"); fi
      emit 1 "launch agents" "launch:$label" "launch agent $label started $runs times, last exit $code" -1 "$runs" "$age" "$label" normal \
        "launchctl bootout gui/$uid/$label; move the plist aside" "$label|$path" "that background job stops and will not start at login"
    done
}

# ---------- listeners reachable from other devices ----------
phase_listen() {
  OUT=$W/i.listen
  T 5 lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null |
    awk 'NR>1 { n=$9; if (n ~ /^(127\.0\.0\.1|\[::1\]|localhost)/) next; print $2 "\t" $1 "\t" n }' | sort -u |
    awk -F'\t' '{a[$1]=a[$1] (a[$1] ? "," : "") $3; c[$1]=$2} END{for (k in a) print k "\t" c[k] "\t" a[k]}' |
    while IFS="$TAB" read -r pid comm addrs; do
      local exe age=-1
      exe=$(ps -o comm= -p "$pid" 2>/dev/null)
      [ -n "$exe" ] || continue
      printf '%s' "$exe" | grep -Eq "$ENTROPY_LISTEN_IGNORE" && continue
      age=$(etime_s "$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')")
      emit 0 "network exposure" "listen:$comm:$addrs" "$comm (pid $pid) listening on $addrs, reachable from other devices" -1 1 "$age" "$(owner_of "$pid")" expose \
        "kill-tree" "$pid" "whatever that server was serving stops"
    done
}

# ---------- Docker ----------
sz2kb() { awk -v s="$1" 'BEGIN{n=s+0; u=s; sub(/^[0-9.]+/,"",u); m=1; if(u~/^[kK]/)m=1000/1024; else if(u~/^M/)m=1000*1000/1024; else if(u~/^G/)m=1000*1000*1000/1024; else if(u~/^T/)m=1000*1000*1000*1000/1024; else m=1/1024; printf "%d", n*m}'; }

phase_docker() {
  OUT=$W/i.docker
  local ctx running dd kb raw mt age proj oldest
  command -v docker >/dev/null 2>&1 && ctx=$(T 5 docker context show 2>/dev/null)
  if command -v docker >/dev/null 2>&1; then
    if T 5 docker info --format '{{.ID}}' >/dev/null 2>&1; then
      running=$(T 5 docker ps -q 2>/dev/null | wc -l | tr -d ' ')
      if [ "${running:-0}" -gt 0 ]; then
        proj=$(T 5 docker ps --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | sort -u | grep -v '^$' | head -3 | tr '\n' ',' | sed 's/,$//')
        oldest=$(T 5 docker ps --format '{{.CreatedAt}}' 2>/dev/null | sort | head -1)
        age=-1
        [ -n "$oldest" ] && age=$(( $(date +%s) - $(date -j -f "%Y-%m-%d %H:%M:%S %z" "$(printf '%s' "$oldest" | awk '{print $1" "$2" "$3}')" +%s 2>/dev/null || date +%s) ))
        emit 1 "docker" "docker:running" "$running containers running on $ctx" -1 "$running" "$age" "${proj:--}" ask \
          "inspect-and-ask" "docker ps" "stopping them stops those services; check what they serve first"
      fi
      kb=$(T 10 docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>/dev/null | awk -F'|' '$1=="Images"||$1=="Build Cache"{split($2,a," "); print a[1]}' |
        while read -r s; do sz2kb "$s"; echo; done | awk '{t+=$1} END{print t+0}')
      [ "${kb:-0}" -gt 0 ] && emit 2 "docker" "docker:reclaimable" "Docker ($ctx) reports reclaimable images and build cache, volumes excluded (layers are shared, so this overlaps)" "$kb" 0 -1 "${ctx:--}" ask \
        "inspect-and-ask" "docker system df -v" "never prune automatically; volumes can hold databases"
    else
      note "docker: not responding (engine: ${ctx:-unknown}). Start the engine and re-run to see containers and reclaimable space."
    fi
  fi
  dd=$ENTROPY_DOCKER_DIR
  if [ -d "$dd" ]; then
    kb=$(T 15 du -sk "$dd" 2>/dev/null | awk '{print $1}')
    raw="$dd/Data/vms/0/data/Docker.raw"; [ -e "$raw" ] || raw=$dd
    if [ -z "$kb" ] && [ "$raw" != "$dd" ]; then
      kb=$(T 15 du -sk "$raw" 2>/dev/null | awk '{print $1}')
      [ -n "$kb" ] && note "Docker Desktop folder sizing timed out; the size is Docker.raw alone"
    fi
    mt=$(stat -f %m "$raw" 2>/dev/null); age=-1; [ -n "$mt" ] && age=$(( $(date +%s) - mt ))
    if [ -n "$kb" ]; then
      if pgrep -f 'com.docker.backend' >/dev/null 2>&1; then
        emit 2 "docker" "docker:desktop-disk" "Docker Desktop disk image (app running, engine: $ctx)" "$kb" 0 "$age" "Docker Desktop" ask "inspect-and-ask" "$dd" "holds every Docker Desktop container, image and volume"
      else
        emit 2 "docker" "docker:desktop-disk" "Docker Desktop disk image, not in use (app not running, engine: ${ctx:-unknown}) [may hold unmigrated volumes]" "$kb" 0 "$age" "Docker Desktop" ask "inspect-and-ask" "$dd" "holds every Docker Desktop container, image and volume; check for data first"
      fi
    else
      note "not measured: $dd (timeout or no permission)"
    fi
  fi
}

# ---------- caches, scratch and other fixed paths (from the culprit table) ----------
size_job() { # "<id><TAB><path>" -> id, KiB, mtime, path
  local id=${1%%$'\t'*} p=${1#*$'\t'} k m
  if [ -n "${PATH_DEADLINE:-}" ] && [ "$(date +%s)" -ge "$PATH_DEADLINE" ]; then printf '%s\t?\t0\t%s\n' "$id" "$p"; return 0; fi
  k=$(T 20 du -sk "$p" 2>/dev/null | awk '{print $1}')
  m=$(stat -f %m "$p" 2>/dev/null)
  printf '%s\t%s\t%s\t%s\n' "$id" "${k:-?}" "${m:-0}" "$p"
}

phase_paths() {
  OUT=$W/i.paths
  local jobs=$W/path.jobs now
  now=$(date +%s)
  : > "$jobs"
  awk -F'\t' '$1=="path"{print $2 "\t" $5 "\t" $9}' "$CUL" |
    while IFS="$TAB" read -r id globs minage; do
      local -a gl
      IFS='|' read -ra gl <<EOF
$globs
EOF
      local g p out m
      for g in "${gl[@]}"; do
        g=${g/#\~/$ENTROPY_HOME}
        g=${g/#\/private\/tmp/$ENTROPY_TMP_ROOT}
        while IFS= read -r p; do
          [ -n "$p" ] && [ ! -L "$p" ] || continue
          if [ "${minage:-0}" -gt 0 ] 2>/dev/null; then
            if [ -d "$p" ]; then
              out=$(T 3 find "$p" -mtime "-$minage" -print -quit 2>/dev/null) || continue
              [ -n "$out" ] && continue
            else
              m=$(stat -f %m "$p" 2>/dev/null || echo "$now")
              [ $((now - m)) -lt $((minage * 86400)) ] && continue
            fi
          fi
          printf '%s\t%s\n' "$id" "$p" >> "$jobs"
        done <<EOF
$(compgen -G "$g")
EOF
      done
    done
  [ -s "$jobs" ] || return 0
  PATH_DEADLINE=$(( $(date +%s) + ENTROPY_PATH_BUDGET )); export PATH_DEADLINE
  tr '\n' '\0' < "$jobs" | nice -n 10 xargs -0 -n1 -P6 bash -c 'size_job "$0"' > "$W/path.sizes"
  awk -F'\t' '$2=="?"{u[$1]++; up[$1]=$4; next}
    {cnt[$1]++; kb[$1]+=$2; if ($3>mt[$1]) mt[$1]=$3; tg[$1]=tg[$1] (tg[$1] ? "|" : "") $4}
    END{for (k in u) print "UNM\t" k "\t" u[k] "\t" up[k]
      for (k in cnt) print k "\t" cnt[k] "\t" kb[k] "\t" mt[k] "\t" tg[k]}' "$W/path.sizes" |
    while IFS="$TAB" read -r id cnt kb mt tg; do
      if [ "$id" = UNM ]; then
        if [ "$kb" -gt 1 ]; then note "not measured: $kb $cnt paths (timeout, budget or no permission), e.g. $mt"; else note "not measured: $mt (timeout, budget or no permission)"; fi
        continue
      fi
      local cat label arg prio breaks tier=2 what
      cat=$(cul path "$id" 3); label=$(cul path "$id" 4); arg=$(cul path "$id" 6); prio=$(cul path "$id" 7); breaks=$(cul path "$id" 8)
      [ "$prio" = low ] && tier=3
      what=$label; [ "$cnt" -gt 1 ] && what="$label [$cnt items]"
      emit "$tier" "$cat" "path:$id" "$what" "$kb" "$cnt" "$((now - mt))" "$id" "$prio" "$arg" "$tg" "$breaks"
    done
}

# ---------- git worktrees with dirty / unpushed / in-use state ----------
inspect_wt() { # "<path><TAB><repo>" -> repo, path, KiB, dirty, unpushed, live, mtime, branch
  local path=${1%%$'\t'*} repo=${1#*$'\t'} kb st n rc dirty unp live mt br
  [ -d "$path" ] || return 0
  if [ "$(date +%s)" -ge "$WT_DEADLINE" ]; then printf 'SKIP\t%s\t%s\n' "$repo" "$path"; return 0; fi
  kb=$(T 6 du -sk "$path" 2>/dev/null | awk '{print $1}'); kb=${kb:-?}
  st=$(T 5 git -C "$path" status --porcelain 2>/dev/null); rc=$?
  if [ $rc -ne 0 ]; then dirty='?'; elif [ -n "$st" ]; then dirty=1; else dirty=0; fi
  n=$(T 5 git -C "$path" rev-list --count HEAD --not --remotes 2>/dev/null); rc=$?
  if [ $rc -ne 0 ]; then unp='?'; elif [ "${n:-0}" -gt 0 ]; then unp=1; else unp=0; fi
  live=$(awk -F'\t' -v p="$path" '$3==p||index($3,p "/")==1{print $2 "(" $1 ")"; exit}' "$W/cwds.tsv")
  [ -n "$NOCWD" ] && live="live-use check unavailable"
  [ -n "$live" ] || live=$(grep -F -- "$path" "$W/ps.snap" | head -1 | awk '{print "pid " $1}')
  mt=$(stat -f %m "$path" 2>/dev/null)
  br=$(T 3 git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" "$path" "$kb" "$dirty" "$unp" "${live:--}" "${mt:-0}" "${br:--}"
}

phase_worktrees() {
  OUT=$W/i.wt
  local list=$W/wt.list now r d c
  now=$(date +%s)
  : > "$list"
  for r in "$ENTROPY_REPOS_DIR"/*/; do
    [ -d "${r}.git" ] || continue
    T 5 git -C "$r" worktree list --porcelain 2>/dev/null |
      awk -v repo="$(basename "$r")" '/^worktree /{n++; if (n>1) print substr($0,10) "\t" repo}' >> "$list"
  done
  local -a dirs
  IFS=':' read -ra dirs <<EOF
$ENTROPY_WORKTREE_DIRS
EOF
  for d in "${dirs[@]}"; do
    for c in "$d"/*/ "$d"/*/*/; do
      c=${c%/}
      [ -f "$c/.git" ] || continue
      printf '%s\t%s\n' "$c" "$(basename "$c")" >> "$list"
    done
  done
  sort -u -t "$TAB" -k1,1 "$list" -o "$list"
  [ -s "$list" ] || return 0
  WT_DEADLINE=$(( now + ENTROPY_WT_BUDGET )); export WT_DEADLINE
  tr '\n' '\0' < "$list" | nice -n 10 xargs -0 -n1 -P6 bash -c 'inspect_wt "$0"' > "$W/wt.out"
  awk -F'\t' -v now="$now" -v minkb="$([ -n "$ALL" ] && echo 0 || echo $((ENTROPY_MIN_MB * 1024)))" '
    $1=="SKIP" {skip++; next}
    { k="other"; if (index($2,"/.codex/worktrees/")) k="codex"; else if (index($2,"/.claude/worktrees/")) k="claude"
      why=""
      if ($4==1) why=why "uncommitted changes, "; else if ($4=="?") why=why "git status unreadable, "
      if ($5==1) why=why "commits not on any remote, "; else if ($5=="?") why=why "push state unknown, "
      if ($6!="-") why=why ($6 ~ /unavailable/ ? $6 : "in use by " $6) ", "
      if (why=="") { c[$1]++; if ($3=="?") uns[$1]++; else kb[$1]+=$3; kc[$1,k]++; if ($7>mt[$1]) mt[$1]=$7; tg[$1]=tg[$1] (tg[$1] ? "|" : "") $2 }
      else { sub(/, $/,"",why); print "HELD\t" $1 "\t" $2 "\t" $3 "\t" why "\t" $7 "\t" $8 } }
    END { if (skip>0) print "SKIPPED\t" skip
      for (r in c) if (minkb>0 && uns[r]==0 && kb[r]<minkb) sn++
      for (r in c) {
        if (sn>=2 && minkb>0 && uns[r]==0 && kb[r]<minkb) { sc+=c[r]; skb+=kb[r]; if (mt[r]>smt) smt=mt[r]; stg=stg (stg ? "|" : "") tg[r]; continue }
        print "CLEAN\t" r "\t" c[r] "\t" kb[r] "\t" mt[r] "\t" kc[r,"codex"]+0 "\t" kc[r,"claude"]+0 "\t" kc[r,"other"]+0 "\t" uns[r]+0 "\t" tg[r] }
      if (sn>=2) print "SMALL\t" sn "\t" sc "\t" skb "\t" smt "\t" stg }' "$W/wt.out" |
    while IFS="$TAB" read -r kind a b c2 d2 e f g h i; do
      case "$kind" in
        SKIPPED) note "worktrees not inspected before the ${ENTROPY_WT_BUDGET}s budget ran out: $a (run again, or raise ENTROPY_WT_BUDGET)" ;;
        HELD) emit 9 "agent worktrees" "wt:$b" "$a/$f worktree kept: $d2" "$c2" 1 "$((now - e))" "$a" held - "$b" - ;;
        SMALL) emit 2 "agent worktrees" "wt:_small" "$b worktrees across $a repos" "$c2" "$b" "$((now - d2))" small normal "git worktree remove (per path, clean and pushed only)" "$e" "worktree folders and their build output are removed; the branches and pushed commits stay" ;;
        CLEAN)
          local what="$b clean, pushed worktree(s) of $a (codex $e, claude $f, other $g)"
          [ "$h" -gt 0 ] && what="$what, $h not sized"
          emit 2 "agent worktrees" "wt:$a" "$what" "$c2" "$b" "$((now - d2))" "$a" normal "git worktree remove (per path, clean and pushed only)" "$i" "worktree folders and their build output are removed; the branches and pushed commits stay" ;;
      esac
    done
}

# ---------- deep scan (opt-in, slow, own time limits) ----------
phase_deep() {
  OUT=$W/i.deep
  local now vol cat kb name
  now=$(date +%s)
  T 60 find "$ENTROPY_REPOS_DIR" -maxdepth 4 -name node_modules -type d -prune 2>/dev/null > "$W/nm.list"
  if [ -s "$W/nm.list" ]; then
    awk '{print "nm\t" $0}' "$W/nm.list" | tr '\n' '\0' | nice -n 10 xargs -0 -n1 -P6 bash -c 'size_job "$0"' 2>/dev/null |
      awk -F'\t' '$2!="?" && $2>204800' | sort -t "$TAB" -k2,2nr | head -10 |
      while IFS="$TAB" read -r _ kb mt p; do
        local proj live prio=ask
        proj=$(basename "$(dirname "$p")")
        live=$(awk -F'\t' -v p="$(dirname "$p")" 'index($3,p "/")==1||$3==p{print $2 "(" $1 ")"; exit}' "$W/cwds.tsv")
        [ -n "$live" ] && prio=held
        emit "$([ "$prio" = held ] && echo 9 || echo 5)" "deep: node_modules" "deep:nm:$p" "node_modules in $proj${live:+ (in use by $live)} (info only)" "$kb" 1 "$((now - mt))" "$proj" "$prio" - "$p" "never removed by this skill; reinstall with the project's package manager"
      done
  fi
  local d
  for d in "$ENTROPY_HOME/Library/Application Support|deep: app data" "$ENTROPY_HOME/Library/Caches|deep: app caches"; do
    cat=${d#*|}; d=${d%|*}
    [ -d "$d" ] || continue
    T 60 du -k -d 1 "$d" 2>/dev/null | awk -F'\t' -v d="$d" '$2!=d && $1>512000' | sort -t "$TAB" -k1,1nr | head -8 |
      while IFS="$TAB" read -r kb p; do
        name=$(basename "$p")
        emit 5 "$cat" "deep:$cat:$name" "$name (review only: app-owned data)" "$kb" 1 -1 "$name" ask - "$p" "app data or caches owned by that app; may hold accounts or local databases"
      done
  done
  if [ -d "$ENTROPY_HOME/Downloads" ]; then
    kb=$(T 30 du -sk "$ENTROPY_HOME/Downloads" 2>/dev/null | awk '{print $1}')
    [ "${kb:-0}" -gt 512000 ] && emit 5 "deep: your files" "deep:downloads" "Downloads folder (review only: your files)" "$kb" 1 -1 "Downloads" ask - "$ENTROPY_HOME/Downloads" "your own files"
  fi
  local snaps
  snaps=$(T 10 tmutil listlocalsnapshots /System/Volumes/Data 2>/dev/null | grep -c 'com.apple')
  note "local Time Machine snapshots: ${snaps:-0} (macOS reclaims these itself when space is needed; sizes cannot be read cheaply)"
}

# ---------- ranking, rendering, history ----------
render() {
  local now hist=$ENTROPY_STATE_DIR/history.jsonl tz off f
  now=$(date +%s)
  RUN_TS=$now
  tz=$(date +%z); off=$(( 10#${tz:1:2} * 3600 + 10#${tz:3:2} * 60 )); [ "${tz:0:1}" = "-" ] && off=$((-off))
  MINKB=$((ENTROPY_MIN_MB * 1024)); [ -n "$ALL" ] && MINKB=0
  cat "$W"/i.* 2>/dev/null > "$W/items.tsv"
  : > "$W/hist.keys"
  if [ -f "$hist" ]; then
    awk -v off="$off" -v now="$now" 'BEGIN { td=int((now+off)/86400) }
      match($0, /"ts":[0-9]+/) { t=substr($0, RSTART+5, RLENGTH-5)+0 }
      match($0, /"key":"[^"]*"/) { d=int((t+off)/86400); if (d<td) print substr($0, RSTART+7, RLENGTH-8) "\t" d }' "$hist" | sort -u | cut -f1 > "$W/hist.keys"
  fi
  awk -F'\t' -v OFS='\t' -v minkb="$MINKB" '{ un=0; if ($5=="?") { $5=-1; un=1 }
      hid=0; if ($1!=9 && $5>=0 && $5<minkb && $3 !~ /^(proc|launch|listen):/) hid=1
      sec=9
      if ($1!=9) { if ($3 ~ /^listen:/) sec=8; else if ($1==0) sec=0; else if ($3 ~ /^proc:/) sec=1; else if ($3 ~ /^launch:/) sec=2; else if ($2=="docker") sec=3
        else if ($2=="agent worktrees") sec=5; else if ($2=="agent scratch") sec=6; else sec=4 }
      print sec, ($5>=0 ? 0 : 1), ($5>=0 ? $5 : $6), $0, un, hid }' "$W/items.tsv" |
    sort -t "$TAB" -k1,1n -k2,2n -k3,3nr -k6,6 |
    awk -F'\t' -v OFS='\t' 'FILENAME==ARGV[1] {seen[$1]++; next}
      { id="-"; if ($4!=9 && $6 !~ /^listen:/ && $17!=1) { n++; id="E" n }
        print id, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, seen[$6]+0, $1, $16, $17 }' "$W/hist.keys" - > "$W/ranked.tsv"

  awk -F'\t' -v host="$(hostname -s)" -v ts="$now" '
    function j(s) { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return "\"" s "\"" }
    function num(s) { return (s ~ /^-?[0-9.]+$/) ? s : j(s) }
    FILENAME ~ /machine.tsv$/ { if ($1=="topcpu") { ntc++; tca[ntc]=$2; tcp[ntc]=$3; next } m[++nm]=$1; mv[nm]=$2; next }
    FILENAME ~ /notes$/ { nn++; notes[nn]=$0; next }
    { row=sprintf("{\"id\":%s,\"category\":%s,\"key\":%s,\"what\":%s,\"size_kb\":%s,\"count\":%s,\"age_s\":%s,\"owner\":%s,\"priority\":%s,\"action\":%s,\"target\":%s,\"breaks\":%s,\"seen_before\":%s}",
        ($1=="-" ? "null" : j($1)), j($3), j($4), j($5), $6, $7, $8, j($9), j($10), j($11), j($12), j($13), $14)
      if ($2==9) { nh++; held[nh]=row } else { ni++; item[ni]=row } }
    END {
      printf "{\"host\":%s,\"ts\":%s,\"machine\":{", j(host), ts
      for (i=1;i<=nm;i++) printf "%s%s:%s", (i>1?",":""), j(m[i]), (m[i]=="host"||m[i]=="os"||m[i]=="spotlight") ? j(mv[i]) : num(mv[i])
      printf "},\"top_cpu\":["
      for (i=1;i<=ntc;i++) printf "%s{\"app\":%s,\"pcpu\":%s}", (i>1?",":""), j(tca[i]), tcp[i]
      printf "],\"items\":["
      for (i=1;i<=ni;i++) printf "%s%s", (i>1?",":""), item[i]
      printf "],\"held\":["
      for (i=1;i<=nh;i++) printf "%s%s", (i>1?",":""), held[i]
      printf "],\"notes\":["
      for (i=1;i<=nn;i++) printf "%s%s", (i>1?",":""), j(notes[i])
      printf "]}\n" }' "$W/machine.tsv" "$W/notes" "$W/ranked.tsv" > "$W/out.json"
  mkdir -p "$ENTROPY_STATE_DIR/runs"
  cp "$W/out.json" "$ENTROPY_STATE_DIR/runs/$now.json"
  cp "$W/out.json" "$ENTROPY_STATE_DIR/last.json"
  ls -1 "$ENTROPY_STATE_DIR/runs" | sort -r | tail -n +21 | while read -r f; do rm -f "$ENTROPY_STATE_DIR/runs/$f"; done

  if [ -z "$ENTROPY_NO_HISTORY" ]; then
    awk -F'\t' -v ts="$now" -v host="$(hostname -s)" '{printf "{\"ts\":%s,\"host\":\"%s\",\"key\":\"%s\",\"cat\":\"%s\",\"size_kb\":%s,\"count\":%s}\n", ts, host, $4, $3, $6, $7}' "$W/ranked.tsv" >> "$hist"
  fi

  if [ -n "$JSON" ]; then cat "$W/out.json"; return; fi
  render_table
}

render_table() {
  local asc=0 cols n=0 nrows=0 nheld=0 kind a b c d e f g h i
  [ "$ENTROPY_ASCII" = 1 ] && asc=1
  case "$(locale charmap 2>/dev/null)" in UTF-8) ;; *) asc=1 ;; esac
  cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 100)}

  awk -F'\t' -v OFS='\t' -v asc="$asc" -v run="$RUN_TS" -v host="$(hostname -s)" '
    function hs(kb) { if (kb<0) return DASH; if (kb>=1073741824) return sprintf("%.1fT", kb/1073741824); if (kb>=104857600) return sprintf("%.0fG", kb/1048576); if (kb>=1048576) return sprintf("%.1fG", kb/1048576); if (kb>=1024) return sprintf("%.0fM", kb/1024); return kb "K" }
    function gib(kb) { if (kb>=1048576) return sprintf("%.0f GiB", kb/1048576); return sprintf("%.0f MiB", kb/1024) }
    function ha(s,  d) { if (s<0) return DASH; if (s>=86400) { d=int(s/86400); if (d>=365) return int(d/365) "y"; if (d>=100) return int(d/30) "mo"; return d "d" } if (s>=3600) return int(s/3600) "h"; return int(s/60) "m" }
    function shortlab(id, fb) {
      if (id=="chrome-for-testing") return "headless Chrome"
      if (id=="agent-browser") return "agent-browser daemons"
      if (id=="codex-broker") return "Codex review brokers"
      if (id=="mcp-orphans") return "orphaned MCP servers"
      if (id=="dev-servers") return "stale dev servers"
      if (id=="http-server") return "static file servers"
      if (id=="tunnels") return "public tunnels"
      sub(/ \(.*$/, "", fb); return fb }
    function lports(w,   s, n, a, i, p, ports) {
        s=w; sub(/^.* listening on /,"",s); sub(/, reachable.*$/,"",s); n=split(s,a,","); ports=""
        for (i=1;i<=n;i++) { p=a[i]; sub(/^.*:/,"",p); if (index("," ports ",", "," p ",")==0) ports=ports (ports?",":"") ":" p }
        return ports }
    function what(f,   w, k, id, lab, nm) {
      w=f[5]; k=f[4]
      if (k ~ /^proc:/) { id=substr(k,6); lab=shortlab(id, w); if (f[9] ~ /parent gone/) nm="orphaned"; else nm=f[9]
        return f[7] TIMES " " lab ((nm!="-" && nm!="") ? " " DOT " " nm : "") }
      if (k ~ /^launch:/) return "restarting launch agent " DOT " " f[9]
      if (k=="docker:running") return f[7] " containers running" ((f[9]!="-") ? " " DOT " " f[9] : "")
      if (k=="docker:reclaimable") return f[9] " images + build cache"
      if (k=="docker:desktop-disk") return "Docker Desktop disk " DOT " " ((w ~ /not in use/) ? "not in use" : "app running")
      if (k=="wt:_small") return f[5] " " DOT " small"
      if (k ~ /^wt:/) return f[7] " worktree" (f[7]==1 ? "" : "s") " " DOT " " f[9]
      if (k ~ /^deep:/ && w ~ /review only/) { sub(/ \(review only: /," " DOT " review only, ",w); sub(/\)$/,"",w); return w }
      sub(/ \[[0-9]+ items\]$/,"",w)
      return w }
    function doverb(f,  k) { k=f[4]
      if (f[2]==0) return "stop"
      if (k ~ /^proc:/) return "kill"
      if (k ~ /^launch:/) return "bootout"
      if (k=="docker:desktop-disk") return (f[5] ~ /not in use/) ? "migrate" : "ask"
      if (k=="docker:reclaimable") return "prune"
      if (k=="docker:running") return "ask"
      if (k ~ /^wt:/) return "remove"
      if (k ~ /^deep:/) return "ignore?"
      if (f[10]=="ask" || f[11]=="-") return "ask"
      if (f[11]=="path") return "remove"
      return "clean" }
    function marker(f,  kb) { kb=f[6]+0
      if (f[2]==0) return "G"
      if (f[10]=="ask" || f[11]=="inspect-and-ask" || f[3]=="user data" || doverb(f)=="migrate") return "D"
      if (f[4] ~ /^(proc|launch):/) return "G"
      if (f[10]=="low" || (kb>=0 && kb<524288)) return "L"
      return "G" }
    FILENAME ~ /machine.tsv$/ { if ($1=="topcpu") { top=top (top?" | ":"") $2 " " $3 "%"; next } M[$1]=$2; next }
    FILENAME ~ /notes$/ { print "NOTE", $0; next }
    { rows++; r[rows]=$0 }
    END {
      DASH=asc ? "-" : "–"; DOT=asc ? "-" : "·"; TIMES=asc ? "x" : "×"
      up="?"; if (M["uptime_days"]!="") up=(M["uptime_days"]<1) ? int(M["uptime_days"]*24) "h" : int(M["uptime_days"]) "d"
      print "HDR", (M["disk_used_pct"]!="" ? M["disk_used_pct"] : "?"), (M["swap_pct"]!="" ? M["swap_pct"] : "?"), sprintf("%.1f", M["load_ratio"]), up, host, run
      w=""
      if (M["load_ratio"]>1.5) w=w "load is over 1.5x the core count; "
      if (M["swap_pct"]>50) w=w "swap over half used (a reboot clears it); "
      if (M["uptime_days"]>7) w=w "uptime over 7 days; "
      if (M["disk_free_kb"]!="" && M["disk_free_kb"]<15728640) w=w "under 15 GiB free; "
      if (w!="") print "WATCH", substr(w,1,length(w)-2)
      if (top!="") print "TOP", top
      for (i=1;i<=rows;i++) { split(r[i], f, "\t")
        if (f[4] ~ /^proc:/) { np=split(f[12], pl, " "); for (t=1;t<=np;t++) pidrow[pl[t]]=i } }
      for (i=1;i<=rows;i++) { split(r[i], f, "\t")
        if (f[4] ~ /^listen:/) { split(f[4], kk, ":"); pt=lports(f[5])
          if (f[12] in pidrow) tag[pidrow[f[12]]]=tag[pidrow[f[12]]] (tag[pidrow[f[12]]] ? "," : "") substr(pt,1)
          else also=also (also ? ", " : "") kk[2] " " pt } }
      for (i=1;i<=rows;i++) { split(r[i], f, "\t")
        if (f[4] ~ /^listen:/) continue
        if (f[17]==1) { nsmall++; smallkb+=(f[6]>0 ? f[6] : 0); continue }
        if (f[2]==9) { nheld++; heldkb+=(f[6]>0 ? f[6] : 0)
          w=f[5]; sub(/ worktree kept: /," " DOT " ",w)
          print "HELD", 9, DASH, "-", w, (f[16]==1 ? "?" : hs(f[6])), ha(f[8]), DASH, "keep"; continue }
        m=marker(f); kb=f[6]+0
        if (m=="D") ask+=(kb>0 ? kb : 0); else if (f[4] !~ /^proc:/) safe+=(kb>0 ? kb : 0)
        if (m=="G" && kb>0) { cand++; ck[cand]=kb; ci[cand]=f[1] }
        print "ROW", f[15], f[1], m, (tag[i] ? "LAN " tag[i] " " DOT " " : "") what(f), (f[16]==1 ? "?" : hs(f[6])), ha(f[8]), (f[14]>0 ? (f[14]>99 ? 99 : f[14]) : DASH), doverb(f) }
      if (also!="") print "NOTE", "also listening on LAN: " also
      pick=""
      for (t=1;t<=3;t++) { b=0; for (i=1;i<=cand;i++) if (ck[i]>0 && (b==0 || ck[i]>ck[b])) b=i
        if (b==0) break; pick=pick (pick?" ":"") ci[b]; ck[b]=-1 }
      print "SUM", gib(safe), gib(ask), nheld+0, gib(heldkb), (pick!="" ? pick : "-"), nsmall+0, gib(smallkb)
    }' "$W/machine.tsv" "$W/notes" "$W/ranked.tsv" > "$W/grid.tsv"

  case "$cols" in ''|*[!0-9]*) cols=100 ;; esac

  local TL TM TR ML MM MR BL BM BR H V ELL GD GG GL
  if [ $asc = 1 ]; then TL=+ TM=+ TR=+ ML=+ MM=+ MR=+ BL=+ BM=+ BR=+ H=- V='|' ELL='..' GD='?' GG='*' GL='o'
  else TL=┌ TM=┬ TR=┐ ML=├ MM=┼ MR=┤ BL=└ BM=┴ BR=┘ H=─ V=│ ELL='…' GD=◆ GG=● GL=○; fi

  local -a K SC ID MK WH SZ AG XX DO NOTES
  local disk="?" swap="?" load="?" up="?" host="" run="" watch="" top="" safe=0 ask=0 heldkb=0 pick="-" nn=0 nsmall=0 smallkb=0
  while IFS="$TAB" read -r kind a b c d e f g h; do
    case "$kind" in
      HDR) disk=$a swap=$b load=$c up=$d host=$e run=$f ;;
      WATCH) watch=$a ;;
      TOP) top=$a ;;
      NOTE) nn=$((nn + 1)); NOTES[nn]=$a ;;
      SUM) safe=$a ask=$b nheld=$c heldkb=$d pick=$e nsmall=$f smallkb=$g ;;
      ROW|HELD)
        [ "$kind" = HELD ] && [ -z "$HELD" ] && continue
        n=$((n + 1)); K[n]=$kind; SC[n]=$a; ID[n]=$b; MK[n]=$c; WH[n]=$d; SZ[n]=$e; AG[n]=$f; XX[n]=$g; DO[n]=$h
        [ "$kind" = ROW ] && nrows=$((nrows + 1)) ;;
    esac
  done < "$W/grid.tsv"

  local idw=3 whw=4 j len
  for ((j = 1; j <= n; j++)); do
    [ ${#ID[j]} -gt $idw ] && idw=${#ID[j]}
    [ ${#WH[j]} -gt $whw ] && whw=${#WH[j]}
  done
  local avail=$((cols - 57 - idw))
  [ $whw -gt $avail ] && whw=$avail
  [ $whw -lt 24 ] && whw=24
  local tw=$((idw + whw + 57))
  local -a cw
  cw=("" $((idw + 4)) 5 $((whw + 4)) 9 8 6 12)

  local D S OUT
  printf -v D '%*s' 300 ''; D=${D// /$H}
  rule() { # left mid right
    local k
    OUT=" $1"
    for ((k = 1; k <= 7; k++)); do OUT="$OUT${D:0:${cw[k]}}"; [ $k -lt 7 ] && OUT="$OUT$2"; done
    printf '%s%s\n' "$OUT" "$3"
  }
  cl() { local g=$(($2 - ${#1})); [ $g -lt 0 ] && g=0; printf -v S '%*s' "$g" ''; OUT="$OUT  $1$S  $V"; }
  cr() { local g=$(($2 - ${#1})); [ $g -lt 0 ] && g=0; printf -v S '%*s' "$g" ''; OUT="$OUT  $S$1  $V"; }
  gline() { # id marker what size age x do
    local w=$3 m=$2
    [ ${#w} -gt $whw ] && w="${w:0:$((whw - ${#ELL}))}$ELL"
    case "$m" in D) m=$GD ;; G) m=$GG ;; L) m=$GL ;; -) m=" " ;; esac
    OUT=" $V"; cl "$1" $idw; cl "$m" 1; cl "$w" $whw; cr "$4" 5; cr "$5" 4; cr "$6" 2; cl "$7" 8
    printf '%s\n' "$OUT"
  }
  grid() { # ROW or HELD
    local want=$1 prev="" first=1
    rule "$TL" "$TM" "$TR"
    OUT=" $V"; cl ID $idw; cl "" 1; cl WHAT $whw; cr SIZE 5; cr AGE 4; cr "$XS" 2; cl DO 8; printf '%s\n' "$OUT"
    for ((j = 1; j <= n; j++)); do
      [ "${K[j]}" = "$want" ] || continue
      if [ $first = 0 ] && [ "${SC[j]}" != "$prev" ]; then rule "$ML" "$MM" "$MR"
      elif [ $first = 1 ]; then rule "$ML" "$MM" "$MR"; fi
      first=0; prev=${SC[j]}
      gline "${ID[j]}" "${MK[j]}" "${WH[j]}" "${SZ[j]}" "${AG[j]}" "${XX[j]}" "${DO[j]}"
    done
    rule "$BL" "$BM" "$BR"
  }
  local XS='×'; [ $asc = 1 ] && XS=x

  local left sepd='·'; [ $asc = 1 ] && sepd='-'
  left="  ENTROPY  run ${run}  $sepd  disk ${disk}%  $sepd  swap ${swap}%  $sepd  load ${load}${XS}  $sepd  up ${up}  $sepd  ${SECONDS}s"
  local gap=$((tw - ${#left} - ${#host}))
  [ $gap -lt 2 ] && gap=2
  printf -v S '%*s' "$gap" ''
  printf '%s%s%s\n' "$left" "$S" "$host"
  [ -n "$watch" ] && printf '  WATCH    %s\n' "$watch"
  [ -n "$top" ] && printf '  TOP CPU  %s\n' "$top"
  echo

  if [ "$nrows" -gt 0 ]; then
    grid ROW
  else
    echo "  Nothing to clean."
  fi

  local l1 l2 r1 r2 lw
  l1="   $GG  worth doing      $GD  ask first      $GL  low value"
  l2="   safe now  ≈ $safe      ask first  ≈ $ask"
  [ $asc = 1 ] && l2="   safe now  ~ $safe      ask first  ~ $ask"
  r1="held  $nheld $sepd $heldkb  (--held)"
  r2=""; [ "$pick" != "-" ] && r2="pick  $pick  $sepd  \"safe\""
  lw=${#l1}; [ ${#l2} -gt $lw ] && lw=${#l2}
  echo
  if [ $((lw + 4 + ${#r1})) -le $tw ] && [ $((lw + 4 + ${#r2})) -le $tw ]; then
    printf -v S '%*s' $((lw - ${#l1} + 4)) ''; printf '%s%s%s\n' "$l1" "$S" "$r1"
    printf -v S '%*s' $((lw - ${#l2} + 4)) ''; printf '%s%s%s\n' "$l2" "$S" "$r2"
  else
    printf '%s\n%s\n   %s\n' "$l1" "$l2" "$r1"
    [ -n "$r2" ] && printf '   %s\n' "$r2"
  fi

  [ "$nsmall" -gt 0 ] && printf '   + %s small items (%s %s) %s --all\n' "$nsmall" "$([ $asc = 1 ] && echo '~' || echo '≈')" "$smallkb" "$sepd"
  if [ -n "$HELD" ] && [ "$nheld" -gt 0 ]; then
    echo
    grid HELD
  fi
  if [ "$nn" -gt 0 ]; then
    echo
    for ((j = 1; j <= nn; j++)); do echo "  NOTE     ${NOTES[j]}"; done
  fi
}

# ---------- remote run ----------
remote_run() {
  local host=$1 cul
  shift
  [ -f "$SELF" ] || { echo "entropy: --host needs the script run from a file, not stdin" >&2; return 1; }
  cul=$ENTROPY_CULPRITS
  [ -n "$cul" ] || cul=$(cd "$(dirname "$SELF")" && pwd)/../references/culprits.tsv
  { printf 'ENTROPY_CULPRITS_DATA=%q\n' "$(cat "$cul")"; cat "$SELF"; } |
    T 120 ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" bash -s -- "$@"
}

main() {
  local host="" want_host="" deep="" a
  JSON=""; HELD=""; ALL=""
  while [ $# -gt 0 ]; do
    a=$1; shift
    case "$a" in
      --json) JSON=1 ;;
      --deep) deep=1 ;;
      --held) HELD=1 ;;
      --all) ALL=1 ;;
      --host) want_host=1
        case "${1:-}" in ""|--*) host=$ENTROPY_HOST ;; *) host=$1; shift ;; esac ;;
      -h|--help) sed -n '2,8p' "$SELF"; return 0 ;;
      *) echo "entropy: unknown option $a" >&2; return 2 ;;
    esac
  done
  if [ -n "$want_host" ]; then
    [ -n "$host" ] || { echo "entropy: --host needs a name (or set ENTROPY_HOST)" >&2; return 2; }
    remote_run "$host" ${JSON:+--json} ${deep:+--deep} ${HELD:+--held} ${ALL:+--all}
    return $?
  fi
  [ "$(uname)" = Darwin ] || { echo "entropy: macOS only" >&2; return 1; }

  mkdir -p "$ENTROPY_STATE_DIR/work" || return 1
  W=$ENTROPY_STATE_DIR/work
  if ! shlock -f "$ENTROPY_STATE_DIR/lock" -p $$ 2>/dev/null; then
    echo "entropy: another run is in progress; wait for it to finish" >&2
    return 1
  fi
  trap 'rm -f "$ENTROPY_STATE_DIR/lock"' EXIT
  trap 'exit 130' INT TERM
  local f
  for f in "$W"/*; do [ -f "$f" ] && : > "$f"; done
  : > "$W/notes"; : > "$W/machine.tsv"

  CUL=$W/culprits.tsv
  if [ -n "${ENTROPY_CULPRITS_DATA:-}" ]; then printf '%s\n' "$ENTROPY_CULPRITS_DATA" > "$CUL"
  else cat "${ENTROPY_CULPRITS:-$(cd "$(dirname "$SELF")" && pwd)/../references/culprits.tsv}" > "$CUL" 2>/dev/null; fi
  [ -n "$ENTROPY_CULPRITS_EXTRA" ] && [ -f "$ENTROPY_CULPRITS_EXTRA" ] && cat "$ENTROPY_CULPRITS_EXTRA" >> "$CUL"
  grep -v '^#' "$CUL" > "$W/culprits.clean" && cp "$W/culprits.clean" "$CUL"
  [ -s "$CUL" ] || { echo "entropy: culprit table not found" >&2; return 1; }

  export TMO W CUL
  export -f T size_job inspect_wt
  ps -Ao pid=,ppid=,etime=,rss=,pcpu=,command= > "$W/ps.snap" 2>/dev/null
  T 10 lsof -nP -d cwd -Fpcn 2>/dev/null |
    awk '/^p/{p=substr($0,2)} /^c/{c=substr($0,2)} /^n/{print p "\t" c "\t" substr($0,2)}' > "$W/cwds.tsv"

  NOCWD=""; [ -s "$W/cwds.tsv" ] || { NOCWD=1; note "live-use check unavailable (lsof returned nothing): worktrees are held, not offered"; }
  export NOCWD ALL ENTROPY_MIN_MB
  phase_machine
  phase_procs &
  phase_launch &
  phase_listen &
  phase_docker &
  phase_paths &
  phase_worktrees &
  wait
  [ -n "$deep" ] && phase_deep
  render
}

main "$@" </dev/null
