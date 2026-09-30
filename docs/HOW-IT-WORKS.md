# How it works

One skill tells Opus when to work inline and when to delegate.
One small runner starts each large bounded Codex task. No workflow files,
task board, brief/report templates, or review chains are required.
The skill and runner are the source of truth.

## Five steps

1. **Inline or delegate:** Opus handles small work and defects it can locate.
   sol handles large bounded work and computer use; Sonnet handles frontend
   as a native background subagent. Every delegation needs acceptance evidence.
2. **Dispatch:** write a 200 to 400 word scratch prompt: Outcome, Where,
   Constraints, Acceptance. Pass it to codex-run in the background.
   Keep working in disjoint files; at most two writers. Wait for notification,
   not polling. Default model is `gpt-6.1-sol`, effort `medium`, timeout 20 minutes.
3. **Review:** Opus checks acceptance results and relevant diff hunks.
   UI work needs a screenshot. No routine model reviewers.
4. **When the result is wrong:** Opus fixes clear defects inline. Resume once
   only for a large fix. A second failure returns to Opus to rescope or escalate.
5. **Handoff:** near 200k chat context, write `.orchestra/handoff.md`, at most
   40 lines. Record goal, readiness, done/running work, run/thread IDs,
   decisions, next action, and backlog. Continue in a new chat with "takeover".

## Runner and state

Windows uses `scripts/codex-run.ps1`; macOS/Linux use `scripts/codex-run.py`.
The runner starts `codex exec`, forces standard service tier, limits tool
output, and adds shell and git rules. It captures output and enforces a timeout.
Windows uses a job object to stop the worker and descendants together.
Output is a status/token summary followed by a bounded final message.
Run artifacts live in `.orchestra/runs/`: metadata `.json`, events `.jsonl`,
stderr `.err.log`, and final message `.last.md`. They are diagnostics, not
workflow files. The runner creates `.orchestra/.gitignore` when absent.

`/orchestra`, explicit dispatch requests, "takeover", or "handover" activate
the skill in the current chat. Old folders and memory notes do not activate it.
Opus is the only reviewer. Astra then Fable are for named blockers only.

## Computer use and limits

`-ComputerUse` requires the Codex desktop app and native `node_repl`/Sky tool.
Windows checks the app and holds one machine-wide GUI lock. The worker must
preflight native control and return an end-state screenshot path.
See [computer-use.md](../skills/orchestra/computer-use.md).

Workers run with full disk access and no approval prompts. Prompt rules are
not isolation; GUI workers control the real desktop. Use a separate account
or VM for stronger limits. macOS/Linux are verified by mock tests in CI only;
live runs and computer use on macOS are not yet verified by the author.
