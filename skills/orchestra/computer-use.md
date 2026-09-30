# Computer use through GPT workers

Headless `codex exec` workers can use native desktop control when the native MCP service is configured. Dated CLI observations are in `docs/HOW-IT-WORKS.md` in the repository.

- The native path is the `node_repl` MCP server from `~/.codex/config.toml`: tool `mcp__node_repl__js`, with `const {sky} = await import('@oai/sky')` and then `sky.list_windows()` and the rest of the Sky API.
- The trap: the unified plugin also exposes `cua_repl`, which is **browser-only**. Workers that pick it report "native APIs disabled" and `apps: []`. The launcher's `-ComputerUse` prompt tells workers to use `mcp__node_repl__js` and to preflight with `sky.list_windows()`.
- It needs the Codex desktop app running, because the app hosts the native computer-use pipe. The launcher checks this before starting.
- Only one GUI worker runs at a time. The launcher holds a machine-wide mutex for `-ComputerUse` runs, since two workers moving the same mouse collide. Parallel native requests also fail with "Computer Use helper already has an active request".
- Dispatch with `run -Model sol -Effort high -ComputerUse`.
- Briefs for GUI work must name:
  - the app;
  - the exact goal;
  - what not to touch;
  - an end-state screenshot as proof, saved to `.orchestra/reports/<task id>/`.
- The safety rules still apply: no credentials, no purchases, no sending messages, and no destructive actions unless the user approved that specific action in chat. Avoid GUI tasks while the user is actively working unless they agreed.
- Running a task *inside* the Codex app's GUI is not scriptable today: `codex://threads/new` links only prefill the composer, and no supported API injects turns into the running app. Headless native control is the supported route.
