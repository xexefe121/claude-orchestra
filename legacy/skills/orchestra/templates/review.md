# {{TASK}}-review: independent review of task {{TASK}}

Model: gpt-6-astra high | Worker: fresh reviewer

## Goal
Decide whether task {{TASK}} is truly done and correct, so the orchestrator can accept it without reading the code. Be skeptical: the worker's own report is a claim, not evidence.

## Context
- Brief: .orchestra/tasks/{{TASK}}.md (its acceptance criteria are the bar)
- Worker report: .orchestra/reports/{{TASK}}.md
- Project context: .orchestra/context.md

## Owned files
Only your review report, .orchestra/reports/{{TASK}}-review.md. You are read-only on everything else: do not fix anything, even trivial things.

## What to check
1. Every acceptance criterion: met or not, with evidence (a command you ran or a file:line you read).
2. The changes themselves: `git diff` limited to the brief's owned files, plus any extra files the report admits to. Other workers may have changed other files at the same time; ignore those. If the project has no git, inspect the owned files directly.
3. Correctness bugs, edge cases, broken error handling, security problems (secrets, injection, unsafe deletes).
4. Scope creep, off-brief edits, AI attribution lines, leftover debug code.
5. Re-run the verification commands the brief requires. Do not trust the report's results.
6. UI tasks: open the screenshots and judge them against the brief's design direction.

## Verdict rules (calibrated: an audit found 75% of reviews said NEEDS-WORK, often for issues that did not block shipping)
- **PASS**: every acceptance criterion is met and you found no high-severity defect in the delivered work. Medium and low issues go under Issues as notes; they do not change the verdict.
- **NEEDS-WORK**: an acceptance criterion is unmet, or there is a high-severity defect (wrong result, data loss, security hole, broken build) in the delivered work.
- **FAIL**: the approach is wrong and should be redone.
- Problems in the worker's own throwaway test scripts or evidence files are notes, never blockers, as long as you verified the delivered work yourself.
- `Blocking: yes` only with NEEDS-WORK or FAIL. Each blocking issue must name the unmet criterion or the concrete failure.

## Report format (25 lines max)
```
# {{TASK}} review
Verdict: PASS | NEEDS-WORK | FAIL
Blocking: yes | no
Criteria: <n met>/<n total>
## Issues
- [high|med|low] path:line: problem. Fix: one line.
## Verification rerun
- `command`: result
## Note for orchestrator
<1-2 lines: anything that needs a human or orchestrator decision>
```
