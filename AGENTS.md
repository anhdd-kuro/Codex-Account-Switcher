# AI Account Switcher Project Notes

Terms and ownership: [GLOSSARY.md](GLOSSARY.md).

This project is a sanitized public version of Graham's local Codex Account Switcher menu-bar app.

Rules for future work:

- Do not commit local Codex auth files, account registries, tokens, account IDs, email addresses, or build artifacts.
- Keep `build/`, `.swiftpm/`, `.build/`, and module caches ignored.
- The public toolbar account label must remain generic: use the first alphanumeric character from the email address unless the user sets a custom label in the app.
- Keep switching based on account email queries, not padded numeric selectors such as `01` or `02`.
- The app depends on `codex-auth`; do not vendor or copy private `~/.codex/accounts` data into the repository.
- Build verification is `./build.sh`.
- Install verification is `./install.sh`, then confirm the app runs from `/Applications/AI Account Switcher.app` (renamed in this fork; executable and bundle id unchanged).
- Current app release is v3.0 / build 3000: a full macOS 27 Liquid Glass redesign (AccountPanelView.swift, glass components in PanelComponents.swift, PanelTheme in Models.swift), a performance pass (cached codex-auth path, signature-gated panel rebuilds, event-driven relaunch and process waits, ephemeral URLSession), and removal of the retired API mode and hidden legacy menu. It keeps transactional verified switching, rollback, best-account scoring, verified reset-credit redemption, the lifecycle monitor, privacy-safe diagnostics and the non-executing Route B prototype.
- The GitHub Pages site in docs/ and the README artwork are generated from demo-mode captures (CODEX_ACCOUNT_SWITCHER_DEMO=1, CODEX_ACCOUNT_SWITCHER_DEMO_SCENARIO=two|four, CODEX_ACCOUNT_SWITCHER_APPEARANCE=dark|light).

Potential v2.5 idea:

- Consider a separate "Cheap Agent" / Route B mode instead of trying to make a third-party model fully replace Codex Desktop.
- The app could store provider profiles in Keychain and launch a local helper that exposes only a limited, tested tool set: selected MCP calls, simple file/folder checks, Ego Browser or Chrome browser reads/clicks, page scraping, and harmless draft/check workflows.
- Treat each third-party model as capability-tested rather than trusted by default. Show capability states such as chat only, MCP-safe, browser-safe, and live-ops unsafe.
- Require smoke tests before enabling browser or MCP use: open/read a page, perform a harmless click/type, call one selected MCP, process the tool result, and continue coherently.
- Keep native Codex as the fallback and default for public, irreversible, account-sensitive, or upload/send tasks such as Traxsource, Kit, Prime, SoundCloud, Bandcamp, invoices, and account switching.
- Keep all provider keys, local routing files, account emails, and actual auth state out of the public repository.
- The minimal prototype now implements profile selection only. It stores a public profile ID in `UserDefaults`; provider execution, key entry, and tool enablement remain disabled.

Claude fork notes:

- Claude support lives in Sources/ClaudeAccounts.swift (store, Keychain via /usr/bin/security, usage, token refresh) and the Claude section of the Accounts tab.
- Keychain writes mirror Claude Code: `security -i` with hex on stdin when short, argv otherwise, always `-U`. Never delete-then-add the live item.
- Only replace `claudeAiOauth` in the live item; keep every other key.
- Never refresh the active profile's token; Claude Code owns it.

## Build, install, run

- `./build.sh` compiles every `Sources/*.swift` except `LifecycleMonitor.swift` (built separately) and copies the logos and `Resources/analytics-pricing.json`. A new source file needs no registration; a new resource needs a `cp` line in `build.sh`.
- `./run-tests.sh` runs `Tests/InfrastructureTests.swift` against `AppInfrastructure.swift` and `LimitResetWatcher.swift` only, then the app's `--self-test-reset-logic`. New testable logic must live in a file that has no AppKit dependency and be added to that compile list.
- Install: quit the running app, replace `/Applications/AI Account Switcher.app`, open it. `open` on an already-running app only activates it, so a stale binary keeps running; always `pkill -f CodexAccountSwitcher` first. After relaunch confirm the process start time.
- If the app runs but has no menu-bar item, kill and relaunch; it has happened once without a code cause.
- When the working tree is unfinished, ship through a clean worktree (`tmp/wt`), then `git update-ref refs/heads/main`, push, remove the worktree.
- Commits are conventional (`feat:`, `fix:`, `docs:`), end with the Co-Authored-By line, and are pushed to the fork's `main`.

## Verifying UI

- Never claim a UI change works from a clean build. Render it: `tmp/render` (fake data) and `tmp/render-real` (real analytics, a 100 s first scan) are offscreen harnesses that screenshot `AccountSwitcherPanelView`. Rebuild them with `swiftc` over `Sources/*.swift` minus `main.swift` and `LifecycleMonitor.swift`.
- Environment switches for the real app: `CODEX_ACCOUNT_SWITCHER_SHOW_PANEL=1`, `..._SHOW_SETTINGS=1`, `..._DEMO=1`, `..._CELEBRATE=1` (fires the reset toast and confetti once, two seconds after launch).
- A screenshot of the live panel needs the status item clicked; the menu bar has many third-party items, so find ours by its text.

## UI rules (Vitesse dark)

- Colours come from `PanelTheme` in `Models.swift`; never hard-code a colour in a view. Dark panel `#121212`, tiles `#1E1E1E`, accent `#4D9375`, text `#CECABE`.
- Accounts are flat rows (no cards, no circle letters): 22pt header, 18pt usage bars, hairline dividers, a green dot on the active account, inactive rows at 50% alpha (`TileView.restingAlpha`).
- Remaining percent is shown, not used percent. Resets show the largest unit plus hours from one day up: `45m`, `4h`, `3d 4h`.
- Dialogs must go through `NSAlert.runAbovePanel()` or they open behind the menu panel.
- Panel width is `AccountSwitcherPanelView.panelWidth` (452); everything lays out from it.
- A glass/blur background and a Glass opacity slider were tried and reverted at the user's request. Do not reintroduce them unprompted.

## Providers

- **Codex**: accounts come from `codex-auth`; usage from `chatgpt.com/backend-api/wham/usage`. `plan_type` from that response decides the 5h window: a plan type containing `pro` (ChatGPT Pro, Business premium "prolite") has no 5-hour limit and shows weekly only. `codex-auth` labels the prolite seat "Business", so the label is not enough.
- **Claude**: `api.anthropic.com/api/oauth/usage`. Every plan shows the 5h window, including Team premium seats. Keep the Keychain rules in "Claude fork notes" above.
- **Cursor** (`Sources/CursorUsage.swift`): read-only. Token from `cursorAuth/accessToken` in Cursor's `state.vscdb` (via `/usr/bin/sqlite3 -readonly`), user id from `~/.cursor/cli-config.json`, then `cursor.com/api/usage-summary` with the `WorkosCursorSessionToken` cookie. Redirects off cursor.com are refused so the cookie never leaves it. Never log the token or cookie. No switching. Token analytics come from the account usage export (`export-usage-events-csv?strategy=tokens`, `AnalyticsCursor.swift`): the export is authoritative, so Cursor buckets from the earliest exported event on are replaced (the earliest half hour never shrinks), other sources are untouched, and the sync runs at most every 15 minutes inside the analytics scan.
- Menu bar parts per provider: Codex and Claude pick Off, 5-hour, Weekly or Both (two stacked lines); Cursor picks Off, Auto, API or Both (two stacked lines) (default Off). Preferences are plain `UserDefaults` keys (`usageDisplayMode`, `claudeUsageDisplayMode`, `cursorMenuBarLane`, `toastOnReset`, `confettiOnReset`).

## Analytics

- Ported from TokenTracker (MIT, `github.com/xiufengsun/TokenTracker`); keep the credit in `README.md`. The spec we followed is `tmp/analytics-spec.md`.
- Engine files are `Analytics*.swift` (Controller, Scanner, parsers, Sessions, SnapshotBuilder, Pricing, Projects, State, Support, Zstd); the panel contract is `AnalyticsModels.swift` (`AnalyticsProviding`, `AnalyticsSnapshot`). The UI only talks to the contract.
- State lives in `~/Library/Application Support/AI Account Switcher/analytics/state.plist` (version 2; a version bump forces a full rescan, about 100 s). First scan peaks near 1 GB; incremental scans take 2 to 20 s.
- Tokens are bucketed per UTC half hour keyed `source|model`; files keep inode/offset cursors with head/tail fingerprints; duplicates are removed with hashed sets. `.jsonl.zst` rollouts use the built-in zstd decoder, which must never trap on corrupt input (it was fuzzed with 20,000 corrupt files).
- Numbers differ from TokenTracker on purpose: Claude is about 40% higher because Agent SDK lines are counted, and edit-session counts are higher because TokenTracker's duplicate-id bug is fixed here. Codex matches on most days.
- The tab shows: total tokens with source split, summary tiles, top 5 models, a 6-month activity heatmap, usage trend, daily/projects breakdown. Session efficiency was removed from the UI; the computation still runs.
- Arithmetic on log-derived integers uses saturating helpers; a plain `+` on file data can trap.

## Limit reset celebration

- `LimitResetWatcher` (pure, tested) tracks the lowest remaining percent per window since the last reset and reports a reset when it was at or below 20% and has refilled by 50 points. First observation never fires. `Celebration` shows the toast and confetti as click-through windows anchored under the status item. Both are toggles in Settings > Automation, on by default.

## Review workflow

- Non-trivial changes get a cross-provider read-only review through T3 `delegate_task` (codex, `gpt-6.1-sol`), then every finding is verified before being fixed. Two rounds found integer traps, zstd overflows, unbounded line memory, dedup eviction and stale-period bugs.

## Open items

- T3 Code and Cursor keep using the old Codex account after a switch: their long-running `codex app-server` processes load the account once. Needs a restart strategy the user has not chosen.
