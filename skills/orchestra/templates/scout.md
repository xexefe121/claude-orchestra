# NNN-scout: map <area> for the orchestrator

Model: gpt-6-astra xhigh (large or unfamiliar codebase) or gpt-6-sol high (small one) | Worker: fresh scout

## Goal
Give the orchestrator a compact, accurate picture of <area> so it can plan without reading the code itself.

## Questions to answer
<!-- e.g. How does X flow end to end? Where would feature Y plug in? What breaks if Z changes? -->

## Owned files
Only .orchestra/reports/NNN-scout.md. You are read-only on everything else.

## Report format (80 lines max)
```
# NNN scout
## Answers
<one short section per question, with file:line anchors>
## Map
- path: purpose (only the paths that matter)
## Build, run, and test
<exact commands, verified by running them when cheap>
## Risks and traps
## Suggested context.md lines
<lines the orchestrator can paste into context.md verbatim>
```
