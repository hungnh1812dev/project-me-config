---
name: session-handoff
description: The shared state files that carry knowledge between per-task agents - project profile, board, handoff, conventions, current unit record, findings, archive - with their formats, size limits, and who writes, reads, clears and archives each one. Use when the manager sets up a project or dispatches, closes a task or a phase, or when the user answers a question.
---

# Session Handoff

Every unit (task or batch) gets fresh agents, and the manager's message is only the task ID. Agents learn what to do from the files below. Nothing else carries over, so anything an agent needs must be written down here. All files live in `.claude/state/`. Rules for all: short, no pasted code or diffs, point to file paths.

**Live files hold only what is still open.** Finished work leaves them: git holds the code history, module READMEs and `docs/` hold the module details, and `archive/` holds the rest for later lookup. No agent reads `archive/` at start; grep it only when needed.

## Files

| File | Written by | Read by | Limit | Cleared / archived |
|---|---|---|---|---|
| `project.md` | manager, with the user | every agent, in full, at start | one line per item | never |
| `board.md` | manager | builders (grep the task's row); manager | active phases only | a phase moves to `archive/board-archive.md` when its checkpoint passes |
| `handoff.md` | builders; manager adds user answers | builders and planner, in full, at start | ~3 KB | a task's lines are removed when it is committed with all checks passed |
| `conventions.md` | builders | grep the needed section only | ~10 KB | stale or module-only facts move to `archive/conventions-archive.md` |
| `current.md` | builder of the unit (format in `worker-flow`) | checkers, manager | one unit | manager resets after the unit's last commit |
| `findings/<unit or phase>-<qc or security>.md` | the checker that failed | builder in a fix round | - | **that checker deletes it when its re-check passes** |
| `archive/*.md` | manager | nobody at start; grep on demand | - | never |

## project.md (project profile)

Created once per project by the manager, with the user. Every value comes from the user or the repo; never guess. One line per item.

```markdown
# Project Profile
Tasks: <file holding each task's acceptance/verify/files, and how to find one by ID>
Phases: <file holding each phase's goal/inputs/outputs/exit criteria, or none (flat list)>
Spec: <path, or none>
Scopes:
- core-builder: <paths>
- ui-builder: <paths>
- qc: <e2e test dir>
High-risk paths: <paths where any change gets a security review before commit>
Stack: <one line per scope>
Commands:
- install / build / type-check / unit test / integration test / format / dependency audit / run app: <command each, or n/a>
- dev stack (tier 2, `test-tiers`): <start / stop command and the URLs it serves, or n/a>
- full stack (tier 3): <start, kept-mode start, stop command and URLs, or n/a>
- e2e single spec: <command against a running stack, or n/a>
Tier 3 also when: <project paths or areas that need the full stack beyond the defaults in `test-tiers`, or none>
E2E tests: <dir and runner, or none>
Docs to keep current: <READMEs, API docs, ADR dir, env example file>
Security rules: <docs with this project's authz / audit / data rules, or none>
```

## board.md

```markdown
# Board - <project>
Source: <task file> · Spec: <path>
Decisions: <open or project-wide decisions, one line>
Open risks: <one line>

## Phase <n>: <name>
Base: <hash> · Phase checks: qc <pending|pass> · security <pending|pass> · Checkpoint: <pending|passed date>

| ID | Title | Scope | Status | Commit |
|---|---|---|---|---|

## Notes
- <only items still open for the active phases; at most ~10 lines>
```

No log. Events worth keeping go into a commit message, `handoff.md` (while open), or `conventions.md` (if lasting).

## handoff.md

```markdown
# Handoff
Updated: <YYYY-MM-DD> after <task ID>

## In progress / next
- <ID> <title> - <state, exact next step>
- <ID> user answers: <one line each>

## Direct requests
### DR<n> <title>
<the request-validator's brief, verbatim: goal, acceptance, verify, files>

## Follow-ups
- <item> -> <owner task, or unscheduled>
```

`Direct requests` holds the task entries for requests the request-validator routed straight to a builder (no planner task file). The manager writes each brief before dispatch and removes it when the task is committed, like the task's other lines.

Only unfinished work: tasks not yet committed or with checks pending, user answers for those tasks, and open follow-ups. No `Done` list (the board and git have it).

## conventions.md

Cross-cutting knowledge every builder may need, one line per fact, grouped under: Tooling, Testing & smoke, Frontend, Backend, User decisions in force, Gotchas. Module structure and API details belong in the module's README / `docs/modules/`, not here.

## Findings files

`findings/<unit>-qc.md` or `findings/<unit>-security.md` for a unit; `findings/<phase>-qc.md` or `findings/<phase>-security.md` for the end-of-phase checks; `findings/audit-<YYYY-MM-DD>-qc.md` for an audit. Written only when a check fails, overwritten on each failed re-check. Each finding: severity, scope that owns the fix (`core-builder` / `ui-builder`), what is wrong, where (`file:line`), repro or evidence, suggested fix. When the re-check passes, the checker that wrote it deletes it, so later agents never read resolved issues.

## Who does what

| When | Who | Action |
|---|---|---|
| New project | manager | Creates `project.md` with the user, plus empty board and handoff |
| Phase starts | manager | Writes `Base: <HEAD hash>` under the phase heading on the board |
| Before dispatch | manager | Sets the board row to `in-progress`; makes sure every decision the task needs is in handoff.md or conventions.md |
| Unit finished | builder | Completes `current.md`; adds its line and follow-ups to handoff.md; adds cross-cutting facts to conventions.md |
| User answers a question | manager | Writes the answers under `In progress / next` before resuming the agent |
| Check passes | checker | Deletes its own findings file for the unit, if one exists |
| Commit made | manager | Records the hash on the board; moves lasting user answers to conventions.md "User decisions in force" (one line each); **removes the task's lines from handoff.md**; after the unit's last commit, resets `current.md` |
| Phase ends | manager | Runs qc `REGRESSION` then security-qc `PHASE`; writes the results under the phase heading |
| Checkpoint passes | manager | **Moves the phase section to `archive/board-archive.md`**; clears its Notes; moves stale conventions to `archive/conventions-archive.md` |
| handoff.md over ~3 KB or conventions.md over ~10 KB | manager | Trims: closed items out of handoff; module-only or stale facts from conventions into the archive |
