# Computer use through Codex workers

Headless `codex exec` workers can control the real desktop when the native
MCP service is configured. Use codex-run with `-ComputerUse`.

- Native control comes from the `node_repl` MCP server in `~/.codex/config.toml`:
  tool `mcp__node_repl__js`, import `const {sky} = await import('@oai/sky')`,
  then call `sky.list_windows()` before using the rest of the Sky API.
- The unified plugin's `cua_repl` is browser-only. It can report "native APIs
  disabled" and `apps: []`. The codex-run `-ComputerUse` prompt names the native
  tool and requires the Sky preflight. If unavailable, stop with
  `BLOCKED: native CUA unavailable`; do not substitute browser control.
- The Codex desktop app hosts the native control pipe and must be running.
  The Windows runner checks this before starting.
- Only one GUI run may control the desktop at a time. The Windows runner holds
  a machine-wide mutex throughout `-ComputerUse` runs. Parallel native requests
  can fail with "Computer Use helper already has an active request".
- Dispatch in the background, for example:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\orchestra\scripts\codex-run.ps1" -Project . -PromptFile "$env:TEMP\desktop-task.txt" -Effort high -ComputerUse
```

Give each run one goal. The prompt must name the app, exact end state, what
not to touch, and where to save the end-state screenshot. Require that screenshot
path in the final message. No briefs or report templates are needed.

Workers have full disk access and no approval prompts. Prompt rules are not
isolation. Do not handle credentials, make purchases, send messages, or perform
destructive actions unless the user approved that specific action in chat.
Avoid GUI work while the user is using the desktop unless they agreed.
Use a separate account or VM for stronger limits.

Running a task inside the Codex app's GUI has no supported turn-injection API;
`codex://threads/new` only prefills the composer. Use headless native control.
Live runs and computer use on macOS are not yet verified by the author.

- **Websites are different.** For work inside a web page, do not use `-ComputerUse`. Tell the worker to use its Chrome browser tool, which can read the page URL. Native desktop control refuses to act in a browser window when it cannot verify the URL (seen 2026-10-01). The Chrome tool path set up a Codemagic build in about 3 minutes.
