---
name: code-standards
description: Project code rules - run Prettier after every finished feature and before any commit, no hardcoded values, never guess (ask instead), and the design principles (isolated modules, names over comments, extensible with minimal impact, few cohesive files per module). Use whenever planning, writing or changing code in this project.
---

# Code Standards

## 1. Prettier after every finished feature

Run this before proposing a commit, every time:

1. Use the project's script if there is one (`format` / `prettier` in the root or package `package.json`), run with the package manager that matches the lockfile (`pnpm-lock.yaml` → pnpm, `yarn.lock` → yarn, `bun.lockb` → bun, `package-lock.json` → npm).
2. Otherwise run Prettier on the changed files only: `<pm> exec prettier --write <files>`.
3. If Prettier is not set up in the project at all, **ask** (via a `blocked` report) before adding it or a config. Do not invent a config.
4. Then run lint and type-check if the project has them.

## 2. No hardcoding

Never write these as literals in the code:

| Kind | Where it belongs |
|---|---|
| URLs, ports, hosts, API keys, feature flags | env config, read through one typed config module; key names documented in `.env.example` |
| Colors, spacing, radii, shadows, font sizes | design tokens / theme (CSS variables or Tailwind theme) |
| User-facing text | the project's i18n / copy module, if there is one; otherwise ask how copy should be handled |
| Magic numbers (limits, timeouts, page sizes) | named constants in a constants / config module |
| Routes, API paths | one route / endpoint map |
| Mock or sample data | test fixtures only, never in production code paths |

Allowed: `0`, `1`, `-1`, empty string, and literals that are obviously self-describing in context (e.g. array index math).

## 3. Never guess. Ask.

If any of these is unclear, stop and ask (the worker reports `blocked`, the manager asks the user):

- Requirement or acceptance-criterion ambiguity
- Naming of public APIs, routes, DB fields
- Design values that are not already in the tokens
- Library or framework choice not already in the repo
- Env values, credentials, third-party endpoints
- Whether to delete or rename existing code

Give options and a recommendation with the question so the user can answer fast.

## 4. Design principles: think before you build

Before planning or writing code, check the approach against these four. If one of them cannot be met without a design change outside the task, report `blocked` with options instead of compromising silently.

### 4.1 Isolated modules, one owner per responsibility

- Each module owns one responsibility and exposes it through a small public interface; other modules use that interface, never its internals.
- Before adding logic, search for where that responsibility already lives. Extend the owner; do not re-implement the same behaviour in a second module.
- Keep dependencies one-directional. No circular imports, no reaching into another module's private files or tables.
- Shared logic goes into one shared module that both sides depend on, not into copies.

### 4.2 Readable code: names over comments

- Names say what a thing is or does: `expiresAt`, `isPublished`, `findActiveSessionsByUser()`, not `data`, `tmp`, `flag`, `handle()`.
- Booleans read as questions (`is`, `has`, `can`, `should`); functions start with a verb; units go in the name when they matter (`timeoutMs`).
- If you need a comment to explain *what* code does, rename or extract a well-named function instead.
- Comments are for what names cannot say: *why* a non-obvious choice was made, a constraint, a workaround with its reason. Public interfaces may keep their doc comments.
- Keep functions short and at one level of abstraction.

### 4.3 Extensible with minimal impact

- Adding a new variant (a type, provider, field, role, screen) should mean adding code in one place, not editing many files. Prefer registries, maps, and interfaces over growing `if`/`switch` chains spread across modules.
- Depend on interfaces and config, not on concrete implementations, where a second implementation is realistic.
- Changes to an existing public interface are additive (new optional fields or parameters) wherever possible, so existing callers keep working.
- Do not build for imagined future needs. Leave a clean extension point; do not implement the extensions.

### 4.4 File granularity: few, cohesive files a reviewer can read

Code is reviewed by people reading a diff. Split by layer (where the project has layers), then by use case; never by kind of thing (types, constants, ports, helpers each in their own file).

- **One file per use case or entry point.** A use case, controller, job, CLI command or adapter is one file, with the types, constants and small helpers only it uses kept inside it.
- **Per module layer: at most one ports file and one constants file.** Shared types of a layer live in its main rules or entity file. No file that holds only types, only one constant group, or only a re-export.
- **A port only when it earns it:** the layer rules forbid the I/O in the caller (for example a database client in the use-case layer), or there is a second real implementation (including a fake that a spec uses). A one-call library wrapper stays inside the adapter that uses it. One adapter per aggregate and storage technology, not one per query.
- **A new file only when** it is a separate use case or entry point, it has its own spec, the file would pass 300 lines, or a layer rule requires the split.
- **No file under 30 lines** except `index.ts`, the module wiring file, and a file the framework or a layer rule requires. Merge it into its nearest neighbour in the same layer.
- **Check:** adding one endpoint or use case touches at most 6 files (handler, request schema, use case, rule, repository method, wiring). If the plan needs more, merge before building.
- Task file lists and target file maps written before this rule are superseded where they conflict; the planner revises them, and a builder that finds a conflict in its task follows this section and records the difference in the unit record.

### 4.5 File and folder names

Applies to TypeScript and JavaScript source files (`.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`) and the folders that hold them. Other file types (CSS, JSON, Markdown, shell scripts, images) keep their own conventions.

- **Folders:** `kebab-case` (`order-history/`, `payment-methods/`). Framework folder syntax stays as the framework requires (`[id]`, `[...slug]`, `(group)`, `_private`, `@slot`).
- **Files:** `<use><PascalName>[.<word>].<ext>`.
  - `<PascalName>` names the thing the file holds, not its layer or folder: `Invoice`, `CheckoutPage`, `PaymentGateway`. When the file's main export is one component or one hook, the file name equals that export's name.
  - `<use>` only when the file's main export is one React hook: `useCart.ts`, `useSessionTimer.tsx`. The file exports a hook with exactly that name. A file that holds several hooks takes no `use` prefix.
  - `<word>` is one optional lower-case word that says what kind of file it is (`service`, `controller`, `client`, `constants`, `errors`): `Invoice.service.ts`, `Payment.errors.ts`. At most one word per file.
  - `<ext>` is the file's extension.
- **A word only when needed.** Ask in order; the first match decides:
  1. One React hook: `use<PascalName>.<ext>`. Never add a word that says what kind of hook it is (no `.query`, `.mutation`, `.state`).
  2. One React component, pages included: `<ComponentName>.tsx`, no word.
  3. A tool, framework, config or layer rule selects the file by its word (a module or role suffix, a lint or test glob), or the project's naming document requires a word in that package: the word is needed.
  4. The word keeps same-named files in one folder apart (`Cart.api.ts` next to `Cart.constants.ts`): the word is needed.
  5. Otherwise: `<PascalName>.<ext>`, no word. Never add a word by habit or to copy the files around it.
- **One meaning, one word.** When the project's naming document already has a word for this kind of file, use that word. When it has none, pick one plain lower-case word that says what the file holds. Never pick a vague word (`helper`, `util`, `utils`, `misc`, `common`, `types`, `component`). List a new word in your unit record or report so the planner can add it to the naming document.
- **No repeated word.** The base name does not end with its own word, singular or plural: `Payment.errors.ts`, not `PaymentError.errors.ts`; `Shipping.contract.ts`, not `ShippingContracts.contract.ts`. Exported identifiers keep their own names (`PaymentError` lives in `Payment.errors.ts`).
- **Tests:** append the project's test suffix to the full name of the file under test: `Invoice.service.spec.ts`, `useCart.test.ts`, `CheckoutPage.test.tsx`. Tests of one file split by scenario add one lower-case variant right before the suffix (`Invoice.service.refund.spec.ts`). A variant never stands in for a word and appears only on test files.
- **Kept as the tool requires:** framework-fixed names (`index.ts`, entry files such as `main.ts`, `*.d.ts`, framework route files such as `page.tsx` or `layout.tsx`), tool configs at a package root (`vite.config.ts`, `eslint.config.mjs`), and generated code.
- Types-only and re-export-only files get no name: merge them into a neighbour (§4.4).
- **Project detail:** when the project profile has a `Naming:` line, that document adds the project's words, framework names and stricter rules (for example "word required" in a package). It never loosens this section. Without one, this section applies alone.
- **Existing files:** name new files and folders by this section. Rename an existing file only when your task says so. A rename changes paths and imports, not exported identifiers or public package entry points.

## 5. General

- Match the surrounding code's style and naming; where it conflicts with section 4, follow section 4 in new code and do not rewrite the old code.
- Stay in the task's scope. No drive-by refactors.
- Never read or edit `.env*` files (except `.env.example`).
