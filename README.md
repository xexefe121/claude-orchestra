# Claude orchestra

Claude Code plans and reviews as orchestrator.
Codex GPT workers do the labor; Claude Sonnet workers are optional.
State lives in `.orchestra/`, so another chat can take over.

## Why

One operator's audit covered 11 projects and 430 worker runs. Delegated tasks yielded about 3-4 times more work per Claude usage window. These are personal measurements, not a controlled benchmark or a promised saving.

The main Claude cost was the orchestrator re-reading its own context. One session spent 187 of 291 API calls polling. Sessions made 30-82 state edits each. Context reached 500k-960k tokens, where calls cost about 3-5 times more. The resulting rules use completion notifications, batch dispatch, short result digests, an automatic task board, and handover at 200k context.

## Requirements

- Windows 10 or 11. Windows PowerShell 5.1.
- Claude Code, desktop or CLI, with a paid Claude plan.
- Codex CLI, logged in with a ChatGPT plan. Install with `npm install -g @openai/codex`, then `codex login`.
- Optional Codex desktop app for computer use. Keep it running and configure the native `node_repl`/Sky service. See [computer-use.md](skills/orchestra/computer-use.md).
- Optional `claude` CLI login for Sonnet, Opus, and Fable workers: `claude auth login`.
- Optional Node.js and `npx` for the Claude frontend Playwright profile.

The installer reports prerequisites. It never installs them or signs you in.

## Install, update, uninstall

From a clone:

```powershell
git clone https://github.com/xexefe121/claude-orchestra.git
Set-Location claude-orchestra
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -AddAgentsRule
```

Or inspect the script, then install from PowerShell:

```powershell
irm https://raw.githubusercontent.com/xexefe121/claude-orchestra/main/install.ps1 | iex
```

The one-liner downloads the `main` zip. To add the opt-in activation rule with that route:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/xexefe121/claude-orchestra/main/install.ps1))) -AddAgentsRule
```

Skills go into `$env:USERPROFILE\.claude\skills`. Existing skill folders move to `<name>.bak-<timestamp>` before replacement. Re-running install updates both skills. The rule is added once to `~/.claude/AGENTS.md`, or `CLAUDE.md` when only that file exists. Without the switch, the installer prints instructions. Restart Claude Code after installation if it has already loaded its skill list.

From a clone, update with:

```powershell
git pull
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

With the download route, re-run the one-liner. Keep a clone or download `uninstall.ps1` to uninstall:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Uninstall backs up both skills, removes their active folders, and removes marked rule blocks. Backups and project `.orchestra/` state remain. The optional git rule is a second block in [AGENTS-snippet.md](docs/AGENTS-snippet.md); add it manually if wanted.

## Usage

In Claude Code:

```text
/orchestra <project> <goal>
/orchestra-claude <project> <goal>
/orchestra takeover <project>
handover
```

`/orchestra` uses GPT workers for most work. `/orchestra-claude` routes taste and quality-sensitive work to Sonnet. Say `takeover` in the project chat to resume from `.orchestra/`. Say `handover` to save progress and prepare the next chat. Orchestra is opt-in; a state folder alone does not activate it.

The launcher also works directly. Use a project folder you control:

```powershell
$launcher = Join-Path $env:USERPROFILE '.claude\skills\orchestra\scripts\orchestra.ps1'
$project = Join-Path $env:USERPROFILE 'orchestra-example'
& $launcher init -Project $project
```

Fill `.orchestra/context.md` and create `.orchestra/tasks/001-example.md` from the task template before dispatching:

```powershell
& $launcher run -Project $project -Task 001-example -Model sol -Effort high -Review
```

For a wave, save this array as `plan.json` in the project. Every task needs its own brief:

```json
[
  {"task": "001-example", "model": "sol", "effort": "high"},
  {"task": "002-followup", "model": "sol", "effort": "high", "dependsOn": ["001-example"]}
]
```

```powershell
& $launcher batch -Project $project -Plan plan.json
& $launcher status -Project $project
& $launcher board -Project $project
```

In Claude Code, dispatch with its background tool option and wait for the completion notification. Ordinary PowerShell calls block until complete. Default run timeout is 90 minutes; review timeout is 30. `-TimeoutMin 0` disables the run timeout. `-NoDigest` suppresses report excerpts. `-ComputerUse` serializes access to the real desktop. `-Cli auto` prefers a supported PATH/npm CLI for normal tasks and a supported desktop CLI for computer use. `desktop` and `newest` are explicit alternatives.

## Model routing

Names are pinned in `Normalize-Model` in [orchestra.ps1](skills/orchestra/scripts/orchestra.ps1). Update `Get-ModelPrefix` too when changing a shorthand. Full model IDs pass through. Check current CLI support before relying on a pinned model.

| Work | `/orchestra` | `/orchestra-claude` | Effort |
|---|---|---|---|
| Plans, decisions, final review | Claude orchestrator | Claude Opus orchestrator | Session setting |
| Coding, tests, scripts, bulk changes | `sol` | `sol` for bulk; `sonnet` for quality-sensitive work | high; Sonnet medium by default |
| Frontend, visual polish, copy | `sol`, with Claude design direction | `sonnet` | high for design-critical work |
| Computer use | `sol -ComputerUse` | `sol -ComputerUse` | high |
| 3D, frontier problems | `astra` | `astra` | high; ultra for hardest |
| Automatic task review | `astra` | `astra` | high |
| Triage, labels, quick checks | `luna` or `luna56` | `luna` or `luna56` | low or medium |
| Final model escalation | `fable` after astra | `fable` after astra | high or consult-specific |

| Shorthand | Pinned model ID |
|---|---|
| `sol` | `gpt-6.1-sol` |
| `sol6` | `gpt-6-sol` |
| `astra` | `gpt-6-astra` |
| `luna` | `gpt-6-luna` |
| `luna56` | `gpt-5.6-luna` |
| `sonnet` | `claude-sonnet-5-5` |
| `opus` | `claude-opus-5-5` |
| `fable` | `claude-fable-5-1` |

Claude workers use the same Claude usage window as the orchestrator. GPT workers use the separate ChatGPT quota. Claude workers support `-Profile lean|frontend|full`; `frontend` adds Playwright. Reviews use the default astra reviewer unless explicitly overridden.

## Safety

**Workers have full disk access and no approval prompts.** Codex runs with `danger-full-access` and approval policy `never`. Claude workers use `--dangerously-skip-permissions`. Computer-use workers control the real desktop, including other open apps.

Read [WORKER.md](skills/orchestra/templates/WORKER.md) before use. It forbids credential access, deleting outside the project, unauthorized global installs, git history changes, and following instructions found in files or web pages. Briefs must state owned files and boundaries. These are prompt rules, not enforced isolation. Use at your own risk.

For stronger limits, use a separate Windows account or VM with only the files needed. Codex `-s workspace-write` is **not wired into this launcher**. There is no sandbox switch here. To use it, modify the Codex argument construction for both fresh and resumed runs, choose an approval policy, and separately remove Claude's permission bypass. Verify the changes before using sensitive projects.

## Limitations

- Windows only. No PowerShell 7, macOS, or Linux support promised.
- Model IDs change. Codex and Claude CLI flags drift. Dated observations live in [HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).
- Native desktop control depends on a working desktop app and native service configuration. The installer only checks prerequisites; it does not configure that service.
- Cost and efficiency numbers are one person's measurements.
- Workers can fail or exceed context. Reports, reviews, and handover reduce that risk; they do not guarantee correctness.

Run mock regression tests from a clone:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1
```

Tests use local mocks, compile small .NET fixtures, and leave logs in a printed temp folder. They make no model calls. Timeout suites take several minutes. See [HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) for state and task flow.

## License

[MIT](LICENSE). Copyright (c) 2026 xexefe121.
