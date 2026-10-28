# Phase 1: Example Secret and ConfigMap update

Goal: the example Secret and ConfigMap files in `templates/` match the env contract in the deployment docs, under their final names. Placeholders only, no real values.

Sources (by priority when they disagree, user answer 2026-10-27):
1. `deployment/supabase-database.md` §4 (TLS keys), §5 (Secret map), §7 (backup on Supabase)
2. `deployment/k3s-secrets-sops.md` §1 (which keys are secret), §2 (Secret bodies)
3. `deployment/k3s-traefik.md` §2 (client IP), §3 (init container), §6 (cms-api env contract), §7 (backup job config)
4. `deployment/devops-runbook.md` §4.4 (ConfigMaps), §4.5 (Secrets), §4.6 (credential modes)

## Placement rule (user, 2026-10-27; overrides where the docs put a key)

- **ConfigMap** = values needed before the pod runs: Flux `postBuild.substituteFrom` values (`APP_*`). Pods never read these ConfigMaps (`apps/*/deployment.yaml` loads only Secrets via `envFrom`), and that stays so.
- **Secret** = every value needed only at pod runtime (init containers and containers), secret or not. The docs' "not secret" column becomes a comment grouping inside the Secret, not a separate ConfigMap.
- Consequence: the docs' runtime ConfigMaps (`cms-api-config` runtime keys, `postgres-backup-config`) are not created; their keys go into the Secret of the pod that reads them. The backup job reads only its own Secret, so it gets its own copy of the shared database settings (`DB_HOST`, `DB_PORT`, `DB_NAME`, TLS); keep the values equal across Secrets.
- Exception (Q7): the database CA stays a ConfigMap (`database-ca-configmap`), as the Supabase docs specify: a public certificate mounted as a file, not an env value.

## Value rule (user, 2026-10-27; applies to every task)

Every value in a template belongs to exactly one group:
1. **Secret**: values a pod uses at runtime.
2. **ConfigMap**: only values Flux substitutes during rollout or integration (`APP_*`).
3. **`<value-name>` placeholder**: every value the user sets by hand after cloning, written as a lower-case kebab placeholder named after what it holds (`DB_HOST: "<db-host>"`, U8.1). No concrete name or value appears in a value.

Where a task below names the value the docs require (for example `verify-full`, `5432`, `production`, `abyss_api`, `/etc/abyss/database-ca/ca.crt`), the builder writes a group-3 placeholder as the value and puts the doc value and its doc section in the comment next to the key (for example `DB_SSL_MODE: "<db-ssl-mode>"  # production: verify-full (supabase-database.md §4)`).

The samples are public: no concrete names or values. CD needs no `.env*` file; `apps/*/.env.example` is named only as a verification reference, never as a CD input. Not a task: a `.env*` check in CD (user: the app team removes all `.env*` files when building the image).

## Decisions (user, 2026-10-27)

| ID | Decision | How the tasks apply it |
|---|---|---|
| U1 fixed doc values | placeholders | group-3 placeholder; the doc value goes in the comment |
| U2 role names | placeholders | `DB_USERNAME: "<api-role>.<project-ref>"`, `"<migrator-role>.<project-ref>"`, `"<backup-role>.<project-ref>"`; comment: must equal the `-v ..._role` values of the roles script (docs default named in the comment) |
| U3 CA mount path | placeholder | `DB_SSL_ROOT_CERT_PATH` / `PGSSLROOTCERT: "<db-ssl-root-cert-path>"`; comment: `<mountPath of database-ca-configmap>/ca.crt`, must equal the Deployment/CronJob `mountPath` |
| U4 / U8.3 value shapes | decided | `ADMIN_ORIGIN: "https://<admin-service>.<domain>"`, cms-api public URL `https://<api-service>.<domain>`, `WEB_ORIGIN: "https://<domain>"`; other shapes keep their form with a placeholder per variable part (`http://<api-service-name>.<app-namespace>-<app-env>.svc.cluster.local:<api-port>/api/v1`, `https://<account-id>.<object-storage-host>`), product host named in the comment |
| U6 product references in comments | keep | headers keep Supabase, Cloudflare R2, Cloudinary, nginx-unprivileged and doc pointers |
| U7 / U8.4 concrete examples in comments | remove | P1-T1, P1-T4 (P1-T4 includes the shared ConfigMap) |
| U8.1 placeholder spelling | kebab case | all tasks |
| U8.2 `FRONTEND_URL` (cms-api) | removed, replaced by `WEB_ORIGIN` | P1-T1 |
| Q3 / Q3a / option A | frontend = web; old keys: remove if a doc key has the same role, else keep as `old config`; `APP_API_URL` kept next to `API_INTERNAL_URL` during transition | P1-T1, P1-T4 |
| U8.5 + final naming | names table below, approved; template file names equal object names; init container: independent (`api-init-secrets` only, user final) | all tasks |

## Rules for every task

- Placeholders in `<angle-brackets>`; no real host, password, key, token, project ref or domain.
- Quote every value (ConfigMap and Secret data must be strings).
- Keep the existing header style of the templates: what the object is, who reads it, how to copy and apply it (`cp templates/<name>.example.yaml templates/<name>.yaml` then `kubectl apply --server-side -f templates/<name>.yaml`), how to roll it out after a change. Headers name objects and template files by their new names only.
- Inside a Secret, group keys under two comment headings: `secret values` (the docs' Secret column) and `plain settings (not secret per the docs; here because only the pod reads them)`.
- Old keys (user rule, from Q3a): for each key in an old example that is not in the docs, if a doc key has the same role, **remove** it; if none has, **keep** it under a comment block `old config: from the previous example, no equivalent in the deployment docs`. cms-api keeps its old-config keys commented out (Q4); the frontend keeps them active (the image deployed today needs them).
- Existing template files are renamed with `git mv` (a rename, not a delete; approved by the user); the builder never deletes a file.
- Filled copies stay gitignored: every template ends in `.example.yaml`, its filled copy drops `.example` (`.gitignore`: `templates/*.yaml`, `!templates/*.example.yaml`).
- Each task edits only its own paths.

## Object names and template files (final, approved by the user)

Names are written literally in templates, `cluster-base/` and `apps/` (no longer derived from `${APP_SERVICE_NAME}`). Namespace stays `<app-namespace>-<app-env>`. `web` is the frontend; the rest of the frontend -> web rename (`apps/frontend`, `frontend-sync`, `APP_SERVICE_NAME`) is a separate request.

| Object | Old name | New `metadata.name` | Template file (old -> new) | Referenced by |
|---|---|---|---|---|
| ConfigMap, shared Flux values | `shared-config` | `shared-configmap` | `templates/shared-configmap.example.yaml` (name unchanged) | `cluster-base/{cms-api,cms-admin,frontend}-sync.yaml` `substituteFrom` |
| ConfigMap, cms-api Flux values | `cms-api-config` | `api-configmap` | `cms-api-configmap.example.yaml` -> `api-configmap.example.yaml` | `cluster-base/cms-api-sync.yaml` |
| ConfigMap, cms-admin Flux values | `cms-admin-config` | `admin-configmap` | `cms-admin-configmap.example.yaml` -> `admin-configmap.example.yaml` | `cluster-base/cms-admin-sync.yaml` |
| ConfigMap, frontend Flux values | `frontend-config` | `web-configmap` | `frontend-configmap.example.yaml` -> `web-configmap.example.yaml` | `cluster-base/frontend-sync.yaml` |
| Secret, cms-api main container | `${APP_SERVICE_NAME}-secrets` (main) / `${APP_SERVICE_NAME}-${APP_ENV}-secrets` (init) | `api-secrets` | `cms-api-secret.example.yaml` -> `api-secrets.example.yaml` | `apps/cms-api/deployment.yaml`, main container |
| Secret, cms-api init container (all its values) | (new) | `api-init-secrets` | new `api-init-secrets.example.yaml` | `apps/cms-api/deployment.yaml`, init container only |
| Secret, cms-admin | `${APP_SERVICE_NAME}-secrets` | `admin-secrets` | new `admin-secrets.example.yaml` | `apps/cms-admin/deployment.yaml` |
| Secret, frontend | `${APP_SERVICE_NAME}-secrets` | `web-secrets` | `frontend-secret.example.yaml` -> `web-secrets.example.yaml` | `apps/frontend/deployment.yaml` |
| ConfigMap, database CA | (new) | `database-ca-configmap` | new `database-ca-configmap.example.yaml` | none yet (follow-up: cms-api mount) |
| Secret, backup CronJob | (new) | `backup-secrets` | new `backup-secrets.example.yaml` | none (backup CronJob not planned) |

### cms-api init container: independent Secret (user decision, final)

- The init container reads only `api-init-secrets` (`envFrom`, wired by RW-T2). It does not read `api-secrets`. The main container reads only `api-secrets`.
- `api-init-secrets` therefore holds every value the init container needs: `deploy:migrate` reads only `DB_*` and `NODE_ENV` (`k3s-traefik.md` §3). Exact key set: `DB_USERNAME`, `DB_PASSWORD` (secret values; the migration role), `NODE_ENV`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_SSL_MODE`, `DB_SSL_ROOT_CERT_PATH` (plain settings).
- Six values are kept in both Secrets (`NODE_ENV`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_SSL_MODE`, `DB_SSL_ROOT_CERT_PATH`); both headers say to keep them equal. Only `DB_USERNAME` and `DB_PASSWORD` differ (mode B: migrator vs API role; mode A: the same login in both).
- Result, matching the docs' mode B: the init container sees no app secret, the main container never sees the migrator password.

### Ownership split with the rename plan (`tasks/rename-web.md`)

- Phase 1 owns `templates/` only: it writes every template under its final file name and `metadata.name` (the table above); existing files move with `git mv`. RW-T3 then only checks them.
- RW-T2 owns the manifest wiring (`cluster-base/*-sync.yaml` `substituteFrom`, `apps/*/deployment.yaml` `envFrom`; the cms-api init container reads `api-init-secrets` only). RW-T4 owns the object names in the other docs. The cutover order is in `rename-web.md` ("Cutover order").
- Phase 1 docs: `docs/components/configuration.md` only (P1-T5).
- Stale comment after RW-T2: P1-T1's `DB_SSL_MODE` comment in `api-secrets.example.yaml` says the Deployment has no CA mount yet. P1-T1 is not changed while its builder runs; RW-T3 rewords that comment once RW-T2 adds the mount (same wording rule as P1-T2: no "yet").
- Until the rename branch merges, `templates/` use the new names while `cluster-base/` and `apps/` still use the old ones. Promote Phase 1 and the rename together (develop -> staging -> main), never Phase 1 alone; on `develop` the gap is expected.

Files Phase 1 touches: `templates/api-configmap.example.yaml`, `templates/api-secrets.example.yaml`, `templates/admin-configmap.example.yaml`, `templates/web-configmap.example.yaml`, `templates/web-secrets.example.yaml` (all renamed from the old names), `templates/shared-configmap.example.yaml` (edited), `templates/api-init-secrets.example.yaml`, `templates/admin-secrets.example.yaml`, `templates/database-ca-configmap.example.yaml`, `templates/backup-secrets.example.yaml` (new), `docs/components/configuration.md`.

Grep for old names (used by several verify steps):
`grep -rnE 'shared-config\b|cms-api-config|cms-admin-config|frontend-config|<svc>-config|cms-api-secrets|cms-admin-secrets|frontend-secrets|SERVICE_NAME\}-secrets|APP_ENV\}-secrets|<svc>-<env>-secrets|cms-api-secret\.example|frontend-secret\.example|cms-api-configmap\.example|cms-admin-configmap\.example|frontend-configmap\.example' <paths>`

---

## P1-T1: Move the whole cms-api runtime env into `api-secrets` and rename the cms-api templates

Spec: `supabase-database.md` §4, §5; `k3s-secrets-sops.md` §1, §2; `k3s-traefik.md` §2, §6; `devops-runbook.md` §4.4, §4.6; placement and value rules; final naming
Scope: core-builder
Paths: `templates/cms-api-secret.example.yaml` -> `templates/api-secrets.example.yaml` (git mv, then edit); `templates/cms-api-configmap.example.yaml` -> `templates/api-configmap.example.yaml` (git mv, then edit)
Deps: none
Security gate: yes

Acceptance criteria:
- `api-secrets.example.yaml`: `metadata.name: api-secrets`. Header: read by the main container only; the init container reads `api-init-secrets` instead, which repeats the six shared database settings (keep them equal); rotation pointer `deployment/k3s-secrets-sops.md` §7; production SOPS flow `deployment/k3s-secrets-sops.md` §4; a "never set in production" line for `LOGIN_RATE_LIMIT_*`, `REFRESH_RATE_LIMIT_IP`, `ALLOW_LOGIN_RATE_LIMIT_OVERRIDE`, `OWNER_EMAIL`, `OWNER_DISPLAY_NAME`; no `PORT` and no `APP_*` key (the Deployment sets `PORT` from `APP_PORT`).
- `secret values` group: `DB_USERNAME` (`<api-role>.<project-ref>`; comment: mode A uses the migrator login, `devops-runbook.md` §4.6), `DB_PASSWORD`, `JWT_ACCESS_SECRET`, `OTP_PEPPER`, `TOTP_ENC_KEY` (each at least 32 bytes, `openssl rand -base64 48`), `CLOUDINARY_API_SECRET`, `TURNSTILE_SECRET_KEY`, `SMTP_USER` and `SMTP_PASSWORD` (both or neither), `BACKUP_STORAGE_ACCESS_KEY_ID` and `BACKUP_STORAGE_SECRET_ACCESS_KEY` (read-only bucket token, never the job token); commented, temporary: `OWNER_SETUP_TOKEN` (first install), `TOTP_ENC_PREVIOUS_KEY` (rotation, with `TOTP_ENC_PREVIOUS_KID`).
- `plain settings` group (doc values in comments, values are placeholders): `NODE_ENV`, `DB_HOST` (session pooler host exactly as in the certificate), `DB_PORT` (doc: 5432, never 6543), `DB_NAME`, `DB_SSL_MODE`, `DB_SSL_ROOT_CERT_PATH`, `TRUST_PROXY_HOPS`, `CLIENT_IP_HEADER` (commented, with its Cloudflare condition), `ADMIN_ORIGIN`, `WEB_ORIGIN`, `MAIL_PROVIDER`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURE`, `MAIL_FROM`, `MEDIA_PROVIDER`, `CLOUDINARY_CLOUD_NAME`, `CLOUDINARY_API_KEY`, `CLOUDINARY_FOLDER`, `TURNSTILE_EXPECTED_HOSTNAME`, `JWT_ACCESS_KID`, `TOTP_ENC_KID`, `TOTP_ISSUER`, `BACKUP_STORAGE_ENDPOINT`, `BACKUP_STORAGE_REGION`, `BACKUP_STORAGE_BUCKET`, `BACKUP_STORAGE_PREFIX` (all six `BACKUP_STORAGE_*` or none); commented: `TOTP_ENC_PREVIOUS_KID`. `NODE_ENV`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_SSL_MODE`, `DB_SSL_ROOT_CERT_PATH` carry a comment: same value in `api-init-secrets`.
- `DB_SSL_MODE` comment: `verify-full` needs the `database-ca-configmap` mount, which `apps/cms-api/deployment.yaml` does not have yet (follow-up); with the file missing the process stops at boot naming `DB_SSL_ROOT_CERT_PATH`.
- Old cms-api keys:
  - Removed (a doc key has the same role): `TRUST_PROXY` (-> `TRUST_PROXY_HOPS`), `EMAIL_PROVIDER` (-> `MAIL_PROVIDER`), `EMAIL_FROM` (-> `MAIL_FROM`), `STORAGE_PROVIDER` (-> `MEDIA_PROVIDER`), `CORS_ORIGINS` (-> `ADMIN_ORIGIN`), `FRONTEND_URL` (-> `WEB_ORIGIN`), `RATE_LIMIT_FPS`, `RATE_LIMIT_BURST` (-> `LOGIN_RATE_LIMIT_*`, never set in production).
  - Kept, commented out, in `old config`: `JWT_REFRESH_SECRET`, `COOKIE_SECURE`, `COOKIE_SAMESITE`, `CONTENT_TYPES_DIR`, `MEDIA_MAX_UPLOAD_BYTES`, `AWS_REGION`, `AWS_S3_BUCKET`, `GMAIL_CLIENT_ID`, `GMAIL_CLIENT_SECRET`, `GMAIL_REFRESH_TOKEN`, `GMAIL_SENDER_EMAIL`, `RESEND_API_KEY`, `BREVO_API_KEY`, `REDIS_ENABLED`, `REDIS_URL`. Block comment: verify against `apps/cms-api/.env.example` (verification reference only).
  - Old keys with a doc name (`DB_*`, `CLOUDINARY_*`, `SMTP_*`, `JWT_ACCESS_SECRET`) are carried into the groups above.
- `api-configmap.example.yaml`: `metadata.name: api-configmap`; keys unchanged (`APP_SERVICE_NAME`, `APP_IMAGE_REPO`, `APP_PORT`); header names `shared-configmap` and `cluster-base/cms-api-sync.yaml`, and says runtime settings live in `api-secrets` (main container) and `api-init-secrets` (init container); this ConfigMap is for Flux only.
- U7: both files' comments lose every concrete example (`"3000"`, `cms-api-prod-secrets`, `5 / 10`, `10485760`, ...).

Verify:
- `git status` shows both files as renamed (`R`), not deleted and added.
- `python3 -c "import sys,yaml; [list(yaml.safe_load_all(open(f))) for f in sys.argv[1:]]" templates/api-secrets.example.yaml templates/api-configmap.example.yaml` exits 0.
- python check: active Secret keys equal the two lists above; ConfigMap `data` keys are exactly `{APP_SERVICE_NAME, APP_IMAGE_REPO, APP_PORT}`; every active value is a string and a `<...>` placeholder.
- The old-name grep on the two files finds nothing; `git check-ignore templates/api-secrets.yaml templates/api-configmap.yaml` prints both.

---

## P1-T2: Add the `api-init-secrets` and `database-ca-configmap` templates

Spec: `supabase-database.md` §4, §5; `k3s-secrets-sops.md` §1, §2, §6; `k3s-traefik.md` §3; `devops-runbook.md` §4.6; final naming; REPLAN 2026-10-27: `api-init-secrets` replaces `cms-api-migrate-db` / `api-migrate-secrets`; the init container is independent and reads only this Secret
Scope: core-builder
Paths: `templates/api-init-secrets.example.yaml` (new), `templates/database-ca-configmap.example.yaml` (new)
Deps: P1-T1 (header wording; the six shared settings must match `api-secrets`)
Security gate: yes

Acceptance criteria:
- `api-init-secrets.example.yaml`: Secret `api-init-secrets`, namespace `<app-namespace>-<app-env>`. Exact keys:
  - `secret values`: `DB_USERNAME` (`<migrator-role>.<project-ref>`; comment: Supabase docs default `postgres`, self-managed `abyss_migrator`; mode A: the same login as `api-secrets`), `DB_PASSWORD`.
  - `plain settings`: `NODE_ENV`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_SSL_MODE`, `DB_SSL_ROOT_CERT_PATH`, each with the comment: same value as in `api-secrets`. Doc values in comments as in P1-T1.
- Header: the init container always reads `api-init-secrets`, in both credential modes; it is its only `envFrom` source. In mode A it holds the same database account as `api-secrets` (`devops-runbook.md` §4.6); in mode B the migration role. the main container never reads it; it holds no app secret, because `deploy:migrate` reads only `DB_*` and `NODE_ENV`; rotation: reset the migrator password (Supabase: dashboard), then this Secret, no restart (the next rollout's init container reads it); a change to a shared database setting goes into both `api-secrets` and this Secret.
- `database-ca-configmap.example.yaml`: ConfigMap `database-ca-configmap`, one key `ca.crt` as a block scalar with `-----BEGIN CERTIFICATE----- / <ca-certificate> / -----END CERTIFICATE-----`. Header: public CA from Supabase Dashboard > Database settings > SSL (`supabase-database.md` S1); mounted read-only in the cms-api containers and the backup job at the path that `DB_SSL_ROOT_CERT_PATH` / `PGSSLROOTCERT` point to; key name `ca.crt` fixed; not read by Flux; the cms-api Deployment mounts it in both containers (added by RW-T2); word this without "yet" or "not yet", so the comment stays true after RW-T2.

Verify:
- YAML parse of both files exits 0.
- python check: `api-init-secrets` keys are exactly `{DB_USERNAME, DB_PASSWORD, NODE_ENV, DB_HOST, DB_PORT, DB_NAME, DB_SSL_MODE, DB_SSL_ROOT_CERT_PATH}`; the CA ConfigMap has exactly `{ca.crt}`.
- `git check-ignore templates/api-init-secrets.yaml templates/database-ca-configmap.yaml` prints both.

---

## P1-T3: Add the `backup-secrets` template

Spec: `supabase-database.md` §5, §7; `k3s-secrets-sops.md` §1, §2; `k3s-traefik.md` §7 ("Off-site bucket", "Nightly CronJob"); `devops-runbook.md` §4.4, §4.5
Scope: core-builder
Paths: `templates/backup-secrets.example.yaml` (new)
Deps: P1-T2 (refers to `database-ca-configmap`)
Security gate: yes

Acceptance criteria:
- Secret `backup-secrets`, namespace `<app-namespace>-<app-env>`.
- `secret values`: `DB_USERNAME` (`<backup-role>.<project-ref>`), `DB_PASSWORD`, `RCLONE_CONFIG_OFFSITE_ACCESS_KEY_ID`, `RCLONE_CONFIG_OFFSITE_SECRET_ACCESS_KEY`.
- `plain settings` (the docs' `postgres-backup-config` keys merged here; doc values in comments): `DB_HOST`, `DB_PORT`, `DB_NAME` (same values as `api-secrets`), `PGSSLMODE`, `PGSSLROOTCERT`, `BACKUP_BUCKET`, `BACKUP_PREFIX`, `BACKUP_MAX_DATABASE_BYTES`, `BACKUP_MAX_DUMP_BYTES`, `RCLONE_CONFIG_OFFSITE_TYPE`, `RCLONE_CONFIG_OFFSITE_PROVIDER`, `RCLONE_CONFIG_OFFSITE_ENDPOINT` (`https://<account-id>.<object-storage-host>`), `RCLONE_CONFIG_OFFSITE_NO_CHECK_BUCKET`, `BACKUP_AGE_RECIPIENT` (`<age-public-key>`); commented: `RCLONE_S3_UPLOAD_CONCURRENCY`, `RCLONE_S3_CHUNK_SIZE` (only when the pod is killed for memory).
- Header: backup CronJob only; the rclone token is the write-capable job token, never the read-only token in `api-secrets`; `BACKUP_AGE_RECIPIENT` is a public key, the private age key is never in the cluster or git; the role password is set with `\password` at a psql prompt (`supabase-database.md` S4); no restart after a change; if `BACKUP_PREFIX` changes, the R2 lifecycle and lock prefixes change too; the backup CronJob is not planned (user, 2026-10-27): this template is ready for when one is added.

Verify:
- YAML parse exits 0.
- python check: active keys equal the two lists above; all values are strings and placeholders.
- `git check-ignore templates/backup-secrets.yaml` prints the path.

---

## P1-T4: Rename and align the web, admin and shared templates

Spec: `k3s-secrets-sops.md` §1, §6; `k3s-traefik.md` §4, §5; placement and value rules; Q3, Q3a, option A; final naming
Scope: core-builder
Paths: `templates/frontend-secret.example.yaml` -> `templates/web-secrets.example.yaml` (git mv, then edit); `templates/frontend-configmap.example.yaml` -> `templates/web-configmap.example.yaml` (git mv, then edit); `templates/cms-admin-configmap.example.yaml` -> `templates/admin-configmap.example.yaml` (git mv, then edit); `templates/shared-configmap.example.yaml` (edit); `templates/admin-secrets.example.yaml` (new)
Deps: none
Security gate: yes

Acceptance criteria:
- `web-secrets.example.yaml`: `metadata.name: web-secrets`. `plain settings` adds the docs' web runtime values: `API_INTERNAL_URL` (`http://<api-service-name>.<app-namespace>-<app-env>.svc.cluster.local:<api-port>/api/v1`; server-only), `WEB_REVALIDATE_SECONDS` (doc: 60; 0 disables), `WEB_PORT` commented (unset uses the image default; if set it must equal `APP_PORT` in `web-configmap`).
- Old frontend keys: `APP_API_URL` stays active in its own block `transition: remove once the image reads API_INTERNAL_URL` (option A), with its `/auth/...` path note; header says to keep both base URLs consistent. Kept active in `old config`: `AUTH_SECRET`, `APP_API_TOKEN`, `REVALIDATE_TOKEN_SECRET`, `NEXT_ENV`; verify against `apps/frontend/.env.example` (verification reference only).
- `web-configmap.example.yaml`: `metadata.name: web-configmap`; keys unchanged; header notes `NEXT_PUBLIC_*` are build args and runtime values go in `web-secrets`.
- `admin-configmap.example.yaml`: `metadata.name: admin-configmap`; keys unchanged; header port line fixed (the Deployment uses `containerPort: 8080`, nginx-unprivileged per `k3s-traefik.md` §5); points to `admin-secrets` for runtime values.
- New `admin-secrets.example.yaml`: Secret `admin-secrets`; `plain settings` only: `CSP_CONNECT_SRC` commented (space-separated origins; overrides the CSP derived from the build-time API URL). Header: the docs give cms-admin no secret value; the Secret exists because the Deployment loads one; it may stay `stringData: {}`.
- `shared-configmap.example.yaml`: `metadata.name: shared-configmap`; keys unchanged; comments lose every concrete example (`staging.example.com`, `shared-config`) and name the per-app ConfigMaps by their new names.
- U7: the comments of all five files lose every concrete example (`"3000"`, `frontend-prod-secrets`, the `cms-api-<app-env>` Service URL example, `nginx listens on 80`).

Verify:
- `git status` shows the three moves as renames (`R`).
- YAML parse of the five files exits 0.
- python check on `web-secrets.example.yaml`: active keys are exactly `{API_INTERNAL_URL, WEB_REVALIDATE_SECONDS, APP_API_URL, AUTH_SECRET, APP_API_TOKEN, REVALIDATE_TOKEN_SECRET, NEXT_ENV}`; `data` keys of the three ConfigMaps are unchanged from before.
- The old-name grep on `templates/` finds nothing (after P1-T1 to P1-T4); `git check-ignore templates/web-secrets.yaml templates/admin-secrets.yaml templates/admin-configmap.yaml templates/web-configmap.yaml` prints all four.

---

## P1-T5: Update the configuration doc for the new templates

Spec: Q6; final naming
Scope: core-builder (scope extended to `docs/components/configuration.md`)
Paths: `docs/components/configuration.md`
Deps: P1-T1, P1-T2, P1-T3, P1-T4
Security gate: no

Acceptance criteria:
- `configuration.md`, "Where each value comes from": ConfigMap rows name `shared-configmap` and `api-configmap` / `admin-configmap` / `web-configmap`; Secret rows name `api-secrets` (main container), `api-init-secrets` (init container only; repeats the six shared database settings), `admin-secrets`, `web-secrets`, `backup-secrets`; one row lists `database-ca-configmap` as the exception (public CA mounted as a file, not read by Flux); the placement rule in one line.
- `configuration.md`: "Templates for all six" becomes the actual list of template files; one line notes that `database-ca-configmap` and `backup-secrets` take effect only once the cms-api Deployment mounts the CA (follow-up) and a backup CronJob is added (not planned), and that `DB_SSL_MODE=verify-full` needs the CA mount.
- Other docs (`docs/components/*.md`, `docs/DEPLOYMENT.md`, `README.md`) are not touched here: RW-T4 owns their object names and the cutover steps.

Verify:
- Every template path named in the doc exists: `grep -ohE 'templates/[a-z-]+\.example\.yaml' docs/components/configuration.md | sort -u | xargs ls`.
- `ls templates/*.example.yaml` lists no file `configuration.md` leaves out.
- The old-name grep on `docs/components/configuration.md` finds nothing.

---

Build order: P1-T1 and P1-T4 (parallel) -> P1-T2 -> P1-T3 -> P1-T5. Manifest wiring and the cutover are RW-T2 and the rename plan's cutover.

Depends on the rename (frontend -> web; separate request, not in Phase 1): `apps/frontend/` folder, `cluster-base/frontend-sync.yaml` and the `frontend-sync` name, the overlays `cluster/me/<env>/frontend-sync-overlay.yaml`, `APP_SERVICE_NAME` value `web`, `docs/components/frontend.md`, and the comments that still say "frontend". Object names and template file names are already `web-*` after Phase 1.

Follow-ups (not in Phase 1): mount `database-ca-configmap` in both cms-api containers (needed for `verify-full`); remove `APP_API_URL` from `web-secrets` once the image reads `API_INTERNAL_URL`.

## Design: `APP_API_URL` -> `API_INTERNAL_URL` (option A, user decision 2026-10-28)

- Decision: during the transition `web-secrets` carries both keys, pointing at the same cms-api base (`.../api/v1`). `API_INTERNAL_URL` is the doc key (`k3s-traefik.md` §4); `APP_API_URL` stays active in its own `transition` block until the web image reads `API_INTERNAL_URL`. A Secret created from the template therefore works with today's image and with the next one.
- Status: already applied by P1-T4 (`templates/web-secrets.example.yaml`, checked 2026-10-28). No new build task.
- Owner: `templates/web-secrets.example.yaml` is the only file that lists the web runtime keys; `apps/web/deployment.yaml` loads it whole (`envFrom: web-secrets`) and needs no change for a key added or removed.
- Extension path: the next renamed app key follows the same steps: add the new key next to the old one in that app's `<prefix>-secrets` template, mark the old one `transition`, remove it in one later edit of the same file once the image reads the new key.
- Removal (later, one task): delete the `transition` block from `templates/web-secrets.example.yaml`, then the user removes `APP_API_URL` from each live `web-secrets` and restarts web. Waits on the open questions below.
- Open (user): what the running image uses `APP_API_URL` for; who signals that the image reads `API_INTERNAL_URL`; prod follows the same option; whether the deployment docs (web: no Secret, plain `env`) or the repo (`web-secrets` via `envFrom`) is the target.
