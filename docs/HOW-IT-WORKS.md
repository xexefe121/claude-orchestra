# How it works

Claude is the orchestrator. It writes briefs, chooses models, reviews results, and decides what happens next. The PowerShell launcher starts headless Codex or Claude workers and records their state in the project.

## State files

| Path | Owner | Purpose |
|---|---|---|
| `.orchestra/context.md` | Orchestrator | Goal, architecture, decisions, readiness checklist |
| `.orchestra/progress.md` | Orchestrator | Handoff and milestones |
| `.orchestra/WORKER.md` | Orchestrator | Worker rules |
| `.orchestra/tasks/*.md` | Orchestrator | Briefs and owned files |
| `.orchestra/reports/*.md` | Worker | Result, verification, risks, handoff notes |
| `.orchestra/workers.json` | Launcher | Worker identity, session, status, CLI, context |
| `.orchestra/runs.json` | Launcher | Latest task results across worker resumes |
| `.orchestra/board.md` | Launcher | Task board derived from state |
| `.orchestra/runs/` | Launcher | Raw JSONL and stderr logs; gitignored |

`init` copies templates. `run` checks model/CLI support, starts a worker, captures output, and writes state. A task counts as done only when exit code is zero and its report was written during that run. `-Review` chains a fresh reviewer. The launcher prints completion lines and bounded report digests. `status` lists workers; `board` regenerates the task board. A named worker can resume for related work below its handoff threshold.

`batch` reads a JSON array, starts independent tasks in parallel, waits for jobs, and respects `dependsOn`. Failed dependencies skip their dependents. Per-project mutexes protect state writes. A machine-wide desktop mutex allows one computer-use worker at a time. Process jobs and timeouts bound hung workers and inherited output pipes.

## Task loop and escalation

The orchestrator defines readiness, divides work into independent owned-file briefs, and dispatches one batch per wave in the background. Completion notifications replace polling. It reads the digest, consults a report only when needed, accepts results, and dispatches the next wave. Only the orchestrator commits.

Fix an unclear brief and resume once after a failure. After a second failure, escalate to astra; use a stronger effort or consult for hard decisions. Fable is the final model escalation. In hybrid mode, Sonnet handles frontend and judgment-sensitive coding, while sol handles large mechanical non-UI work. Ask the user when the remaining decision belongs to them.

GPT handoff threshold is 70% of context. Claude worker threshold is 200k tokens or 70%, whichever comes first. The orchestrator hands over at 200k context. Handover records state, running workers, decisions, exact next action, and gotchas in `progress.md`. Takeover reads that handoff, then context, worker status, and relevant fresh reports. Workers continue independently while the orchestrator changes chats.

## Known environment notes (2026-09-30)

These are dated observations from the kit's validation environment, not requirements for every PC.

- PATH/npm Codex CLI 0.159.2 supported `gpt-6.1-sol`; the bundled desktop CLI 0.158.0-alpha did not. Both supported `gpt-6-sol`, `gpt-6-astra`, and `gpt-6-luna`.
- Native control was verified through `mcp__node_repl__js` with `@oai/sky` on both CLI families when the desktop app was running and the native service was configured. `cua_repl` in that environment exposed only browser control. CLI family alone does not guarantee native control.
- Current `auto` selection prefers a supported PATH/npm CLI for ordinary work and a supported desktop CLI for computer use. It falls back to the other supported family and preserves CLI provenance for resumes.
- Claude model shorthands were pinned to Sonnet 5.5, Opus 5.5, and Fable 5.1. The launcher accepts full IDs. Update pins when models change.
- Windows PowerShell 5.1 reads scripts without a BOM as ANSI by default. Package scripts use ASCII-compatible source and UTF-8 APIs for data. Non-ASCII task inputs get a BOM before CLI consumption when needed.

## Local verification

`tests/run.ps1` runs the latest mock regression suites in separate PowerShell 5.1 child processes. It supplies a fake home and fresh temp fixtures, protecting installed skills and CLI configuration. Suites cover model selection, Claude engine parsing, profiles, reviews, context guards, boards, batch timeouts, process drainage, install, and uninstall. No live-model harness is included.
