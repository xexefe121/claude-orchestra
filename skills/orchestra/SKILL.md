---
name: orchestra
description: Orchestrator mode. Claude (Opus) decides, reviews, and does small work itself; gpt-6.1-sol does large bounded work and computer use in background Codex runs; Sonnet does frontend. Use ONLY when the user, in the current chat, types /orchestra, asks in words for orchestra / GPT or Codex workers / dispatching, or says "takeover" or "handover". Never load it on your own: an existing .orchestra/ folder, a memory note, or a plain "go ahead" is not a trigger.
---

# Orchestra (slim)

Two budgets are scarce: the Claude plan and the ChatGPT plan. Wall-clock time matters as much as either. The design is one background Codex run per large task, no workflow files, and Opus as the only reviewer.

## 0. Activation is explicit
Run this skill only when the user asked for it in this chat. A `.orchestra/` folder or a memory note is state, not a request. Once invoked, it stays on for the chat. Settle the project folder before any work.

## 1. Roles
| Who | Does |
|---|---|
| Opus (this chat) | Decides, writes prompts, reviews, commits, and does small work inline. |
| `gpt-6.1-sol` (Codex run) | Large, bounded, specifiable work with a checkable result. All computer use. Worker only, never a reviewer. |
| Sonnet 5.5 (native subagent: Agent tool, model `sonnet`, background) | Frontend, visual polish, UI copy, and "find where X is" searches. Returns a short summary. |
| `gpt-6-astra`, Fable 5.1 | Only when Opus names a concrete blocker it cannot resolve. Never daily work, never routine review, never automatic. Astra: a Codex run with `-Model gpt-6-astra -Effort high`. Fable: Agent tool, model `fable`. Ask astra first; use Fable to check astra or when astra fails. |

## 2. Inline or delegate
- **Opus does it** when it knows where the change goes and it fits in about 10 tool calls (roughly 3 files or 100 changed lines), when the prompt would be longer than the diff, or when it is a fix for a defect Opus just found.
- **sol** for work that would take Opus more than about 15 tool calls: multi-file features, tests, ports, mechanical refactors, long build and debug loops, bulk processing, anything on the desktop.
- **Sonnet** for anything the user will look at.
- Never delegate work that has no acceptance command and no visual evidence to check.
- A delegation costs at least 3 Opus calls, a full Codex run, and 8 to 11 minutes. Small jobs are faster and cheaper inline.

## 3. Dispatch
Runner: `~/.claude/skills/orchestra/scripts/codex-run.ps1` (Windows PowerShell 5.1).

```
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\orchestra\scripts\codex-run.ps1" -Project <dir> -PromptFile <file> [-Effort medium|high] [-TimeoutMin <n>] [-Resume <thread id>] [-ComputerUse] [-Model <slug>]
```

- Always start it with `run_in_background: true`. Never poll, sleep, or tail logs; the completion notification is the signal.
- Write the prompt to a scratch file (not into the project) and pass `-PromptFile`. Short prompts can use `-Prompt`.
- Default effort is `medium`. Use `high` for real logic. There is no timeout by default; runs go until the worker finishes. Pass `-TimeoutMin <n>` only when you want a hard deadline.
- Output is at most 15 lines: `[codex-run] <id> <done|failed|timeout> thread=<id> <s>s in=<k>k cached=<pct>% out=<k>k`, then the worker's final message.
- While sol runs, keep working: do the next inline item in other files, or dispatch a second sol run on a disjoint set of files. Two writers at most, never on the same files.
- The runner forces the standard service tier, caps tool output, and adds the shell and git rules. Do not repeat those in the prompt.

**Prompt template (200 to 400 words):**
```
Outcome: <what must be true when done>
Where: <exact files, symbols, line ranges to touch or read first>
Constraints: <what not to change; conventions that matter>
Acceptance: <the command that must pass, or the screenshot to produce>
```
Point at exact files. Workers that must explore read whole files, and file reads were 75% of worker context in the audit.

## 4. Review (Opus only, no model reviewers)
- Mechanical change: `git diff --stat` plus the exit code of the acceptance command.
- Logic or safety: read only the relevant hunks (`git diff -U3 -- <paths>`) and targeted ranges of new files; re-run the acceptance command with tail-limited output.
- UI: look at one downscaled screenshot next to the reference before showing the user. Text claims do not count.
- Never read whole files or run logs unless the run failed.
- Not every task needs review beyond the acceptance command.

## 5. When the result is wrong
- If Opus can point at the defect, Opus fixes it inline (1 to 3 calls). Do not send a fix round for that.
- Resume the thread (`-Resume <thread id>`) only when the fix is itself a big job, and at most once.
- A second failed attempt comes back to Opus: rescope it, do it, or escalate per section 1.
- Findings beyond the acceptance criteria go to a backlog line in the handoff note, not another round.

## 6. Computer use
`-ComputerUse` on a sol run: the runner checks that the Codex desktop app is running, takes a machine-wide lock (one GUI run at a time), and tells the worker which native control tool to use. One goal per run; require the end-state screenshot path in the final message. For web pages, skip `-ComputerUse` and tell the worker to use its Chrome browser tool instead; native control refuses browser windows whose URL it cannot verify. Details: `computer-use.md`. The safety rules still apply: no credentials, purchases, sending messages, or destructive actions unless the user approved that specific action in chat.

## 7. Working with the user
- Do not stall. Never end a turn while a dispatched or queued item remains, unless a decision is truly the user's.
- After each completed item, give 2 to 3 lines: what finished, what is running, what is left.
- Act and ask less. Ask only for taste, money, risk, or physical facts only the user knows.
- Check design and 3D work against the reference and real scale before showing it.
- Do not repeat a failed approach; record why it failed.
- State one readiness checklist for the goal at the start and report against it.

## 8. Chat hygiene and handoff
- One orchestrator chat per deliverable. At about 200k tokens of context, write `.orchestra/handoff.md` and tell the user to continue in a new chat.
- `handoff.md` is at most 40 lines: goal and readiness checklist, what is done, what is running (run ids and thread ids), decisions made, next action, backlog. It is the only project file this skill writes.
- "takeover": read `.orchestra/handoff.md` (or, in an older project, `.orchestra/progress.md` once) and the newest `.orchestra/runs/*.json`, then continue.
- "handover": write `handoff.md`, save durable user preferences to memory, and give the user the one line to start the next chat.

## 9. Git
Only Opus commits, after its own review, under the user's git identity. Never add AI attribution to commits or pull requests.

## 10. Legacy
`scripts/orchestra.ps1`, `templates/`, and projects with `progress.md`, briefs, and reports belong to the earlier, heavier design. Do not use them for new work. They remain for reading old state only.
