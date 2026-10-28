# Handoff
Updated: 2026-10-27 after user answers on the frontend-to-web rename

## In progress / next
- P1-T1 cms-api runtime env into api-secrets; rename templates - awaiting checks/commit; next: security review, then P1-T4
- P1-T4 web, admin, shared templates - awaiting checks/commit; next: security review, then RW-T1
- P1-T2 api-init-secrets and database-ca-configmap templates - awaiting checks/commit; next: security review, then P1-T3
- P1-T3 backup-secrets template - awaiting checks/commit; next: security review, then P1-T5
- P1-T5 configuration.md for the new templates - awaiting checks/commit; next: RW-T2
- RW-T1 Move frontend app wiring to web - awaiting security review/commit; next: RW-T2
- RW-T2 Apply configmap/secrets naming in Flux and Deployments - awaiting security review/commit; next: RW-T3
- RW-T3 Template names and object names - awaiting security review/commit; next: RW-T4
- RW-T4 Docs rename to web and cutover steps - awaiting commit (no security gate); next: merge to develop, then user cutover per docs/DEPLOYMENT.md section 17
- DR1 Note in deployment docs: web reads web-secrets - awaiting commit (docs only); next: commit
- PLAN (template task, Phase 1) - plan in .claude/state/tasks/phase-1.md. Waiting for user approval of the task list and of adding docs/components/configuration.md to core-builder scope. Not yet approved.
- user answers:
  - Source of truth when docs disagree: Supabase production docs.
  - Add missing example files (database-ca, cms-api-migrate-db, postgres-backup): yes.
  - Placement rule: runtime-only values go in the Secret; values needed before the pod runs (Flux substitution) go in the ConfigMap.
  - Old keys: if a doc key does the same job, remove the old key; if none, keep it and note it as old config.
  - Object names, cms-admin Secret, docs task, database-ca as ConfigMap: as recommended.
  - Edit files in templates/: yes.
  - CD REQUIREMENT (user): CD must not need any .env* file; all runtime config must come from ConfigMap or Secret. Any .env.example reference is for verification only, never a CD input.
  - Public repo (user): sample files must not show concrete names or values; the user fills them in when cloning.
  - NAMING RULE (user, decided):
    - Secret: only values used by the pod at runtime (including initContainers and containers).
    - ConfigMap: only values that Flux can substitute during the rollout/integration step.
    - <value name> placeholder: values the user sets by hand after cloning the sample file.
    - Items the planner lists that do not fit these three groups must be shown to the user before changing them.
  - Profile: approved as written in project.md.
- DIRECT REQUEST (rename frontend to web) - planner job. User answers:
  - Q1 names: web-sync, web-config, APP_SERVICE_NAME=web, Secret web-<env>-secrets.
  - Q2 image and app repo: handled by another team; do not check or wait on them. Note: the app repo's CI contract (<app>-sync-overlay.yaml) must still be synced with the rename timing; flag it, do not solve it.
  - Q3 (environment config): web's environment config is the same as the frontend's current config file. Keep the same keys and values; only the names change (APP_SERVICE_NAME=web).
  - Q4 downtime on staging: accepted.
  - Q5 deleting old objects: the user deletes them themselves; agents must not delete anything.
  - Q6 docs/AUDIT.md and app-defined names (FRONTEND_URL, FRONTEND_GRAPHQL_URL): leave as is, add a one-line note.
  - Q7 one change on develop, merged to staging and main: yes.
  - Staging first, then prod.

## User decisions (Phase 1 and rename), latest
- Phase 1 task list P1-T1..P1-T5: APPROVED.
- core-builder scope: add docs/components/configuration.md: YES.
- U1 fixed values, U2 role names, U3 mount path: placeholders (recommended).
- U4 shape of values, U5 object names: as recommended (object names literal; Flux-referenced names stay).
- U6 product references in comments: keep. U7 remove concrete examples in comments: YES in P1-T1 and P1-T4.
- U8 placeholder style: not answered yet.
- No .env* grep check: the app team removes all .env* files when building the Docker image.
- Rename 2a: user wrote the pattern `<api|admin|web>-<configmap|secret>` for new object names. This may conflict with the existing Flux-referenced names (cms-api-config, shared-config, web-secrets). Planner must report the conflict, not decide it.
- Rename 2b: extend core-builder scope to apps/, cluster-base/, cluster/, docs/, README.md: YES.
- Rename 2c: Dockerfile/app paths: user does not care; the app team updates the image tag in GitHub after building the image. No action in this repo.
- Rename 2d: wait for Phase 1 before merging the rename: YES.
- Rename 2e: deletion of old workload: as recommended (A, Flux prunes; user deletes hand-made objects).
- U8.1 placeholder spelling: kebab case (`<db-host>`). DECIDED.
- U8.2 FRONTEND_URL (cms-api): REMOVED in P1-T1, replaced by WEB_ORIGIN. DECIDED.
- U8.3 value shapes: `https://<service>.<domain>` for api and admin, `https://<domain>` for web; other shapes as recommended. DECIDED.
- U8.4 shared-configmap.example.yaml: cleanup of concrete examples YES (add to P1-T4). DECIDED.
- U8.5 NAMING (overrides the earlier U5 "object names stay literal"): Secret and ConfigMap names follow `<api|admin|web>-<configmap|secrets>` for all apps (note: `secrets`, plural, as the user corrected). Planners propose the concrete names per service and per Flux file for user approval; the user does not write them. The shared ConfigMap is renamed `shared-configmap` (it is shared by the other three ConfigMaps). This changes Flux substituteFrom names, envFrom names, and template metadata.name in cluster-base/, apps/, templates/. Planners must list the exact file set and the cutover impact (cms-admin is live on prod) before any build. DECIDED, impact to be confirmed.

## Naming decisions (final, from user)
- Names table: APPROVED (shared-configmap, api-configmap, admin-configmap, web-configmap, api-secrets, admin-secrets, web-secrets, database-ca-configmap, backup-secrets).
- cms-api init container: INDEPENDENT (user decision, replaces MIXED). The init container reads ONLY `api-init-secrets`; it does not read `api-secrets`. Every value the init container needs is copied into `api-init-secrets`. Planners decide the key list and update P1-T2 and RW-T2/RW-T3 and the cutover copy step accordingly.
- Mount of database-ca in cms-api containers: ADDED to RW-T2 (recommended option A).
- Backup CronJob: SKIPPED for now (not running yet).
- Phase 1 and rename plan: APPROVED for build.
- Remove APP_API_URL once the frontend image reads API_INTERNAL_URL: APPROVED (future follow-up).
- database-ca and postgres-backup: keep the Phase 1 names (database-ca-configmap, backup-secrets). APPROVED.
- Template file names equal the object names (for example api-secrets.example.yaml, admin-configmap.example.yaml, web-secrets.example.yaml). APPROVED.

## Checkpoint decisions (user, after phase security review)
- Phase 1 checkpoint: ACCEPTED by user (2026-10-28). Board section archived to .claude/state/archive/board-archive.md.
- Rename checks (qc regression, then security PHASE) now: YES. Base 13e3797. Merge still waits for the user's staging and prod cutover.
- Rename checkpoint: ACCEPTED by user (2026-10-28). qc and security both pass (tier 1). Board section archived. Not pushed.
- docs/DEPLOYMENT.md section 17 step 2: spell out the full copy command for each renamed Secret (same style as docs/components/web.md step 1). APPROVED.
- Tier 3 runtime check before the staging -> main merge: Docker-based (kind/k3d), option B. Stack commands are NOT in project.md yet; a planner must propose them and the user approves before any build.

## Phase 1 checkpoint answers (user)
- Cookie / old-config keys (COOKIE_SECURE, COOKIE_SAMESITE, JWT_REFRESH_SECRET): keep as they are now (commented under old config). User checks the app repo themselves.
- Key renames (CORS_ORIGINS -> ADMIN_ORIGIN, TRUST_PROXY -> TRUST_PROXY_HOPS): APPROVED.
- Review step for placeholders (NODE_ENV, NEXT_ENV): user checks this themselves.
- .gitignore for *.yml copies: NO change.
- File copy names in template headers (QC finding): FIX (make consistent). Builder picks one consistent form and matches configuration.md.

## Check rules (user)
- QC (qc agent) runs only at a phase checkpoint (REGRESSION) or on audit request, NOT after each task. Per-task qc-cli / qc-browser checks are skipped; note the reason on the board.
- Security review (security-qc) for Risk: high tasks still runs per task, as before, unless the user changes it.

## Test rules (user, mid-turn)
- If a QC check needs a real runtime test, run it ONLY in Docker. Do not install any tool on the machine where the code is edited.

## Direct requests
- Rename frontend to web across the deploy repo (see above). Route: planner. Planner has not yet produced the plan.

### DR1 Note in deployment docs: web reads web-secrets
- In the three deployment docs (deployment/k3s-secrets-sops.md section 6, deployment/devops-runbook.md around line 189, deployment/k3s-traefik.md section 4), add a short note: in this repo web loads web-secrets through envFrom (API_INTERNAL_URL, APP_API_URL transition key and the other web keys). Do not change any key or value. Doc-only change.

## Open design question (DevOps risk) - answers (user, 2026-10-28)
- Keep APP_API_URL in web-secrets next to API_INTERNAL_URL (option A, both keys): YES.
- Removal of APP_API_URL: the app team says when the web image reads API_INTERNAL_URL (release note or PR for the image tag); then user asks for a removal task.
- Prod: same web-secrets template as staging: YES.
- Deployment docs (k3s-secrets-sops.md, devops-runbook.md, k3s-traefik.md) say web uses plain env, but repo uses web-secrets via envFrom: keep repo as is; add a short doc note that this repo uses web-secrets for web. YES.
- Open, not answered: point 2 (what the running image uses APP_API_URL for; confirm same cms-api base with /api/v1, from the app repo). Also WEB_PORT: k3s-traefik.md says 8080 as image default; apps/web and docs/components/web.md say 3000. Needs user answer.
- Asked by user, from DevOps team: renaming the frontend env var APP_API_URL to API_INTERNAL_URL in the template. Risk as stated: the running frontend image still reads APP_API_URL; a Secret created from the new template lacks it, and the frontend fails until the app reads API_INTERNAL_URL.
- Ask the planner (DESIGN): assess this risk against the current deploy repo and the rename plan, and give options (for example keeping both keys during transition, or ordering the app change first). Planner returns options and open questions; no decision by manager.
- Status: planner returned options A-D (no files changed). User DECIDED option A: keep both keys during transition (API_INTERNAL_URL added; APP_API_URL kept with a note to remove once the image reads the new key). Applies to P1-T4 and the frontend Secret. Not yet applied to the template files. Other open points for the user: (2) what the running image uses APP_API_URL for; (3) Secret name mismatch (`web-secrets` read by envFrom vs `<app>-<env>-secrets` in template); (4) whether Q3 keeps APP_API_URL in the web Secret; (5) who signals removal; (6) prod follows the same option.

## Follow-ups
- Real Secret/ConfigMap manifests (SOPS) are out of scope for this work -> unscheduled
- apps/cms-api/.env.example is not in this repo; needed to verify keys -> unscheduled
- apps/cms-api/deployment.yaml: init container reads ${APP_SERVICE_NAME}-${APP_ENV}-secrets, main container reads ${APP_SERVICE_NAME}-secrets (different Secrets) -> unscheduled, not in this work
- apps/cms-api/deployment.yaml has no database-ca mount; verify-full will fail at boot until added -> unscheduled
- postgres-backup templates have no CronJob consuming them yet -> unscheduled
- APP_API_URL -> API_INTERNAL_URL: a fresh frontend template breaks an image that still reads APP_API_URL (risk, see phase-1.md) -> unscheduled
- Image and app repo rename (other team) must be synced with the overlay rename -> unscheduled, owner: other team
- docs/components/cms-api.md:83 still lists FRONTEND_URL (qc regression note); P1-T1 removed it in the template, so the doc line needs a follow-up edit -> unscheduled
- Flux ${VAR} substitution and CRD schemas not validated (no kubeconform or Flux dry-run in this environment) -> unscheduled
