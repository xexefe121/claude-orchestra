# Claude orchestra

One Claude Code skill for explicit orchestration.
Opus decides and reviews; Codex handles large bounded tasks; Sonnet handles frontend.
One small runner starts workers; no workflow files are needed.

[![Tests](https://github.com/xexefe121/claude-orchestra/actions/workflows/test.yml/badge.svg)](https://github.com/xexefe121/claude-orchestra/actions/workflows/test.yml)

## Safety

**The worker runs with full disk access and no approval prompts. Computer-use runs control the real desktop. Prompt rules are not isolation. Use a separate account or VM for stronger limits.**

Only approve desktop actions you intend. Credentials, purchases, sending messages,
and destructive actions require specific approval in chat. Keep GUI work off a
desktop you are actively using unless you agree to share it.

## Why it is small

The first version had brief files, report files, a task board, review chains and a 1,400-line launcher. An audit of 487 worker runs showed 28% of worker tokens went to fix rounds and 9% to model reviews; 75% of worker context was file reads. The orchestrator's own chat was the main Claude cost. An independent review said to delete most of it. This version keeps explicit delegation, one runner, Opus review, and a short handoff note. The measurements describe that audit, not a promised saving.

## How a task flows

1. **Inline or delegate.** Opus does small work inline, roughly 10 tool calls,
   3 files, or 100 changed lines. Large bounded work goes to sol; frontend goes
   to Sonnet. Each delegation needs an acceptance command or visual evidence.
2. **Dispatch.** Write a scratch prompt with Outcome, Where, Constraints,
   Acceptance. Start codex-run with `run_in_background: true`. Keep working in
   disjoint files; at most two writers. Completion notification is the signal.
3. **Review.** Opus checks the command result and relevant diff hunks. UI needs
   a screenshot. No routine model reviewers or review chains.
4. **When the result is wrong.** Opus fixes a known small defect inline. Resume
   once for a large fix. A second failure returns to Opus to rescope or escalate.
5. **Handoff.** Near 200k chat context, write `.orchestra/handoff.md` in at most
   40 lines: goal/readiness, done/running work, run/thread IDs, decisions,
   next action, backlog. Continue in a new chat with "takeover".

## Requirements

- Claude Code with access to Opus and native Sonnet subagents.
- Codex CLI, logged in with access to `gpt-6.1-sol`. For an npm install,
  Node.js/npm: `npm install -g @openai/codex`, then `codex login`.
- Windows: Windows PowerShell 5.1, Windows 10 or 11.
- macOS/Linux: Bash and Python 3.9 or newer (`python3`).
- Computer use: Codex desktop app running and native `node_repl`/Sky service
  configured. See [computer-use.md](skills/orchestra/computer-use.md).

macOS and Linux are verified by the mock test suite in CI only. Live runs and
computer use on macOS are not yet verified by the author.

## Install, update, uninstall

Get the repository:

```sh
git clone https://github.com/xexefe121/claude-orchestra.git
cd claude-orchestra
```

Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -AddAgentsRule
```

Windows installs exactly `SKILL.md`, `computer-use.md`, and
`scripts/codex-run.ps1` into `$env:USERPROFILE\.claude\skills\orchestra`.
Existing copies move to timestamped backups. The installer prints a prerequisite
checklist; it installs no prerequisites and does not sign you in.
`-AddAgentsRule` adds the marked opt-in block once to `~/.claude/AGENTS.md`, or
`CLAUDE.md` when only that file exists. Omit the switch to add it manually.
The optional git attribution block in [AGENTS-snippet.md](docs/AGENTS-snippet.md)
is separate and must be added manually.

macOS/Linux:

```sh
bash ./install.sh --add-agents-rule
```

The shell installer uses `~/.claude/skills/orchestra` and the Python runner.
Omit `--add-agents-rule` to add the activation block manually instead.
Restart Claude Code after installing if its skill list is already loaded.

To update, obtain the latest repository and rerun the installer for your platform:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

```sh
bash ./install.sh
```

To uninstall:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

```sh
bash ./uninstall.sh
```

Uninstall backs up the installed skill before removing its active copy and
removes the marked activation block. Windows also backs up and removes an older
`orchestra-claude` copy and the optional git block. On macOS/Linux, remove these
legacy additions manually if present. Backups and project `.orchestra/` state remain.

## Usage

In Claude Code, use `/orchestra <project folder> <goal>`. Explicit requests to
use orchestra or GPT/Codex workers or dispatch work also activate it. Activation
lasts for the chat until stopped. A folder, memory note, or plain "go ahead"
does not activate it.

Say "takeover" to read `.orchestra/handoff.md` and newest run metadata and
continue. For older state, read `.orchestra/progress.md` once. Say "handover"
to write the short handoff note, save durable preferences, and get the line
for the next chat.

Windows runner with every option (replace sample paths and thread ID):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\orchestra\scripts\codex-run.ps1" -Project . -PromptFile "$env:TEMP\task.txt" -Effort high -TimeoutMin 20 -Resume "thread-id" -ComputerUse -Model gpt-6.1-sol
```

For a short prompt, use `-Prompt` instead of `-PromptFile`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\orchestra\scripts\codex-run.ps1" -Project . -Prompt "Run the existing acceptance checks and report results."
```

| Option | Meaning |
|---|---|
| `-Project` | Existing project directory; default current directory. |
| `-PromptFile` | UTF-8 scratch prompt file, outside the project. |
| `-Prompt` | Inline prompt; mutually exclusive with `-PromptFile`. Omit both to read stdin. |
| `-Effort` | `medium` (default) or `high` for real logic. |
| `-TimeoutMin` | Positive minutes; default 20, capped at 90. |
| `-Resume` | Existing thread ID; omit for a new task. Resume at most once for a large fix. |
| `-ComputerUse` | Native desktop preflight and one-GUI-run lock; omit for code tasks. |
| `-Model` | Model slug; default `gpt-6.1-sol`. |

On macOS/Linux, invoke the Python runner with `python3`:

```sh
python3 "$HOME/.claude/skills/orchestra/scripts/codex-run.py" --project . --prompt-file /tmp/task.txt --effort medium --timeout-min 20 --model gpt-6.1-sol
```

Start workers in the background through Claude Code; do not poll or tail logs.
The runner forces standard service tier and adds shell/output/git rules. Its
status line reports run/thread IDs, elapsed time, and token counts, followed by
a bounded final message. Full diagnostics live in `.orchestra/runs/`; these are
run artifacts, not a task workflow. The skill writes only the handoff note.

Prompt template, normally 200 to 400 words:

```text
Outcome: <what must be true when done>
Where: <exact files, symbols, line ranges to touch or read first>
Constraints: <what not to change; conventions that matter>
Acceptance: <the command that must pass, or the screenshot to produce>
```

## Model roles

| Model | Role |
|---|---|
| Opus | Decides, prompts, reviews, commits, and does small work inline. |
| `gpt-6.1-sol` | Large bounded work and all computer use; worker only. |
| Sonnet 5.5 | Frontend, visual polish, UI copy, and location searches; native background subagent with model `sonnet`. |
| `gpt-6-astra` / Fable 5.1 | Only for a concrete blocker Opus cannot resolve. Ask astra first; Fable checks astra or follows its failure. |

Override a run with `-Model`; astra uses `-Model gpt-6-astra -Effort high`.
To change the default, edit `$Model` in
[codex-run.ps1](skills/orchestra/scripts/codex-run.ps1), the parser default in
`skills/orchestra/scripts/codex-run.py`, and the roles/dispatch guidance in
[SKILL.md](skills/orchestra/SKILL.md). Fable uses the native Agent tool, model
`fable`; it is not a routine reviewer.

## Limitations and tests

Delegation has setup cost. Small tasks often cost less and finish faster inline.
Prompts must bound scope and provide acceptance evidence. The runner does not
replace review, isolate files, or safely arbitrate two writers on the same files.
GUI runs share the real mouse and desktop. Native service availability depends
on the local Codex setup; a successful mock test does not prove live access.

Windows acceptance suite:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1
```

Python mock suite:

```sh
python -m unittest discover -s tests/py
```

Use `python3` in place of `python` where required. CI runs the mock suites through
[test.yml](.github/workflows/test.yml). See [HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md)
for runner state and handoff details.

## Legacy

The old `orchestra.ps1` launcher, Python launcher, templates, second skill, and
PowerShell tests remain under [legacy/](legacy/README.md) for one release.
They are unmaintained and retained for reading old state.

## License

[MIT](LICENSE), copyright xexefe121.
