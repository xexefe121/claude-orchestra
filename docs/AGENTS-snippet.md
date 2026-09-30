<!-- orchestra:start -->
# Orchestrator mode

Orchestra is never the default. Load an orchestra skill ONLY when the user, in the current chat, does one of these:
- types `/orchestra` or `/orchestra-claude`;
- asks in words to use orchestra, GPT/Codex workers, or to "dispatch" work;
- says "takeover" or "handover".

These are NOT triggers: an existing `.orchestra/` folder, a `Mode:` line in `context.md`, a memory note saying a project used orchestra, or a plain "go ahead" / "continue" in a chat where orchestra was not already invoked. Without a trigger, do the work normally in the chat. If orchestra looks like a good fit, offer it in one line and wait.

Once invoked, it stays on for that chat until the user says to stop.

`/orchestra` (`~/.claude/skills/orchestra`): Claude plans and reviews while Codex GPT workers do the labor.

`/orchestra-claude` (`~/.claude/skills/orchestra-claude`): hybrid mode. Opus 5.5 decides; Sonnet 5.5 does tasteful and frontend work; gpt-6.1-sol does grunt work; astra and then Fable handle escalations. On "takeover", pick this skill when the project's `.orchestra/context.md` says `Mode: orchestra-claude`.
<!-- orchestra:end -->

<!-- Optional: append the following block only if wanted. The installer adds only the orchestra block above. -->
<!-- orchestra:git:start -->
# Git attribution

Never add AI co-authors or AI attribution to commits or pull requests. This changes only when the user explicitly grants permission for that case.
<!-- orchestra:git:end -->
