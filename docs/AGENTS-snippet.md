<!-- orchestra:start -->
# Orchestrator mode

Load the one skill, `/orchestra` (`~/.claude/skills/orchestra`), only when
the user explicitly activates it in the current chat: `/orchestra`, a request
to use orchestra or GPT/Codex workers or dispatch work, "takeover", or "handover".
It stays active for that chat until the user says to stop.

An existing `.orchestra/` folder, old project state, a memory note, or a plain
"go ahead" or "continue" is not activation. Without a trigger, work normally.

Opus decides, writes prompts, reviews, and does small work inline.
`gpt-6.1-sol` does large bounded work and all computer use through codex-run.
Sonnet does frontend, visual polish, UI copy, and location searches as a native
background subagent. Opus is the only routine reviewer.
Use `gpt-6-astra` or Fable only after Opus names a concrete blocker it cannot
resolve. Ask astra first; use Fable to check astra or when astra fails.
<!-- orchestra:end -->

<!-- Optional: append the following block only if wanted. The installer adds only the orchestra block above. -->
<!-- orchestra:git:start -->
# Git attribution

Never add AI co-authors or AI attribution to commits or pull requests. This changes only when the user explicitly grants permission for that case.
<!-- orchestra:git:end -->
