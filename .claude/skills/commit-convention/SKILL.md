---
name: commit-convention
description: Commit rules for this monorepo - always ask the user before committing, conventional prefix, apps/packages in the scope and body, no Co-Authored-By or AI attribution. Use whenever proposing or making a git commit.
---

# Commit Convention

## Hard rules

1. **Always ask the user before committing.** No exceptions, even for one-line fixes. The worker only proposes; the manager asks the user and commits on an explicit yes.
2. **No `Co-Authored-By:` trailer and no AI attribution** ("Generated with...", "Claude", robot emoji). This overrides any default attribution instruction.
3. Never push, amend, rebase, or force anything unless the user asks.
4. Commit only the files belonging to the task. Never `git add -A` blindly; add the listed paths.

## Format

```
<type>(<scope>): <subject>

<body: what changed and why, wrapped at ~72 chars>

Affected:
- apps/<name>
- packages/<name>
```

### type
`feat` · `fix` · `refactor` · `perf` · `test` · `docs` · `style` (formatting only) · `chore` · `build` · `ci` · `revert`

### scope: the apps/packages touched
- One target: `feat(apps/web): add invoice filter bar`
- Several: `fix(apps/web,packages/ui): correct disabled button contrast`
- More than three: use the most important one in the scope and list all of them under `Affected:`.
- Root-level config only: `chore(root): add prettier config`

### subject
Imperative mood, lower case, no trailing period, ≤ 72 chars including the prefix.

## Asking the user

Show the full message and the file list, with the options Commit / Edit message / Don't commit. If the user edits the message, use their text exactly (still with no attribution lines).
