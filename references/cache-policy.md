# Cache policy

One table for every cache and rebuildable folder the script lists. The `priority` column in `culprits.tsv` mirrors the Default column here; change both together.

Defaults: **clear** = offer normally; **offer** = list last and do not repeat the offer within a session once declined; **ask** = inspect with the user first, never automatic; **never** = not a cleanup target.

All removals are permanent and use the tool's own command where one exists. Say the size first. State whether the cache is global (npm, uv, pnpm, pip and Homebrew are shared by every project) and that `node_modules` and virtualenvs are never touched: `--deep` lists large `node_modules` folders as information only, with no action.

| Item | Default | Command | What it costs |
| --- | --- | --- | --- |
| npm cache (`~/.npm/_cacache`) | clear | `npm cache clean --force` | Next install is slower. Usually the biggest single cache. |
| pnpm store | clear | `pnpm store prune` | Removes only unreferenced packages, often little. Never delete the store folder: live projects hard-link into it. |
| Yarn cache | clear | `yarn cache clean` | Next install is slower. |
| pip cache | clear | `pip3 cache purge` | Wheels re-download. |
| Homebrew downloads | clear | `brew cleanup --prune=all` | Old bottles re-download on reinstall. |
| CocoaPods cache | clear | `pod cache clean --all` | Next `pod install` re-downloads specs. |
| uv cache (`~/.cache/uv`) | offer | `uv cache clean` | Next install re-downloads. Often large; low priority because it is cheap to keep. |
| bun cache (`~/.bun/install/cache`) | clear | `bun pm cache rm` | Next install is slower. Global across projects. |
| Playwright MCP profiles (`~/Library/Caches/ms-playwright/mcp-chrome-*`) | clear | exact folder removal | Only when no process uses them (live-use gate). Logins kept in a profile are lost. |
| Playwright browsers | offer | `npx playwright uninstall --all` | Browser tools re-download about 1 GB on next use, and fail until then. |
| Puppeteer browsers | clear | exact folder removal | Re-downloads Chrome on next use. |
| Hugging Face cache | offer | exact folder removal (or the tool's cache command) | Models re-download; can be many GB. |
| Ollama models | ask | `ollama rm <model>` | Choose models by name; each must be pulled again. |
| Xcode DerivedData | clear | exact folder removal | Next build is a full rebuild. |
| Xcode device support (`*DeviceSupport`) | clear | exact folder removal | Symbols re-download when a device of that OS version connects. |
| iOS simulators | clear | `xcrun simctl delete unavailable` | Removes simulators that have no runtime. `simctl delete all` also drops installed test apps and their data: ask. Simulator runtimes: ask. Real freed space is often far below the listed size (sparse files, clones). |
| Docker images, containers, volumes, build cache | ask | Docker's own commands, per resource | Volumes can hold databases. Never `system prune`. See `actions.md`. |
| Docker Desktop disk image, Colima VM | ask | none automatic | Holds every container and volume of that engine. |
| Backups, Trash, Downloads | ask | none automatic | May be the only copy. Emptying Trash is a Finder action. |
| Local Time Machine snapshots | never | none | macOS reclaims them itself when space is needed. |

## Why these defaults

- Package caches are usually the biggest reclaimable items, and broad cleaners (mole included) deliberately protect them, so they need each tool's own command. That's what this table is for.
- Browser downloads, simulators and device support cost one re-download or rebuild and lose no state, so they default to clear. Anything that can lose data (simulator app data, Docker volumes, backups) defaults to ask.

## Adding an item

Add a row to `culprits.tsv` (kind `path`) and a row here. Prefer a command the tool itself provides; use `path` (exact folder removal) only when none exists.
