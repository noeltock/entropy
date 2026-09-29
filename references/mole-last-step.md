# Optional last step: mole

Use only when `mo` is installed and the user wants system and app caches cleared too. The yield is small (a few GB) because the whitelist below protects every developer cache; those are handled by `cache-policy.md`. Do not run this first, and never in triage: `mo clean --dry-run` can take minutes.

## 1. Whitelist guard (idempotent)

`mo clean` reads `~/.config/mole/whitelist`. That file replaces mole's built-in protections entirely, so a browser-only whitelist silently unprotects browser binaries, model folders, iCloud Drive and Spotlight caches. Read the file; if it is missing, write the full block below; if it exists, append only the missing lines and never remove or rewrite existing ones (the user may have added their own). Patterns use a leading `~`; mole does not expand `$HOME`.

```
# Managed by the entropy skill. User-added lines are preserved.
# --- mole built-in defaults (restated: this file replaces them) ---
~/Library/Caches/ms-playwright*
~/.cache/huggingface*
~/.m2/repository/*
~/.gradle/caches/*
~/.gradle/daemon/*
~/.ollama/models/*
~/Library/Caches/com.nssurge.surge-mac/*
~/Library/Application Support/com.nssurge.surge-mac/*
~/Library/Caches/org.R-project.R/R/renv/*
~/Library/Caches/pypoetry/virtualenvs*
~/Library/Caches/JetBrains*
~/Library/Caches/com.jetbrains.toolbox*
~/Library/Caches/tealdeer/tldr-pages
~/Library/Application Support/JetBrains*
~/Library/Caches/com.apple.finder
~/Library/Mobile Documents*
~/Library/Caches/com.apple.FontRegistry*
~/Library/Caches/com.apple.spotlight*
~/Library/Caches/com.apple.Spotlight*
~/Library/Caches/CloudKit*
FINDER_METADATA
# --- browser caches: HTTP plus Service Worker/app state (stay logged in) ---
~/Library/Caches/com.apple.Safari/*
~/Library/Caches/Google/Chrome/*
~/Library/Caches/Firefox/*
~/Library/Caches/BraveSoftware/Brave-Browser/*
~/Library/Application Support/Google/Chrome/*
~/Library/Application Support/Firefox/*
~/Library/Application Support/BraveSoftware/*
# --- Apple Mail (avoid a full re-sync) ---
~/Library/Caches/com.apple.mail/*
# --- package-manager caches (cleared by their own commands instead) ---
~/.npm/_cacache/*
~/Library/pnpm/store/*
~/.cache/yarn/*
~/Library/Caches/composer/*
~/.composer/cache/*
~/.cache/pip/*
~/.cache/uv/*
~/Library/Caches/Yarn/*
~/Library/Caches/pip/*
# --- Spotify (offline downloads live in this cache) ---
~/Library/Caches/com.spotify.client/*
# --- Docker BuildX layer cache ---
~/.docker/buildx/cache/*
```

"Browser cache" is two things: HTTP caches under `~/Library/Caches` and Service Worker app state under `~/Library/Application Support`. Losing the second logs the user out of web apps, hence both are protected. Trash is deliberately not protected: `mo clean` empties it permanently, so state its size.

## 2. Dry run

```bash
mo clean --dry-run 2>&1 | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' > <scratch file>
```

Run it once, redirect to a file and read the file; do not repeat it with different filters. It writes an itemised list to `~/.config/mole/clean-list.txt`, which is the place to look if the summary is ambiguous. The first run on a machine fires one batch of macOS folder-access prompts. If the output stalls at a permission step, ask the user to run `mo clean --dry-run` once in their own terminal and approve the dialogs, then continue. Never work around the permission prompts.

## 3. Summarise and stop

Group the result: total reclaimable, then system caches, app caches, dev caches, logs, Trash (call out "emptied permanently"). Flag anything that is not an obvious cache. Confirm the protected count looks right (browser, Mail, package and Docker lines protected, not cleaned). Wait for explicit approval; approval for one run never carries to the next.

## 4. Clean

On approval run `mo clean` with the same output handling. A macOS admin or Touch ID dialog may appear for system items; if the user declines, mole skips those and continues. Report the space actually reclaimed and the protected count, and say plainly if the numbers differ a lot from the dry run.

## Guardrails

- Never run `mo uninstall`, `mo purge`, `mo optimize` or `mo remove`.
- Never remove or rewrite user lines in the whitelist.
- If mole's whitelist behaviour changes after an update, re-verify the patterns against its own whitelist source before cleaning.
