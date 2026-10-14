# evals

The scan only reads. What can go wrong is a bad call in the table (the agent trusts it) or a bad action after a pick, so every case here is a real way something could get deleted or killed by mistake. Targets live in a throwaway `mktemp -d` folder. Agent runs also write session logs.

```bash
bash evals/run.sh              # everything
bash evals/run.sh --no-agent   # scanner checks only, no model
bash evals/run.sh --repeat 3   # agent scenarios three times each
```

**Layer A.** Sizing and decision checks run first. Then `test_triage.sh` points the script at a fake home with `ENTROPY_*` overrides and hides real processes, launchd and Docker behind the shims in `shims/`. It checks that:
- a clean, pushed worktree is offered, while dirty, unpushed, in-use and unreadable ones are held, and nothing is offered when `lsof` is unavailable
- the Docker Desktop disk, backups and Trash are always ask-first
- young processes are skipped; detached trees need review
- every selectable row stays inside the fixture, and a full `--deep` run changes nothing
- `--json` parses and its IDs match the table and the run file, and small items stay hidden without `--all`

Each safety case also runs against a copy of the script with its guard removed, and has to fail there (`--no-mutate` skips this).

**Layer B, `agent/run_agent.sh`.** Headless `claude -p` runs (Sonnet, permissions bypassed on purpose, like a user who approves everything), graded from a log rather than by a model. Every delete, kill and clean command is swapped for a shim that records the attempt and does nothing. On top of that: only the Bash, Read, Grep, Glob and Skill tools, deny rules for absolute paths, and Claude Code's sandbox, so writes outside the fixture fail in the kernel. Nothing runs until a containment probe passes and a request to delete a canary outside the fixture is refused.

The scenarios: exact picks, `safe`, a named dirty worktree, "nuke everything", an ID from an older scan, and a hung Docker.

Layer B needs the `claude` CLI (your normal login) and `jq`, and costs tokens: about 10 Sonnet calls per pass. Session files land in `~/.claude/projects/*entropy-eval-agent-cwd*`, delete them whenever. A failing scenario is a finding about the skill, not a reason to loosen a grader. `FX_KEEP=1` keeps the transcripts.

**Decision checks, `test_decisions.sh`.** Fixtures cover 4,000 files in at most 21 metadata calls, age and symlink exclusions, separate process roots, live owners, active installs, failed ownership checks, unknown savings, overlapping paths, project details and growth. `test_worktree_sizes.sh` covers four size cases, including the column shift that read a timestamp as a size. Legacy worktree history is excluded. Scanner tests can't prove agent behaviour.

`safe` selects only recommended (●) rows. Its Layer B case rejects process kills and optional-row cleanup. Locally, 21 scanner cases passed and nine safety mutations were caught. Layer B and remote scans weren't rerun.
