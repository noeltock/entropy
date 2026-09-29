# evals

The scan only reads. What can go wrong is a bad call in the table (the agent trusts it) or a bad action after a pick, so every case here is a real way something could get deleted or killed by mistake. Everything runs against a throwaway folder from `mktemp -d`, and nothing outside it is touched.

```bash
bash evals/run.sh              # everything
bash evals/run.sh --no-agent   # layer A only: about 15 s, no model, just bash and git
bash evals/run.sh --repeat 3   # agent scenarios three times each
```

**Layer A, `test_triage.sh`.** Points the script at a fake home with `ENTROPY_*` overrides and hides real processes, launchd and Docker behind the shims in `shims/`. It checks that:
- a clean, pushed worktree is offered, while dirty, unpushed, in-use and unreadable ones are held, and nothing is offered when `lsof` is unavailable
- the Docker Desktop disk, backups and Trash are always ask-first
- the process minimum age holds, and orphans are flagged
- every selectable row stays inside the fixture, and a full `--deep` run changes nothing
- `--json` parses and its IDs match the table and the run file, and small items stay hidden without `--all`

Each safety case also runs against a copy of the script with its guard removed, and has to fail there (`--no-mutate` skips this).

**Layer B, `agent/run_agent.sh`.** Headless `claude -p` runs (Sonnet, permissions bypassed on purpose, like a user who approves everything), graded from a log rather than by a model. Every delete, kill and clean command is swapped for a shim that records the attempt and does nothing. On top of that: only the Bash, Read, Grep, Glob and Skill tools, deny rules for absolute paths, and Claude Code's sandbox, so writes outside the fixture fail in the kernel. Nothing runs until a containment probe passes and a request to delete a canary outside the fixture is refused.

The scenarios: exact picks, `safe`, a named dirty worktree, "nuke everything", an ID from an older scan, and a hung Docker.

Layer B needs the `claude` CLI (your normal login) and `jq`, and costs tokens: about 10 Sonnet calls per pass. Session files land in `~/.claude/projects/*entropy-eval-agent-cwd*`, delete them whenever. A failing scenario is a finding about the skill, not a reason to loosen a grader. `FX_KEEP=1` keeps the transcripts.
