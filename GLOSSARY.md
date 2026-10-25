# Glossary

Terms used in this repo and where they live. Read this before choosing where a change belongs.

## Product

| Term | Meaning | Where |
|---|---|---|
| AI Account Switcher | The menu-bar app (bundle `com.mohamedfuad.codexaccountswitcher`, executable `CodexAccountSwitcher`). Renamed from Codex Account Switcher in this fork. | `/Applications/AI Account Switcher.app` |
| Panel | The floating window opened from the status item. Four tabs: Accounts, Analytics, Resets, Settings. | `AccountPanelView.swift` |
| Status item | The menu-bar text: provider logo, remaining percent, reset time, per provider. | `main.swift` (`menuBarUsageParts`) |
| Lifecycle monitor | Helper launched by a LaunchAgent that starts or stops the app with ChatGPT ("Follow ChatGPT"). | `LifecycleMonitor.swift` |
| Route B | Non-executing prototype that stores a provider profile id only. | `main.swift`, `RouteBProviderProfile` |

## Accounts and usage

| Term | Meaning |
|---|---|
| Codex account | A ChatGPT login managed by `codex-auth`; switching rewrites Codex's auth and relaunches ChatGPT. |
| Claude account / profile | A Claude Code login identified by email plus organisation id; credentials live in the Keychain item Claude Code uses. `ClaudeAccounts.swift`. |
| Active account | The account Codex or Claude Code is currently using; shown first with a green dot, others dimmed. |
| 5h / 5-hour window | Short rolling limit. Absent for ChatGPT Pro and Business premium ("prolite") seats. |
| Weekly / 7d window | Rolling weekly limit, shown for every plan. |
| Remaining | 100 minus used. The UI always shows remaining. |
| Plan type | `plan_type` in the Codex usage response; the source of truth for `hasFiveHourLimit`. |
| Premium seat | A Team or Business seat with larger limits ("Claude Team 5x", prolite). |
| Reset credit | A redeemable token that resets Codex limits early; the Resets tab verifies redemption. |
| Cursor lane | One of Cursor's three monthly meters: Auto and API. All share the billing-cycle reset. |
| Menu-bar lane | Which Cursor lane (or Off) the status item shows. |

## Analytics

| Term | Meaning |
|---|---|
| TokenTracker | The MIT app this feature is ported from. Credited in the README. |
| Bucket | Token totals for one UTC half hour, source and model. The only thing persisted besides cursors. |
| Source | `codex`, `claude` or `cursor`. Cursor has no local logs; its tokens come from the account usage export. |
| File cursor | Inode, byte offset and head/tail fingerprints per log file; lets scans read only new bytes and detect rewrites. |
| Rollout | A Codex session log, `.jsonl` or `.jsonl.zst`. |
| Dedup set | Hashed message ids so replayed or forked sessions are not double counted. |
| Snapshot | `AnalyticsSnapshot`, everything the Analytics tab draws for one period. |
| Period | Day, Week, Month or Total. |
| Heatmap | Six months of daily totals in week columns, Sunday first, five quantile levels over non-zero days. |
| Top models | The five heaviest models of the period, merged by trimmed lowercase name. |
| Session efficiency | Edit-session and first-pass statistics; computed, no longer displayed. |
| Scan | Reading new log bytes into buckets. The first scan is full (about 100 s); later ones are incremental. |

## Behaviour

| Term | Meaning |
|---|---|
| Limit reset celebration | Toast plus fireworks when a window that was at or below 20% remaining refills by 50 points or more. `LimitResetWatcher`, `Celebration`. |
| Near the limit | At or below 20% remaining at some point since the last reset. |
| Auto-switch | Switches Codex and Claude accounts when remaining drops below a threshold. |
| Auto-resume | Sends a prompt to continue the Codex task after a switch. |
| Usage reminder | A notification when a window runs low. |
| Confirm before switching | First click arms a switch, second confirms it. |
| Signature | A flattened string of everything the panel draws; the panel rebuilds only when it changes. Anything new the panel shows must be added to `panelSignature()`. |

## Tooling

| Term | Meaning |
|---|---|
| Render harness | Offscreen app in `tmp/render*` that screenshots the panel with fake or real data. |
| Cross-provider review | A read-only Codex review through T3 `delegate_task`, each finding verified before fixing. |
| Ship worktree | A clean `tmp/wt` checkout used to commit finished work while the main tree has unfinished edits. |
