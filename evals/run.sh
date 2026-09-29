#!/bin/bash
# run.sh - the whole eval suite: layer A (deterministic triage tests), then layer B (agent runs with a
# tripwire), which starts with the canary gate and stops there if the canary is touched.
#
#   run.sh [--repeat N] [--no-agent] [--no-mutate]
#
# Layer B needs the `claude` CLI and jq, and costs tokens. Exit status is non-zero on any failure.

HERE=$(cd "$(dirname "$0")" && pwd)
REPEAT=1; AGENT=1; MUTATE=--mutate
while [ $# -gt 0 ]; do
  case "$1" in
    --repeat) REPEAT=$2; shift ;;
    --no-agent) AGENT="" ;;
    --no-mutate) MUTATE="" ;;
    *) echo "run.sh: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

START=$(date +%s)
RC=0
echo "=== Layer A: triage tests ==="
bash "$HERE/test_triage.sh" $MUTATE || RC=1
if [ -n "$AGENT" ]; then
  echo
  echo "=== Canary gate, then Layer B: agent behaviour ==="
  bash "$HERE/agent/run_agent.sh" --repeat "$REPEAT"
  B=$?
  [ $B -eq 0 ] || RC=1
fi
echo
echo "total wall time: $(( $(date +%s) - START ))s"
[ $RC -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $RC
