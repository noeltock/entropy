# Acting on picked rows

Act on each row's `target`, read from `~/.local/state/entropy/runs/<run id>.json` for the run id in the table the user picked from (`last.json` is just the most recent scan). Only named IDs, and only after a fresh check right before acting: things change between the scan and the pick.

## Live-use gate (before removing any path)

- Resolve the exact path and its aliases (`realpath`; `/tmp` is `/private/tmp`).
- Check for live use of that path: `lsof -nP -d cwd` for working directories and `ps -Ao pid,command | grep -F <path>`. `lsof +D <path>` under a timeout is fine for a small folder, never for a big tree.
- Any hit, error or timeout fails closed: the row becomes held and the owner is shown.
- Age alone is never a reason to remove something.

## Processes

1. Confirm each PID still runs the expected command (`ps -o command= -p <pid>`). PIDs get reused.
2. Kill children first, then parents, in the order the target lists them: `printf '%s\n' <pids> | xargs kill`. zsh doesn't word-split `$VAR`, so never `kill $PIDS`.
3. Wait about three seconds, list survivors with `ps -p`, and `xargs kill -9` only those.
4. Re-run the scan and confirm the row is gone. Orphaned agent brokers ignore a parent-only kill, which is why the whole tree is targeted.
5. If the owning session is still alive (the OWNER column), ask that session to close its own browsers or servers first.

## Launch agents

`launchctl bootout gui/$(id -u)/<label>`, then move the plist from `~/Library/LaunchAgents` into a sibling `LaunchAgents.disabled` folder. Never `rm` it. If a tool reinstalls the plist at login, disable it with that tool's own command too. A high start count alone isn't a crash loop (scheduled jobs restart cleanly), which is why the script only flags non-zero exits.

## Worktrees

Only rows marked clean and pushed. Re-check each path: `git -C <path> status --porcelain` is empty, `git -C <path> rev-list --count HEAD --not --remotes` is 0, and the live-use gate passes. Then `git worktree remove <path>` (never `--force`) and `git worktree prune` in the main repo. The branch and its pushed commits stay. Anything dirty, unpushed, locked or in use is held: name it, give the reason, leave it.

## Agent scratch and other exact paths (`path` action)

Only the exact paths in the row's target, never a glob, a parent folder or a temp root. Remove them permanently with `rm -r -- <exact path>`. If the harness blocks `rm`, move them to Trash and say plainly that this frees nothing until the Trash is emptied. The current session's own scratch is too fresh to be listed, but check anyway.

## Docker

- Engine first: `docker context show` names the active engine. If the daemon doesn't answer within 5 seconds, say it's not responding, ask the user to start it, and stop. No retries.
- Never `docker system prune`, never prune volumes. Stopped or unattached doesn't mean disposable: volumes and containers can hold databases.
- Any removal needs exact resource IDs, what owns them, the user's yes, and Docker's own command. `docker system df -v` is for looking, not cleaning.
- A Docker Desktop disk image that isn't in use (app not running, another engine active) is reported at its real size. Switching engines doesn't move volumes, so assume it holds databases the new engine lacks. Don't start Docker Desktop to look, and never delete, reset or uninstall it until the volumes are checked (a reset or uninstall wipes them too). The read-only inspect and migrate steps are in [docker-desktop-migration.md](docker-desktop-migration.md).
- Other VM engines (Colima and similar) follow the same rule: inspect with that engine's own list command first.

## Trash

Moving something to Trash on the same disk frees nothing until the Trash is emptied, and emptying it is a Finder action (a scripted empty over ssh can hang for minutes, so stop after the first timeout and hand back). When space is tight, offer the tool's own permanent command for caches instead, size first.

## Other hosts

Run `--host <ssh-host>` per machine and keep the tables separate. Act on a host over ssh, and never move data between machines as a side effect of cleanup.

## Held

Held rows are never acted on: dirty, unpushed or in-use worktrees, active sessions, evidence or recovery data, and anything inaccessible or ambiguous. Show them with the reason so nothing is hidden, and leave them alone.

## Reporting back

Lead with the result: did it work, free space before and after, what's gone. Then what was skipped and why, and anything still pending (Trash not emptied, Docker left alone).
