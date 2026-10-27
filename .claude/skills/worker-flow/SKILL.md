---
name: worker-flow
description: The pipeline every builder agent (core-builder, ui-builder) runs for a task - load the task from the state files, implement, unit test, docs, write the unit record, report - plus the rules all builders share. Project-agnostic; project specifics come from .claude/state/project.md. Preloaded by the builder agents.
---

# Worker Flow (builders)

Run these steps in order for every task. Your agent file says which skills you may load at each step; load each one only when you reach its step, and no others. Do not move on until the step's exit check passes. Browser testing and the security review are done by other agents, working from your `current.md`. The state files you write and their formats are under "State files" below.

## 1. Load the task
The manager's message is only `TASK <ID>` (or `BATCH: ...`) plus optional notes. Find out what to do from the files, reading only what you need:

1. `.claude/state/project.md`: in full. It names the task source, spec, your scope, stack, and commands.
2. `.claude/state/board.md`: grep the task's row, plus the decision lines at the top.
3. The task source from `project.md`: that task's entry only (acceptance, verify, files, dependencies, spec refs). For a direct request (`DR<n>`), the entry is its `### DR<n>` brief under `## Direct requests` in `handoff.md`; it has no spec refs.
4. `.claude/state/handoff.md`: in full (it is short). Take the user answers, provisional decisions, and follow-ups that name this task.
5. The spec: only the sections the task entry cites. Never the whole file.
6. `.claude/state/conventions.md`: grep only the section for your area, when you need it. For the history of a finished area, grep `.claude/state/archive/` (never read it in full).
7. The code and docs for the files the entry lists. Module details live in each module's README / `docs/modules/`, not in the state files.

Then restate the goal and acceptance criteria in 2-3 lines (for yourself). If the files disagree, `project.md` lacks something you need, or you would have to make an assumption that matters, **stop and report `blocked`** with questions. Do not guess.

Overwrite `.claude/state/current.md` with the unit header (`# Current Unit: <unit>`), unless you are the second builder of the same task: then add your section below the first builder's.

Exit: every acceptance criterion is clear and testable.

## 2. Plan
Before the checklist, check your approach against the design principles in `code-standards` section 4, and write 1-3 lines for yourself:
- **Ownership:** which module owns this responsibility. Does it already exist somewhere? Extend it instead of duplicating it.
- **Naming:** the main new names (modules, functions, fields). Are they clear without comments?
- **Extension:** how the next similar feature would be added, and in how few places.
- **Files:** the files you will add or change, checked against `code-standards` §4.4 (one file per use case, one ports and one constants file per layer, no file under 30 lines, at most 6 files per new endpoint). Do not copy a finer split from older code.

Then make a short subtask checklist (vertical slices, each verifiable on its own).

Exit: no responsibility is duplicated across modules, and the next variant can be added without editing unrelated modules.

## 3. Implement
- Follow `code-standards` (no hardcoding, config and tokens only, design principles in section 4).
- Name new files and folders by `code-standards` §4.5 and the project's naming document (`Naming:` in `project.md`, if present); list each word that document does not yet have, and each file you left without a word where neighbours carry one, in the unit record.
- One slice at a time: build, run, then the next slice.

Exit: all subtasks implemented; the build and type-check commands from `project.md` pass.

## 4. Unit test
- Cover the acceptance criteria, edge cases, and error paths. For bugs, write a failing test first.
- Run the whole affected package's test suite, not just the new tests.

Exit: all tests pass. Note the count.

## 5. Docs
- Update the docs `project.md` lists as "Docs to keep current" for what you changed, including the env example for new config keys (names and descriptions only, never real values).
- Write an ADR only for a non-obvious architectural decision.

Exit: docs match the code.

## 6. Finish
1. Re-read your diff against `code-standards` section 4: no duplicated responsibility, no `what` comments that a better name would replace, no new edits scattered across unrelated modules, no file split finer than §4.4 allows. Fix what you find.
2. Run the format command on the changed files (see `code-standards`).
3. Re-run the tests if formatting changed anything.
4. Write the proposed commit message (`commit-convention`).
5. Complete your task section in `current.md`. Be precise in "Behaviour to verify" and "Security-relevant": the checkers test and review only what you list there plus the diff. Set these two fields by rule, not by feel:
   - `Checks needed`: `qc-browser (<flows>)` when the task changes something a user sees in a page; `qc-cli (<e2e/API tests>)` when it changes behaviour with no UI output (endpoint, data, CLI); `none (<reason>)` only for docs, comments, or tooling with no runtime effect. Add the test tier from `test-tiers` (preloaded) with its reason, e.g. `qc-cli tier 1 (behavior-preserving move; integration suite)` or `qc-browser tier 3 (cookie flags changed)`. Pick the lowest tier the rules allow.
   - `Risk: high (<why>)` when the task touches a high-risk path in `project.md`, has `Security gate: yes` in its task entry, or adds or changes auth, sessions, tokens, crypto, permissions, raw SQL built from input, file upload, or payments. Otherwise `Risk: normal`.
6. Update `handoff.md` and `conventions.md` (rules under "State files").
7. Return the report.

## Batches

If the message starts with `BATCH:`, load the shared files once, then run steps 1-6 for each task in order, one `current.md` section per task. Keep each task's changes to its own files where you can. If two tasks must change the same file, note it in the second task's section so the manager can ask the user how to commit them. If a task ends `blocked` or `failed`, stop there and do not start the remaining tasks.

## Fix rounds

The manager sends `FIX <unit>: <findings file>` (or `FIX <phase>: ...` after the phase checks: fix only the findings tagged with your scope, and start a fresh `current.md` named `<phase>-fix`). Read that file, fix each finding within the task scope, re-run steps 4 and 6 (steps 1-4 of Finish), and add a line per finding to the `Fix log` in `current.md`. Do not delete the findings file; the checker does that when its re-check passes. If a finding needs a design change or is outside the scope, report `blocked` instead of working around it.

## State files

All in `.claude/state/`. Short, no pasted code or diffs, point to file paths.

`current.md` (unit record): overwrite it at the start of a unit, complete it at finish, add to the fix log after each fix round. Checkers test and review only what it lists. One section per task in a batch:

```markdown
# Current Unit: <unit>
## <ID> <title>
Status: ready-for-checks | blocked | failed
What was built: <2-4 lines, by feature>
Changed files:
- <path> - <what changed, a few words>
Behaviour to verify:
- <user flow or endpoint> - <expected result>
Security-relevant: <new endpoints, auth/permission paths, input handling, new deps, or none>
Checks needed: qc-browser tier <1-3> (<flows>) | qc-cli tier <1-3> (<tests>) | none (reason)
Risk: high (<why>) | normal
Verification: format <pass|n/a> · build/type-check <pass|fail> · unit tests <pass (n)|fail> · docs <paths|n/a>
Proposed commit: |
  <message per commit-convention>
Deletions needing approval: <list or none>
Fix log:
- round <n>: <finding> -> <what changed>
```

Keep the fix log to one line per finding.

`handoff.md`: holds only unfinished work. At finish, put one line for your task under `In progress / next` (`<ID> <title> - awaiting checks/commit; next: <step>`) and add follow-ups you found under `Follow-ups` (`<item> -> <owner task or "unscheduled">`). Never add history; the manager removes the lines when the task is committed.

`conventions.md`: only cross-cutting facts every builder needs (tooling, test setup, gotchas, user decisions still in force), one line each, under the matching section. Module structure and API details go into that module's README or `docs/modules/`, not here.

## Rules

- You have no channel to the user. When something is unclear, stop that part of the work and report `blocked` with numbered, concrete questions, with options and your recommendation where you have one.
- You never commit. Stage nothing; propose the commit message.
- Never read or edit `.env*` files (except `.env.example`). For values a dev server or script needs locally, use the agent-local `.localEnv.agent` under the rules in `test-tiers` (check it is ignored first; never `git add` it).
- Never delete files. List them under "Deletions needing approval" in `current.md`.
- Never touch code outside the task scope or outside your scope in `project.md`. If the task needs the other builder's scope, say so in the report.
- Never add `Co-Authored-By` or any AI attribution to commit messages.

## Report (your final message is this block only)

Details live in `current.md`; do not repeat them here. No greeting, no narrative, no code.

```
BUILD REPORT
unit: <unit>
status: ready-for-checks | blocked | failed     (per task for a batch: <ID> <status>)
record: .claude/state/current.md
questions: <numbered list, only when blocked>
```
