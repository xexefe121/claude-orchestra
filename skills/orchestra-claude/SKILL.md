---
name: orchestra-claude
description: Hybrid orchestrator mode. Opus 5.5 decides; Sonnet 5.5 (headless Claude CLI) does tasteful, frontend, and quality-sensitive work; gpt-6.1-sol does token-heavy grunt work; astra and then Fable handle escalations. Use ONLY when the user, in the current chat, types /orchestra-claude, asks in words for orchestra-claude / Claude-hybrid orchestration, or says "takeover" in a project whose .orchestra/context.md says Mode: orchestra-claude. Never load it on your own: an existing .orchestra/ folder, a memory note, or a plain "go ahead" is not a trigger.
---

# Orchestra-claude: hybrid Claude + GPT orchestration

**First read `~/.claude/skills/orchestra/SKILL.md`.** Everything there applies:
- the `.orchestra/` state files;
- the task loop;
- resume or fresh workers;
- review, git (no AI attribution), takeover and handover;
- worker safety.

This file only overrides **routing** and **escalation**, and adds the Claude engine. Record the mode in `context.md` (`Mode: orchestra-claude`) so a takeover instance loads this skill.

## Roles

| Role | Model | Launcher `-Model` | Effort |
|---|---|---|---|
| Orchestrator: decisions, decomposition, final taste calls, accept/reject | Opus (this session) | none | none |
| Frontend, UI/UX, visual polish, copy, anything where taste matters | Sonnet | `sonnet` | high |
| Quality-sensitive coding: API design, tricky logic, security-relevant code | Sonnet | `sonnet` | high, or medium when well specified |
| Moderate, well-specified coding | Sonnet | `sonnet` | medium |
| Token-heavy grunt work: bulk edits, large refactors, test writing, migrations, log and data crunching, scouting big codebases | gpt-6.1-sol | `sol` | high |
| Computer use | gpt-6.1-sol | `sol -ComputerUse` | high |
| 3D and frontier work | gpt-6-astra | `astra` | high |
| Task reviews (`-Review`) | gpt-6-astra | default | high |
| Classification, triage, labeling, quick checks | gpt-6-luna or gpt-5.6-luna | `luna` / `luna56` | low or medium |

**Frontend is Sonnet 5.5 only.** In this mode, every task that touches UI goes to `sonnet` and never to sol or astra:
- markup, styles, components, layout, animation;
- UI copy;
- design-token changes;
- visual fixes.

sol may build non-UI support around it (APIs, data plumbing, fixtures, test harnesses), but UI files belong to Sonnet. Frontend Sonnet workers use `-Profile frontend` so they can take screenshots.

Launcher shorthands pin model IDs:
- `sonnet` = `claude-sonnet-5-5` (Sonnet 5.5, released 2026-09-28);
- `opus` = `claude-opus-5-5`;
- `fable` = `claude-fable-5-1`.

Haiku is not part of this mode.

When a newer model ships, update the mapping in `orchestra.ps1`. If `claude` rejects a model, run `claude update` first.

**Sonnet effort default is `medium`.** In the 2026-09-30 audit, Sonnet medium ran a median of 3.8 minutes with every task DONE and 1% tool failures, the most efficient worker measured. Sonnet high runs grew to 386k context and cost several times more per run. Use `high` only for design-critical frontend and hard judgment calls, one deliverable per brief.

Opus picks each Sonnet task's effort (`high` or `medium`) when writing the brief and states it in the brief's header.

**Budget rule.** Sonnet and Fable spend the same Claude usage window as Opus; GPT workers spend the separate ChatGPT quota.
- Anything big, mechanical, and non-UI goes to `sol`, even if Sonnet could do it. Frontend stays with Sonnet regardless of size.
- Sonnet gets the work where its judgment or taste is the point.
- For mixed non-UI work when unsure, split the task: `sol` does the bulk and Sonnet does the finishing pass.

## Escalation ladder (replaces orchestra's)

1. Worker FAILED or BLOCKED: fix the brief and resume once.
2. Fails again: fresh worker one tier up (sol to Sonnet high for judgment problems, or to astra high for hard or 3D problems).
3. Opus stuck, needs clarification, or wants a second opinion: `astra` consult (`templates/consult.md`) at `xhigh`. Use `ultra` or `max` for deep problems.
4. Still stuck on a very, very hard problem after astra: `fable` consult with the same consult template, plus the astra consult report under Context. Within an authorized orchestration task, this escalation needs no separate confirmation.
5. The decision is the user's (taste, scope, money, risk), or Fable did not resolve it: ask the user.

## Context watch

- The launcher reports context for every worker, Claude and GPT alike. At `HANDOFF-RECOMMENDED`, the next task goes to a fresh worker with the predecessor's report under Context. The threshold is 70% for GPT, and 200k tokens or 70%, whichever comes first, for Claude.
- Sonnet workers default to `-Profile lean` (about 34k starting context instead of 42k). Frontend tasks use `-Profile frontend`.
- Sonnet workers read `CLAUDE.md`/`AGENTS.md` and inherit any style rules configured there. Their reports follow `WORKER.md` like everyone else's.
- Do not resume a Sonnet worker for unrelated work just to reuse its warm cache. A fresh worker with a tight brief is cheaper than a bloated context.

## Dispatch is mandatory

Opus does not implement. It writes briefs, dispatches, reviews, and decides. The exceptions come from orchestra's rule: a one-line fix found during review, or a `context.md`/`progress.md` update.
