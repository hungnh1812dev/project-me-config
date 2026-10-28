# Rename frontend to web, and the ConfigMap/Secret naming pattern (direct request)

Goal: the public site's app is called `web` everywhere in this deploy repo, and every app's ConfigMap and Secret follow the user's naming pattern `<api|admin|web>-<configmap|secrets>` (U8.5, corrected: `secrets` plural), with the same keys and values as today. Flat task list (one rename, no phases). Status: names approved by the user ("Naming decisions (final, from user)" in handoff.md); plan APPROVED for build (user, "Naming decisions"); builders run one at a time, RW-T1 after the Phase 1 tasks that touch `templates/`.

Sources:
- User answers 2026-10-27 in `.claude/state/handoff.md`: rename Q1 to Q7, 2b to 2e, U8.2, U8.5, and "Naming decisions (final, from user)".
- `deployment/devops-runbook.md` §3.4 (the bump job opens `<app>-sync-overlay.yaml`; rename the public site's overlay to `web-sync-overlay.yaml` on `staging` and `main`), §3.5 item 4, §4.6 (credential modes).

## Names (APPROVED by the user, 2026-10-27)

Approved set: `shared-configmap`, `api-configmap`, `admin-configmap`, `web-configmap`, `api-secrets`, `api-init-secrets`, `admin-secrets`, `web-secrets`, `database-ca-configmap`, `backup-secrets`. Template file names equal the object names: `templates/<object>.example.yaml`; the filled copy drops `.example` (still gitignored by `templates/*.yaml`).

### Per service and per Flux file

| Service | Flux file | `substituteFrom` (in order) | Deployment file | `envFrom` Secret | Template files (`metadata.name`) |
|---|---|---|---|---|---|
| all | `cluster-base/cms-api-sync.yaml`, `cluster-base/cms-admin-sync.yaml`, `cluster-base/web-sync.yaml` | first: `shared-configmap` | n/a | n/a | `templates/shared-configmap.example.yaml` |
| cms-api | `cluster-base/cms-api-sync.yaml` | `shared-configmap`, `api-configmap` | `apps/cms-api/deployment.yaml` | main container: `api-secrets`; init container: `api-init-secrets` only; both mount `database-ca-configmap` | `templates/api-configmap.example.yaml`, `templates/api-secrets.example.yaml`, `templates/api-init-secrets.example.yaml` |
| cms-admin | `cluster-base/cms-admin-sync.yaml` | `shared-configmap`, `admin-configmap` | `apps/cms-admin/deployment.yaml` | `admin-secrets` | `templates/admin-configmap.example.yaml`, `templates/admin-secrets.example.yaml` |
| web | `cluster-base/web-sync.yaml` | `shared-configmap`, `web-configmap` | `apps/web/deployment.yaml` | `web-secrets` | `templates/web-configmap.example.yaml`, `templates/web-secrets.example.yaml` |
| database CA (shared) | none (mounted as a file, not read by Flux) | n/a | none yet (follow-up) | n/a | `templates/database-ca-configmap.example.yaml` |
| database CA mount | n/a | n/a | `apps/cms-api/deployment.yaml` (both containers, read-only at `/etc/abyss/database-ca`) | n/a | (see row above) |
| backup job | none | n/a | skipped for now (user): no CronJob in this work | `backup-secrets` (future CronJob) | `templates/backup-secrets.example.yaml` (only if Phase 1 still creates it) |

cms-api init container (user decision "INDEPENDENT", replaces "MIXED"): its `envFrom` lists only `api-init-secrets`; it no longer reads `api-secrets`. `api-init-secrets` holds every value the init container needs (the `deploy:migrate` set, `k3s-traefik.md` §3: `NODE_ENV`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_SSL_MODE`, `DB_SSL_ROOT_CERT_PATH`, `DB_USERNAME`, `DB_PASSWORD`); shared database settings are copied into both Secrets, with equal values (phase-1.md placement rule).

database CA (user decision): both cms-api containers mount ConfigMap `database-ca-configmap` (key `ca.crt`) read-only at `/etc/abyss/database-ca` (`supabase-database.md` §4, `k3s-traefik.md` §3 manifest), so `DB_SSL_ROOT_CERT_PATH=/etc/abyss/database-ca/ca.crt` works with `DB_SSL_MODE=verify-full`. The path is the docs' fixed value written as a literal in the manifest (like `containerPort`); the templates keep their placeholder plus comment (U3). The volume is not `optional`: a missing ConfigMap holds the new pod in `ContainerCreating` and the old pod keeps serving, which is visible, instead of a pod that starts and fails TLS.

### Full mapping

Workload names do not change for cms-api and cms-admin: `APP_SERVICE_NAME` stays `cms-api` and `cms-admin`, so their Deployments, Services, Ingresses, TLS Secrets and Flux Kustomizations keep their names. Only web's `APP_SERVICE_NAME` changes (`frontend` -> `web`).

| Thing | Before | After | Referenced by |
|---|---|---|---|
| App base folder | `apps/frontend/` | `apps/web/` | `cluster-base/web-sync.yaml` `path` |
| Flux Kustomization | `frontend-sync` | `web-sync` | overlays, `cluster-base/kustomization.yaml` |
| Image-tag overlays | `cluster/me/<env>/frontend-sync-overlay.yaml` | `cluster/me/<env>/web-sync-overlay.yaml` | `cluster/me/<env>/kustomization.yaml`, app repo bump job |
| web `APP_SERVICE_NAME` | `frontend` | `web` (Deployment, Service, Ingress `web-<env>`, Middleware `web-<env>-https-redirect`, TLS Secret `web-<env>-tls`) | `web-configmap` data |
| Shared ConfigMap | `shared-config` | `shared-configmap` | `substituteFrom` in all three sync files |
| cms-api ConfigMap | `cms-api-config` | `api-configmap` | `cluster-base/cms-api-sync.yaml` |
| cms-admin ConfigMap | `cms-admin-config` | `admin-configmap` | `cluster-base/cms-admin-sync.yaml` |
| web ConfigMap | `frontend-config` | `web-configmap` | `cluster-base/web-sync.yaml` |
| cms-api Secret, main container | `${APP_SERVICE_NAME}-secrets` = `cms-api-secrets` | `api-secrets` (literal) | `apps/cms-api/deployment.yaml` `envFrom` |
| cms-api Secret, init container | `${APP_SERVICE_NAME}-${APP_ENV}-secrets` = `cms-api-<env>-secrets` | `api-init-secrets` only (literal) | `apps/cms-api/deployment.yaml` init `envFrom` |
| cms-admin Secret | `cms-admin-secrets` | `admin-secrets` (literal) | `apps/cms-admin/deployment.yaml` `envFrom` |
| web Secret | `frontend-secrets` | `web-secrets` (literal) | `apps/web/deployment.yaml` `envFrom` |
| Database CA ConfigMap (Phase 1, new) | (none) | `database-ca-configmap` | no manifest yet |
| Backup job Secret (Phase 1, new) | (none) | `backup-secrets` | no manifest yet |

Why literal names in `envFrom`: `APP_SERVICE_NAME` (`cms-api`, `cms-admin`) cannot produce `api-`/`admin-`, and each `apps/<svc>/` folder belongs to one app, so a literal name per app is the plainest form. The next app adds its own `<prefix>-configmap` / `<prefix>-secrets` in its own sync file and Deployment only.

## Rules for every task

- File moves are `git mv` renames (Q7); nothing is deleted. The diff must show them as renames (`git diff -M --stat develop`).
- Names only: no key, value, probe, resource, replica, port or image tag changes (Q3). Two user-approved exceptions, both in RW-T2: the cms-api init container reads only `api-init-secrets`, and both cms-api containers mount `database-ca-configmap`. The prod overlays stay commented out in `cluster/me/prod/kustomization.yaml`, as today.
- Keep unchanged: the `docs/AUDIT.md` body (Q6, one-line note added by RW-T4); `FRONTEND_GRAPHQL_URL` (web build variable defined by the app repo, one-line note in RW-T4); app-repo paths in comments (`apps/frontend/Dockerfile`, `apps/frontend/.env.example`, `src/lib/health/checkApiHealth.ts`): no action (2c). `FRONTEND_URL` is not in this plan: P1-T1 removes it (U8.2).
- Do not edit `deployment/*.md` (source docs; they keep `cms-api-config`, `cms-api-secrets`, `cms-api-migrate-db`, `database-ca`, `postgres-backup`; RW-T4 adds the mapping line), `cluster/me/*/project-me-*/` (Flux bootstrap files) or `.claude/state/tasks/phase-1.md`.
- Template file names (approved): `templates/<object>.example.yaml`. Files that exist on `develop` are moved by RW-T3. Files Phase 1 creates new should be created under their final names by Phase 1 (see "Phase 1 coordination" below); RW-T3 moves any that still carry an old name.
- Scope: core-builder, extended to `apps/`, `cluster-base/`, `cluster/`, `docs/`, `README.md` (2b).
- One branch off `develop`; merge to `develop` only after Phase 1 (P1-T1 to P1-T5) is done (2d); then `develop` -> `staging`, cutover on staging, then `staging` -> `main`, cutover on prod (Q7).
- Old workload (2e, option A): removing `frontend-sync` lets Flux prune the frontend Deployment, Service, Ingress and Middleware. The user deletes the hand-made objects. No agent deletes anything.

---

## RW-T1: Move the frontend app wiring to web

Spec: rename Q1, Q3, Q7; `devops-runbook.md` §3.4
Scope: core-builder
Paths (13):
- `apps/frontend/deployment.yaml` -> `apps/web/deployment.yaml`
- `apps/frontend/service.yaml` -> `apps/web/service.yaml`
- `apps/frontend/ingress.yaml` -> `apps/web/ingress.yaml`
- `apps/frontend/middleware.yaml` -> `apps/web/middleware.yaml`
- `apps/frontend/kustomization.yaml` -> `apps/web/kustomization.yaml`
- `cluster-base/frontend-sync.yaml` -> `cluster-base/web-sync.yaml`
- `cluster-base/kustomization.yaml`
- `cluster/me/staging/frontend-sync-overlay.yaml` -> `cluster/me/staging/web-sync-overlay.yaml`
- `cluster/me/prod/frontend-sync-overlay.yaml` -> `cluster/me/prod/web-sync-overlay.yaml`
- `cluster/me/staging/kustomization.yaml`
- `cluster/me/prod/kustomization.yaml`
- `apps/cms-api/ingress.yaml` (comment only)
- `apps/cms-admin/ingress.yaml` (comment only)
Deps: none
Security gate: yes (changes what Flux applies on both clusters)

Acceptance criteria:
- `cluster-base/web-sync.yaml`: `metadata.name: web-sync`, `path: ./apps/web`; `substituteFrom` names untouched here (RW-T2 changes them); comments say web.
- `cluster-base/kustomization.yaml` lists `web-sync.yaml` in place of `frontend-sync.yaml`.
- Both overlays: `metadata.name: web-sync`; the one `APP_IMAGE_TAG:` line unchanged; comment says web.
- `cluster/me/staging/kustomization.yaml`: `- path: web-sync-overlay.yaml`; `cluster/me/prod/kustomization.yaml`: `# - path: web-sync-overlay.yaml` (still commented).
- `apps/web/*.yaml`: comments say web and point at `cluster-base/web-sync.yaml`, `templates/web-*.example.yaml`, `web-sync-overlay.yaml`; manifest lines unchanged.
- cms-api and cms-admin Ingress comments say web instead of the frontend.

Verify:
- `git diff -M --stat develop` shows the 8 moves as renames.
- `kubectl kustomize apps/web`, `kubectl kustomize cluster/me/staging`, `kubectl kustomize cluster/me/prod` exit 0.
- python check on the staging render: Kustomization `web-sync` with `spec.path ./apps/web` and `APP_IMAGE_TAG` equal to the value on `develop` before the change; no object named `frontend-sync`. Prod render: `web-sync` present, no `frontend-sync`, no `APP_IMAGE_TAG` (as today).
- `grep -rn frontend apps cluster-base cluster/me/staging/*.yaml cluster/me/prod/*.yaml` prints only the kept app-repo paths.

---

## RW-T2: Apply the ConfigMap and Secret naming pattern in the Flux and Deployment manifests

Spec: U8.5; names table above (approved); init container "INDEPENDENT"; database CA mount (user decision; `supabase-database.md` §4, `k3s-traefik.md` §3)
Scope: core-builder
Paths (9):
- `cluster-base/cms-api-sync.yaml` (`substituteFrom`: `shared-configmap`, `api-configmap`)
- `cluster-base/cms-admin-sync.yaml` (`substituteFrom`: `shared-configmap`, `admin-configmap`)
- `cluster-base/web-sync.yaml` (`substituteFrom`: `shared-configmap`, `web-configmap`)
- `apps/cms-api/deployment.yaml` (main `envFrom`: `api-secrets`; init `envFrom`: `api-init-secrets`; `database-ca` volume from ConfigMap `database-ca-configmap` and a read-only `volumeMount` at `/etc/abyss/database-ca` in both containers; header comment)
- `apps/cms-admin/deployment.yaml` (`envFrom`: `admin-secrets`; header comment, which today says the pod needs no Secret)
- `apps/web/deployment.yaml` (`envFrom`: `web-secrets`; header comment)
- `apps/cms-api/kustomization.yaml` (comment only)
- `apps/cms-admin/kustomization.yaml` (comment only)
- `apps/web/kustomization.yaml` (comment only)
Deps: RW-T1
Security gate: yes (cms-admin is live on prod; a wrong name stops its next rollout)

Acceptance criteria:
- `substituteFrom` in the three sync files: first entry `shared-configmap`, second the app's `<prefix>-configmap`; order and every other field unchanged.
- `envFrom.secretRef.name` values are the literals above; the init container has exactly one `secretRef`, `api-init-secrets`.
- `apps/cms-api/deployment.yaml` gains one pod volume `database-ca` (`configMap.name: database-ca-configmap`, not optional) and, in the init and the main container, `volumeMounts: [{name: database-ca, mountPath: /etc/abyss/database-ca, readOnly: true}]`, with a comment: the path must equal the directory of `DB_SSL_ROOT_CERT_PATH` in `api-secrets` and `api-init-secrets`; needed for `DB_SSL_MODE=verify-full`.
- No other manifest line changes (no new `securityContext`, probe or resource changes).
- Comments that name `shared-config`, `<svc>-config` or `<svc>-<env>-secrets` use the new names.
- `grep -rnE "shared-config\b|cms-api-config|cms-admin-config|frontend-config|cms-api-secrets|cms-admin-secrets|frontend-secrets|SERVICE_NAME\}-(\$\{APP_ENV\}-)?secrets|<svc>-<env>-secrets" apps cluster-base` prints nothing.

Verify:
- `kubectl kustomize cluster/me/staging` and `kubectl kustomize cluster/me/prod` exit 0.
- python check on both renders: each `*-sync` Kustomization's `substituteFrom` names are `[shared-configmap, <prefix>-configmap]` with prefix `api`, `admin`, `web`.
- python check on `kubectl kustomize apps/<svc>` for the three apps (unsubstituted `${...}` is fine): every `secretRef.name` is in `{api-secrets, api-init-secrets, admin-secrets, web-secrets}`; the cms-api init container's list is exactly `[api-init-secrets]`, the main container's `[api-secrets]`; both cms-api containers mount volume `database-ca` at `/etc/abyss/database-ca` read-only, and that volume's `configMap.name` is `database-ca-configmap`.
- `git diff develop -- apps cluster-base` touches only `name:` lines, comments, and the cms-api volume and two `volumeMounts`.

---

## RW-T3: Rename every template file and object to the approved names

Spec: U8.5 and "Naming decisions (final, from user)"; rename Q1, Q3; `phase-1.md` "Depends on the rename"
Scope: core-builder
Paths (10 templates; moves are `git mv`, file name = object name). Left side = the name the file has after Phase 1 as `phase-1.md` reads today; if Phase 1 already created a new file under its final name, that line is a `metadata.name` check only:
- `templates/shared-configmap.example.yaml` (name unchanged; `metadata.name: shared-configmap`)
- `templates/cms-api-configmap.example.yaml` -> `templates/api-configmap.example.yaml` (`api-configmap`)
- `templates/cms-api-secret.example.yaml` -> `templates/api-secrets.example.yaml` (`api-secrets`)
- `templates/cms-api-migrate-db-secret.example.yaml` -> `templates/api-init-secrets.example.yaml` (`api-init-secrets`; P1-T2 creates it)
- `templates/cms-admin-configmap.example.yaml` -> `templates/admin-configmap.example.yaml` (`admin-configmap`)
- `templates/cms-admin-secret.example.yaml` -> `templates/admin-secrets.example.yaml` (`admin-secrets`; P1-T4 creates it)
- `templates/frontend-configmap.example.yaml` -> `templates/web-configmap.example.yaml` (`web-configmap`)
- `templates/frontend-secret.example.yaml` -> `templates/web-secrets.example.yaml` (`web-secrets`)
- `templates/database-ca-configmap.example.yaml` (name unchanged; `metadata.name: database-ca-configmap`; P1-T2 creates it)
- `templates/postgres-backup-secret.example.yaml` -> `templates/backup-secrets.example.yaml` (`backup-secrets`; only if P1-T3 still creates it, the backup CronJob is skipped for now)
Deps: RW-T2; P1-T1, P1-T2, P1-T3, P1-T4 (they write these files; this task runs after them)
Security gate: yes (touches `templates/*secret*.yaml`)

Acceptance criteria:
- Every `templates/*.example.yaml` file name is `<metadata.name>.example.yaml`; `metadata.name` is literal (no `<app-service-name>` placeholder) and equals the names table.
- Headers name the new objects and files: each copy command uses the new file name (keeping the template's current copy-target style, for example `templates/web-configmap-<app-env>.yaml`, `templates/web-secrets.yaml`); `cluster-base/web-sync.yaml` and `reconcile kustomization web-sync`; the Secret each Deployment reads; `shared-configmap` read first by every sync file; `api-init-secrets` header: the only Secret the cms-api init container reads; it holds every value the init container needs, and the shared database settings must equal those in `api-secrets`; the web `APP_SERVICE_NAME` comment gives `web`; `shared-configmap` comments say "cms-api, cms-admin and web", "web is served at <domain>".
- Cross-references between templates use the new file names (no `templates/cms-api-*`, `templates/cms-admin-*`, `templates/frontend-*`, `postgres-backup-secret`, `migrate-db` left).
- Keys, values and placeholders exactly as Phase 1 left them (web keeps both `API_INTERNAL_URL` and `APP_API_URL`).
- `FRONTEND_GRAPHQL_URL` stays, with the line "name defined by the app repository; kept as is after the frontend-to-web rename".

Verify:
- YAML parse of every `templates/*.example.yaml` exits 0.
- python check: for every `templates/*.example.yaml`, the file name without `.example.yaml` equals `metadata.name`; the set of names equals the 10 approved names; `data`/`stringData` keys of each file equal its keys on the commit before this task.
- `git diff -M --stat <commit before this task> -- templates` shows the moves as renames; the diff has only `metadata.name` lines and comment lines.
- `grep -rnE "cms-api-(config|secret)|cms-admin-(config|secret)|frontend-(config|secret)|migrate-db|postgres-backup-secret|<app-service-name>-" templates` prints nothing.
- `git check-ignore templates/api-secrets.yaml templates/api-init-secrets.yaml templates/web-secrets.yaml templates/web-configmap-staging.yaml` prints every path (add `templates/backup-secrets.yaml` if that template exists).

---

## RW-T4: Rename frontend to web and the object names in the docs, and add the cutover steps

Spec: rename Q4 to Q7, U8.5; cutover order below
Scope: core-builder
Paths (8):
- `docs/components/frontend.md` -> `docs/components/web.md`
- `README.md`
- `docs/DEPLOYMENT.md`
- `docs/components/configuration.md`
- `docs/components/flux-system.md`
- `docs/components/cms-api.md`
- `docs/components/cms-admin.md`
- `docs/AUDIT.md` (one added line only)
Deps: RW-T3; P1-T5 (edits `configuration.md`)
Note: every template link in the docs uses the RW-T3 file names.
Security gate: no

Acceptance criteria:
- Every `frontend` naming this repo's app, object, file or path becomes `web`; links to `components/frontend.md` point to `components/web.md`.
- Every ConfigMap and Secret name follows the names table (`shared-configmap`, `<prefix>-configmap`, `<prefix>-secrets`); out-of-date `<svc>-<env>-secrets` wording is replaced.
- `docs/components/configuration.md` gains one line: the deployment docs (`deployment/*.md`) say `cms-api-config`, `cms-api-secrets`, `cms-api-migrate-db`, `database-ca`, `postgres-backup`; in this repo they are `api-configmap`, `api-secrets`, `api-init-secrets`, `database-ca-configmap`, `backup-secrets` (U8.5, final naming decisions). Its naming rule says how the next app is added: one `<prefix>-configmap` in its sync file, one `<prefix>-secrets` in its Deployment.
- `docs/AUDIT.md` gains one line under its title: "Written before the frontend-to-web rename and the ConfigMap/Secret renaming: `frontend` is today's `web`; old object names map as in `docs/components/configuration.md`." `docs/components/web.md` gains one line: "`FRONTEND_GRAPHQL_URL` (web build variable) is defined by the app repository and keeps its name."
- `docs/components/web.md` gains the section "Cutover from frontend"; `docs/DEPLOYMENT.md` gains one short subsection "Moving to the new ConfigMap and Secret names" with the per-cluster steps below as commands, including the CI note (the app repo's bump job writes `web-sync-overlay.yaml` from the same merge on; owned by the other team).
- `docs/components/cms-api.md` key list (line with `FRONTEND_URL`) is not edited here (Phase 1 key change, not a rename).

Verify:
- `grep -rn frontend README.md docs --exclude=AUDIT.md` prints only kept names (`FRONTEND_GRAPHQL_URL`, `FRONTEND_URL` in the cms-api key list, app-repo paths).
- `grep -rnE "shared-config\b|cms-api-config|cms-admin-config|frontend-config" README.md docs --exclude=AUDIT.md` prints only the mapping line.
- Every relative `.md` link in the touched docs resolves.
- `git diff -M --stat develop -- docs` shows `frontend.md` -> `web.md` as a rename; `git diff develop -- docs/AUDIT.md` is one added line.

---

## Cutover order (user actions on the clusters; not builder tasks)

Precondition: Phase 1 done and RW-T1 to RW-T4 merged into `develop` (2d).

How the clusters react to the merge (why the order matters):
- A missing ConfigMap in `substituteFrom` fails that sync Kustomization at build time: nothing is applied, the running pods stay as they are.
- A missing Secret: the Deployment is updated, the new pod stays in `CreateContainerConfigError`; with `replicas: 1` and the default rolling update (maxUnavailable rounds to 0) the old pod keeps serving; the sync Kustomization turns not Ready after its 5m `timeout`. Fix: create the Secret; the new pod then starts.
- `frontend-sync` is removed by the root Kustomization regardless of ConfigMaps, so the frontend workload is pruned on merge (2e); web serves only once `web-configmap` and `web-secrets` exist.
- cms-api and cms-admin keep their workload names; their pods roll once because `envFrom` changes. No new certificate for them.
- Rollback: revert the merge on the branch. The old objects still exist until step 6, so Flux returns to the old names.

Per cluster, `<ns>` = `project-me-staging` (branch `staging`) first, then `project-me-prod` (branch `main`):
1. Create the four ConfigMaps as copies of today's, same data: `shared-configmap` (from `shared-config`), `api-configmap` (from `cms-api-config`), `admin-configmap` (from `cms-admin-config`), `web-configmap` (from `frontend-config`, with `APP_SERVICE_NAME: "web"`). Copy only the ones that exist on that cluster today; a missing old one stays missing (same state as today).
   `kubectl -n <ns> get configmap <old> -o json | jq '{apiVersion, kind, data, metadata: {name: "<new>", namespace: .metadata.namespace}}' | kubectl apply --server-side -f -` (for web add `| .data.APP_SERVICE_NAME = "web"` in the jq filter).
2. Create the Secrets the same way (piped, never written to disk; use `{apiVersion, kind, type, data, metadata: {...}}` in the jq filter): `api-secrets` (from `cms-api-secrets`), `admin-secrets` (from `cms-admin-secrets`), `web-secrets` (from `frontend-secrets`), and `api-init-secrets`: copy the init key set (`NODE_ENV`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_SSL_MODE`, `DB_SSL_ROOT_CERT_PATH`, `DB_USERNAME`, `DB_PASSWORD`) from `cms-api-<env>-secrets`, the Secret the init container reads today: `kubectl -n <ns> get secret cms-api-<env>-secrets -o json | jq '{apiVersion, kind, type, metadata: {name: "api-init-secrets", namespace: .metadata.namespace}, data: (.data | with_entries(select(.key | IN("NODE_ENV","DB_HOST","DB_PORT","DB_NAME","DB_SSL_MODE","DB_SSL_ROOT_CERT_PATH","DB_USERNAME","DB_PASSWORD"))))}' | kubectl apply --server-side -f -`. Then list the keys it lacks (`kubectl -n <ns> get secret api-init-secrets -o json | jq -r '.data | keys[]'`) and add any missing init key by hand from `templates/api-init-secrets.example.yaml`.
2b. Create `database-ca-configmap` (new; key `ca.crt`, the Supabase CA, `supabase-database.md` S1) from `templates/database-ca-configmap.example.yaml`. Without it the new cms-api pod waits in `ContainerCreating` and the old pod keeps serving. If the cluster is not on `verify-full` yet, the mount is still required; the file is only read when `DB_SSL_MODE=verify-full`.
3. Check: `kubectl -n <ns> get configmap shared-configmap api-configmap admin-configmap web-configmap` and `kubectl -n <ns> get secret api-secrets api-init-secrets admin-secrets web-secrets` list every object that has an old counterpart, and `kubectl -n <ns> get configmap database-ca-configmap` exists wherever cms-api runs (`backup-secrets` is not part of this cutover).
4. Open the PR (`develop` -> `staging`, then later `staging` -> `main`). Check `cluster/me/<env>/web-sync-overlay.yaml` carries the tag the target branch has now in `frontend-sync-overlay.yaml` (the bot pushes bumps to `staging` and `main` directly) and no `frontend-sync-overlay.yaml` is left. Merge; tell the other team to switch the bump target to `web` now.
5. Check after Flux applies:
   - `flux -n <ns> get kustomizations`: `cms-api-sync`, `cms-admin-sync`, `web-sync` Ready (on prod, `cms-api-sync` and `web-sync` in the same state as before the merge, since their overlays are commented out); no `frontend-sync`.
   - `kubectl -n <ns> rollout status deploy/cms-admin-<env>` completes;
   - where cms-api runs: `kubectl -n <ns> logs deploy/cms-api-<env> -c init` shows the migration finished, and `kubectl -n <ns> exec deploy/cms-api-<env> -c app -- ls /etc/abyss/database-ca/ca.crt` prints the path; `curl -I https://admin.<domain>/health/ready` returns 200.
   - Staging also: `kubectl -n <ns> rollout status deploy/cms-api-staging` and `deploy/web-staging`; `curl -I https://api.<staging-domain>/health/ready` and `curl -I https://<staging-domain>/api/health/ready` return 200; certificate `web-staging-tls` Ready.
6. Only after step 5 passes, the user deletes the old hand-made objects (Q5, 2e): ConfigMaps `shared-config`, `cms-api-config`, `cms-admin-config`, `frontend-config`; Secrets `cms-api-secrets`, `cms-api-<env>-secrets`, `cms-admin-secrets`, `frontend-secrets`, `frontend-<env>-tls`.

Prod specifics: cms-admin is the only live app on prod. Steps 1 to 3 must be complete before the `staging` -> `main` merge; with them done, cms-admin rolls one new pod with no downtime (old pod serves until the new one is Ready). The prod cms-api and web overlays stay commented out, as today.

## Phase 1 coordination (for the Phase 1 planner; this file does not change `phase-1.md`)

- P1-T2 must produce `api-init-secrets` with the full init key set (`NODE_ENV`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_SSL_MODE`, `DB_SSL_ROOT_CERT_PATH`, `DB_USERNAME`, `DB_PASSWORD`), because the init container now reads only this Secret ("INDEPENDENT"). Its header changes from "mode B only, not used in mode A" to "always read by the init container; in mode A put the same account as `api-secrets`". This matches P1-T2's key list as written; only its header and object name differ, which the Phase 1 planner handles (REPLAN P1-T2) or RW-T3 renames.
- P1-T1 and P1-T2 comments that say `apps/cms-api/deployment.yaml` has no `database-ca` mount become out of date after RW-T2; RW-T3 updates those comment lines.
- P1-T3 (backup Secret): the backup CronJob is skipped for now; whether P1-T3 still creates the template is a Phase 1 decision.
- If the Phase 1 planner creates the new files under their final names (`api-init-secrets.example.yaml`, `database-ca-configmap.example.yaml`, `backup-secrets.example.yaml`, `admin-secrets.example.yaml`), RW-T3 checks them instead of moving them.

No open naming questions remain; all names above are approved.
