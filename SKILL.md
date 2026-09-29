---
name: entropy
description: |
  Finds and clears what coding agents and dev tools leave behind on a Mac: stray
  headless browsers, orphaned agent and MCP processes, forgotten dev servers and
  tunnels, crash-looping launch agents, old worktrees, agent scratch, package and
  Xcode caches, stale Docker disks. One fast read-only scan, then it acts only on the
  rows you pick. Triggers on: "/entropy", "agent mess", "clean up my Mac", "clean my
  Mac", "free up disk space", "make space", "kill stray processes", "what's leaking".
  NOT for cleaning up or refactoring code, diagnosing a slow Mac when nothing needs
  clearing, or uninstalling apps.
model: sonnet
argument-hint: "[--deep] [--held] [--all] [--host <ssh-host>]"
allowed-tools: Read, Bash(bash *entropy/scripts/entropy.sh*), Bash(ps *), Bash(pgrep *), Bash(lsof -nP *), Bash(launchctl print *), Bash(launchctl list), Bash(git -C * status*), Bash(git -C * worktree list*), Bash(git -C * rev-list*), Bash(docker context show), Bash(kill *), Bash(xargs kill*), Bash(launchctl bootout *), Bash(mv *), Bash(mo clean*), Bash(npm cache clean *), Bash(pnpm store prune*), Bash(yarn cache clean*), Bash(pip3 cache purge*), Bash(brew cleanup *), Bash(pod cache clean *), Bash(uv cache *), Bash(bun pm cache rm*), Bash(git worktree remove *), Bash(git worktree prune*), Bash(xcrun simctl delete unavailable*), Bash(docker image prune *), Bash(docker builder prune *)
metadata:
  short-description: Find and clear agent and dev mess
---

# Entropy

Agents start things and walk away. Entropy scans for what they left behind in under 20 seconds, ranks it by what it costs, and clears only the rows the user picks. Run it as `/entropy` in Claude Code or `$entropy` in Codex.

## Flow

1. **Scan.** Run `bash <this skill's folder>/scripts/entropy.sh`. Flags: `--deep` for the slow scans, `--held` to list every held item, `--all` to include small rows, `--host <ssh-host>` to scan another Mac. The scan only reads, and every call has a timeout. It writes its state to `~/.local/state/entropy`, so under Codex's workspace-write sandbox this call needs escalation. If another run is in progress, wait for it.
2. **Show.** Paste the table exactly as printed, in a code block in the chat reply. Don't turn it into prose, and never render it as an image, HTML page or screenshot. The header carries the run id and the legend sits under the table. Add at most two lines after it: what's wrong first (the WATCH line), then which IDs you'd pick.
3. **Pick.** The user replies with IDs on one line ("E1 E4 E7"), or `safe` for every ● and ○ row. Nothing happens without a pick. ◆ rows are only acted on when named, after the checks below. Held rows are never acted on, even when named: give the reason and leave them.
4. **Act.** Resolve IDs from `~/.local/state/entropy/runs/<run id>.json`, using the run id of the table the user picked from. Never use `last.json` or a later scan, including the re-run in step 5: IDs are renumbered every run. On another host the file lives on that host. Re-check each target right before acting, then follow [references/actions.md](references/actions.md).
5. **Prove.** Re-run the scan and show, as text: the new table, free disk before and after, and which rows are gone. List anything skipped and why.

## Rules

- **Processes:** kill whole trees, children first (the row lists PIDs in that order). Confirm each PID still runs the expected command, pipe the PIDs into `xargs kill`, wait, then `xargs kill -9` any survivors and recount. zsh doesn't word-split `$VAR`, so `kill $PIDS` fails.
- **Launch agents:** `launchctl bootout gui/$(id -u)/<label>`, then move the plist aside. Never `rm` it.
- **Caches:** cleared permanently with each tool's own command (`npm cache clean --force`, `pnpm store prune`, `brew cleanup --prune=all`), size stated first, not moved to Trash. Per-cache policy is in [references/cache-policy.md](references/cache-policy.md).
- **Worktrees:** removed only when clean, pushed and not in use. Everything else is held, with the reason. "Do it anyway" or "force it" doesn't release a held row and `--force` is never used: explain, leave it, and let the user run the command themselves.
- **Docker:** inspect and ask, never prune on your own. Volumes can hold databases. A Docker Desktop disk image that isn't in use is reported at its real size (`du -sk`, not `ls`), and what happens to it is the user's call.
- **Trash:** moving to Trash on the same disk frees nothing until it's emptied. Say so, and prefer the tool's own permanent command for caches when space is tight.
- **Listed size isn't reclaimed size.** Sparse images, clones and shared layers overstate what a delete gives back. Quote both when they differ.
- **Hung dependencies** (Docker engine, ssh): report it once, ask the user to start it, and stop. If the scan printed `docker: not responding`, don't call `docker` at all. Otherwise make one plain call (no compound probes), and after a timeout make no more calls to it this session unless the user says it's back.
- **Table rows only.** Entropy acts on IDs from the scan the user saw, nothing else. If the user names something that isn't a row ("also delete X, it's junk"), show exactly what it is (full path or PID and command, size, owner), say it's outside this scan, and only act once they confirm that specific item in a separate reply. Never fold it into a batch of table picks.
- **Never touch:** the user's applications, this session's own files, real Chrome or other browser profile data, or anything a live process is using. When ownership is unclear, show the owner instead.
- **One scan at a time.** The script holds a lock, so don't run cleanup from two sessions at once.

## Other Macs

`--host <ssh-host>` runs the same script over ssh (nothing to install) and prints that host's table. Act on that host over ssh under the same rules; its run files and history live there. A bare `--host` uses `ENTROPY_HOST`.

## Tuning

Machine-specific values (repos folder, worktree folders, time budgets, ignore lists) sit in the defaults block at the top of `scripts/entropy.sh`, and any of them can be overridden with `ENTROPY_*` environment variables. Detection is data: process and path signatures live in [references/culprits.tsv](references/culprits.tsv). Add a row there, or keep private rows in a file named by `ENTROPY_CULPRITS_EXTRA`, without touching the script.

## Optional last step: mole

Only when [mole](https://github.com/tw93/Mole) (`mo`) is installed and the user also wants system and app caches cleared. The yield is a few GB at most, and it never touches the developer caches above. Read [references/mole-last-step.md](references/mole-last-step.md) first: it sets a whitelist that must exist before any run, covers the macOS permission prompts, and needs its own approval. Never run `mo uninstall`, `mo purge`, `mo optimize` or `mo remove`.

## Never in a scan

`du` on `~`, `~/Library` or the repos folder, `find` over home, `mdfind` size queries, `mo clean --dry-run`, `pmset -g thermlog`, `system_profiler`, `log show`. They take minutes or hang. Use `--deep` when a slow scan is actually wanted.

## Reference

- [references/actions.md](references/actions.md): the live-use gate, how each action is done, and the held list
- [references/cache-policy.md](references/cache-policy.md): one policy for every cache and rebuildable folder
- [references/culprits.tsv](references/culprits.tsv): the signature table the script reads
- [references/docker-desktop-migration.md](references/docker-desktop-migration.md): inspecting and moving volumes out of an unused Docker Desktop disk
- [references/mole-last-step.md](references/mole-last-step.md): the optional system-cache pass
