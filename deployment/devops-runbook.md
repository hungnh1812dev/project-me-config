# DevOps runbook: GitHub Actions, k3s, FluxCD, Supabase

Owner's step-by-step Supabase setup (Vietnamese): `docs/deployment/supabase-owner-setup.md`.

The source of truth for deploying Abyss. It gives the order of work and the contract between this repo and the deploy repo; the per-topic guides hold the details and are linked, not repeated:

- `docs/ci-cd.md`: the CI workflows and the GitHub setup.
- `docs/deployment/k3s-traefik.md`: images, routing, the cms-api init container, the env contract, backups and the restore drill.
- `docs/deployment/k3s-secrets-sops.md`: SOPS + age, secret layout and rotation.
- `docs/deployment/supabase-database.md`: the Supabase guide (roles, runbook S1 to S8, TLS, secret map, backups on Supabase).
- ADR 0012 (database roles, Supabase), ADR 0013 (backup download, R2), SPEC §7 D7, D19, D20, SPEC §13 "Launch gate".

Written 2026-10-27. The owner reports (2026-10-27) that an earlier deployment with the same CI and deploy-repo contract (sections 3.4, 3.5, 4.1) ran successfully on a VPS with k3s and FluxCD. This repo's current workflows, its images and the whole Supabase path have not run here. Status marks used below:

| Mark                 | Meaning                                                                                                      |
| -------------------- | ------------------------------------------------------------------------------------------------------------ |
| **ready**            | exists in this repo and has been checked (tests, smoke stack or CI scripts)                                  |
| **pending `<task>`** | needs a task that is planned but not built yet; do not use it before that task is committed                  |
| **not run**          | written from docs or design and never run; the step named after it is what proves it                         |
| **deploy repo**      | owned by the deploy repo; this repo only states what it must provide; not verified here                      |
| **verified earlier** | verified earlier by the owner on a VPS with k3s and FluxCD (user report, 2026-10-27); not run from this repo |

> **Never public before the launch gate.** No public DNS record, public ingress or announced URL until phase LG has passed and the owner has approved the launch in writing (SPEC §13). The first production deploy is a private one (open decision Q-OPS4).

## 1. Who owns what

| Concern                                                                     | Owner                       | Where                                               |
| --------------------------------------------------------------------------- | --------------------------- | --------------------------------------------------- |
| Source code, Dockerfiles, tests                                             | this repo                   | `apps/*`                                            |
| CI: checks, image build, push to GHCR, image tag bump in the deploy repo    | this repo                   | `.github/workflows/`, `.github/scripts/`            |
| Database roles script                                                       | this repo                   | `scripts/db/database-roles.sql` (built, LG-db-2)    |
| Flux objects, k8s manifests, SOPS-encrypted Secrets, Traefik config         | deploy repo `<deploy-repo>` | its own layout (**deploy repo**, not verified here) |
| Nightly backup job and its image                                            | deploy repo                 | contract in `k3s-traefik.md` §7 and ADR 0013 §3     |
| Supabase project, R2 bucket, Cloudflare DNS and Turnstile, Cloudinary, SMTP | the owner (dashboards)      | sections 5, 6                                       |

`<deploy-repo>` is the same deploy repo as the owner's earlier deployment (owner, 2026-10-27). It stays a placeholder here until its `owner/name` is written down (Q-OPS1). The same value goes into the GitHub Environment variable `DEPLOYMENT_REPO`.

## 2. Blockers before the first production deploy

Read this first. The first three are hard blockers for Supabase; the others must be decided or done before LG-3.

| #   | Blocker                                                                                                                                                                                                                                                                                                                                                                                                                            | Why it blocks                                                                                                                                | Resolved by                                                                                                                       |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| B1  | ~~cms-api had no TLS setting for the database.~~ **Solved by LG-db-6** (built, awaiting commit): `DB_SSL_MODE` / `DB_SSL_ROOT_CERT_PATH` exist in the API, the init container and `prisma migrate deploy`. The image that carries LG-db-6 must be the one deployed.                                                                                                                                                                | With "Enforce SSL" on (Q-DB3) Supabase refuses a plain connection; with it off, the DB password and all data cross the internet unencrypted. | LG-db-6. Q-OPS2.                                                                                                                  |
| B2  | ~~The roles script did not exist.~~ **Built (LG-db-2, awaiting commit).** The runbook is `supabase-database.md` section 3 (S3 to S6). Not yet run on Supabase: `abyss_api` exists there (created by the owner) but has **no grants** until S3 runs, and `abyss_backup` is created by S3.                                                                                                                                           | The API cannot run as `abyss_api` before S3; the backup job has no role.                                                                     | S3 on the real project (LG-db-7), or the shared `postgres` account for both containers as an accepted risk (ADR 0012 §8). Q-OPS2. |
| B3  | ~~The migration commands loaded the full app config.~~ **Built (LG-db-1, awaiting commit).** The init container needs only `DB_*` and `NODE_ENV` (`cms-api-migrate-db`). The image that carries LG-db-1 must be the one deployed.                                                                                                                                                                                                  | Before that image, the init container must receive every app secret.                                                                         | LG-db-1 in the deployed image. Until then use mode A in section 4.6.                                                              |
| B4  | This repo's CI publish path has not run against GitHub yet (LG-0 item 3). The same contract is **verified earlier** on the owner's earlier deployment.                                                                                                                                                                                                                                                                             | No image exists in GHCR yet; the bump job has never pushed to the deploy repo.                                                               | Section 3.5.                                                                                                                      |
| B6  | ~~The backup job spec in `k3s-traefik.md` §7 wrote to `/tmp` and had no encryption.~~ **Solved by BK-doc:** §7 is the final text (stream, `age`, R2, lifecycle, restore drill).                                                                                                                                                                                                                                                    | It broke ADR 0013.                                                                                                                           | BK-doc.                                                                                                                           |
| B7  | R2 tokens: the ADR 0013 rule "the job key can write but cannot delete" is not proven. Cloudflare's token levels are Admin Read & Write, Admin Read only, Object Read & Write and Object Read only; "Object Read & Write" most likely includes delete. The bucket lock rules that fix this are written in `k3s-traefik.md` §7, "Off-site bucket" step 4; the owner's decision (Q-OPS6) and the delete-attempt proof are still open. | A stolen job key could then wipe every dump.                                                                                                 | Q-OPS6 (recommended: the R2 bucket lock rules).                                                                                   |

## Owner steps before deploy

Only these three are the owner's own checks before the first deploy:

1. **R2 bucket lock check (B7, Q-OPS6).** Set the bucket lock rules (`k3s-traefik.md` §7, "Off-site bucket" step 4), then prove that a delete attempt with the job key fails.
2. **Supabase `verify-full` psql check (S2, section 5).** The `psql ... sslmode=verify-full sslrootcert=ca.crt ... -c 'select version()'` command succeeds and shows PostgreSQL 17.
3. **Cloudflare Access decision (Q-OPS4).** Decide whether Cloudflare Access keeps `<domain>` and `admin.<domain>` private until the launch approval.

## 3. CI: GitHub Actions (this repo)

### 3.1 What runs, and when

Status: **ready** (workflows and their routing tests exist; `bash .github/scripts/affected.test.sh` and `pins-check.test.sh` pass locally). The pipeline shape is **verified earlier** (the owner's earlier deployment). **Not run here**: these workflows have not run on GitHub from this repo (B4).

```
push to develop | staging | main
  changes      turbo affected apps + deploy target from the branch
  repo         pins-check, format:check, pnpm audit --prod --audit-level high
  cms-api      typecheck, lint, test:unit, test:integration (Testcontainers),
               content:generate --check, graphql:print-schema --check, contract:print --check, build
  cms-admin    typecheck, lint, test, build
  web          typecheck, lint, test, build
  publish-<app>   only on push to staging/main, only when the app's image inputs changed and its flow is green
     image     per platform: build + load, non-root guard, (cms-admin) bundle check, push by digest
     manifest  merge digests, tag <branch>-<sha7> and <branch>
     deploy    commit "APP_IMAGE_TAG: <branch>-<sha7>" into the deploy repo and push it
```

- e2e (Playwright) never runs in CI. Before pushing to `staging` or `main`, run `SMOKE_E2E=1 pnpm smoke` locally (`docs/ci-cd.md`, "e2e").
- The `pull_request` trigger is commented out in `ci.yml`, so checks run only after a push to one of the three branches.
- One app failing never blocks another app's publish.

### 3.2 Branch to environment

| Branch    | GitHub Environment | Image platform | Runner         | Deploy repo branch bumped |
| --------- | ------------------ | -------------- | -------------- | ------------------------- |
| `develop` | none               | none           | none           | none (checks and build)   |
| `staging` | `staging`          | `linux/amd64`  | `ubuntu-24.04` | `staging`                 |
| `main`    | `production`       | `linux/amd64`  | `ubuntu-24.04` | `main`                    |

The images are single-platform: both the **staging** and the **production** k3s node must be **amd64** (x86_64).

### 3.3 Images and tags

| Image                                        | Port | User | Containers                                      |
| -------------------------------------------- | ---- | ---- | ----------------------------------------------- |
| `ghcr.io/hungnh1812dev/project-me/cms-api`   | 3000 | 1000 | init `migrate` and main `cms-api`, **same tag** |
| `ghcr.io/hungnh1812dev/project-me/web`       | 8080 | 1000 | `web`                                           |
| `ghcr.io/hungnh1812dev/project-me/cms-admin` | 8080 | 101  | `cms-admin`                                     |

- `<branch>-<sha7>` (for example `main-1a2b3c4`) is immutable and is the release identifier. The moving `<branch>` tag is for humans only; never reference it in a manifest, or a rollback cannot pin a version.
- Each app is bumped only when its own image changed, so the three apps can sit on different tags. That is expected.
- There is no git tag or GitHub Release today. Q-OPS5 asks whether one is wanted.
- Build-time values are baked into the images (so a change needs a new image, not a restart): web `NEXT_PUBLIC_API_BASE_URL`, `NEXT_PUBLIC_ADMIN_URL`, `NEXT_PUBLIC_TURNSTILE_SITE_KEY`; cms-admin `VITE_API_BASE_URL`.

### 3.4 How the tag reaches the deploy repo (owner answer, 2026-10-27)

Status: the contract is **verified earlier** (verified earlier by the owner on a VPS with k3s and FluxCD (user report, 2026-10-27)). This repo's `_publish.yml` is **not run here**.

The owner's answer: the image tag reaches the deploy repo through GitHub. CI commits the tag change into the deploy repo, and Flux then reconciles it. No Flux image automation is needed for this.

The deploy target comes from two GitHub Actions **variables**. They are not secrets.

| Variable                  | Read in the workflow as        | Meaning                                                                                        | Value                                                   |
| ------------------------- | ------------------------------ | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| `DEPLOYMENT_REPO`         | `vars.DEPLOYMENT_REPO`         | `owner/name` of the deploy repo                                                                | `<deploy-repo>` (Q-OPS1)                                |
| `DEPLOYMENT_CLUSTER_PATH` | `vars.DEPLOYMENT_CLUSTER_PATH` | the directory inside the deploy repo that holds this cluster's `<app>-sync-overlay.yaml` files | `<cluster-path>` (for example one path per environment) |

Where to set them: Settings > Secrets and variables > Actions > **Variables**, either as repository variables or as Environment variables on `staging` and `production`. The deploy job runs inside the GitHub Environment (`environment: staging|production`), so it reads both levels. An Environment variable overrides a repository variable with the same name. Use repository variables when both environments use the same value, and Environment variables when the value differs per environment (usually `DEPLOYMENT_CLUSTER_PATH`). If `DEPLOYMENT_CLUSTER_PATH` is empty, the job fails with "DEPLOYMENT_CLUSTER_PATH is not set for this environment". The only secret in this step is `DEPLOYMENT_REPO_TOKEN`, and it must be an Environment secret (`docs/ci-cd.md`).

What the deploy job in `_publish.yml` does today (**ready** in code; the same steps are **verified earlier**; **not run here**):

1. Checks out `vars.DEPLOYMENT_REPO` at branch `staging` or `main` with `DEPLOYMENT_REPO_TOKEN`, without storing the token.
2. Opens `${DEPLOYMENT_CLUSTER_PATH}/<app>-sync-overlay.yaml` inside that checkout and fails if the file or a line `APP_IMAGE_TAG:` is missing.
3. Replaces the value on that line with `"<branch>-<sha7>"`. If nothing changes, it stops.
4. Commits `chore(<branch>): bump <app> to <branch>-<sha7>` as `github-actions[bot]` and pushes **directly** to the branch. If the push is rejected, it rebases and retries, up to 3 attempts.
5. Only one bump runs at a time per environment (`concurrency: deploy-<environment>`).

The job pushes a commit; it does not open a pull request. If the deploy repo's `main` branch requires pull requests, the push is rejected. Q-OPS3 decides whether to keep the direct push or add a pull request mode.

Deploy repo carried over (owner answers, 2026-10-27): Abyss uses the same deploy repo as the owner's earlier deployment, with the same contract: the variables `DEPLOYMENT_REPO` and `DEPLOYMENT_CLUSTER_PATH`, the Environment secret `DEPLOYMENT_REPO_TOKEN`, and the `APP_IMAGE_TAG:` line. It is **verified earlier** on that deployment and still **not run** from this repo (B4). Before the first publish, the deploy repo needs one change, on both `staging` and `main`:

- Rename the public site's overlay to `web-sync-overlay.yaml`, because the bump job opens that name and fails if it is missing. Point the web Deployment at `ghcr.io/hungnh1812dev/project-me/web`. The earlier setup called this app `frontend`.
- This repo does not store the token in the checkout's git config (`persist-credentials: false`). The token is sent only as a header in the push step.

### 3.5 GitHub setup checklist (owner)

Status: this setup is **verified earlier** (verified earlier by the owner on a VPS with k3s and FluxCD (user report, 2026-10-27)). Items that are new for Abyss, such as the `web-sync-overlay.yaml` rename, the build-arg variables and the status-check names, are **not run here**.

The owner reported on 2026-10-27 that the Environments, branch rules and secrets are already set up. Check each item against this list:

1. Environments `staging` and `production`. Deployment branches: `staging` only for the `staging` Environment, `main` only for `production`. No required reviewers on `production` in v1 (owner, 2026-10-27). The gate is the protected `main` branch plus the `main`-only deployment branch rule.
2. Variables `DEPLOYMENT_REPO=<deploy-repo>` and `DEPLOYMENT_CLUSTER_PATH=<cluster-path>`, as repository or Environment variables (section 3.4). In each Environment, set the variables `VITE_API_BASE_URL`, `NEXT_PUBLIC_API_BASE_URL`, and optionally `NEXT_PUBLIC_ADMIN_URL` and `NEXT_PUBLIC_TURNSTILE_SITE_KEY`. Also set the secret `DEPLOYMENT_REPO_TOKEN`: a fine-grained PAT or a GitHub App token, limited to `<deploy-repo>`, with `contents: write` and an expiry date. Meaning of each: `docs/ci-cd.md`, "What you must create in GitHub".
3. Protect the `staging` and `main` branches in this repo (pull request review required). Required status checks: only `Repo checks` for now (owner, 2026-10-27). After the first green run, add the real check names shown on that run, such as the `<app> / Checks` and `<app> / Build` jobs, here and in the branch rule.
4. The branches `staging` and `main` exist in the deploy repo, and each holds the three `<app>-sync-overlay.yaml` files under `DEPLOYMENT_CLUSTER_PATH`: `cms-api`, `cms-admin` and `web` (renamed from the earlier setup's overlay, section 3.4).
5. GHCR packages stay **private** (owner, 2026-10-27). After the first push, the owner checks the three packages in GitHub Packages. The old package of the earlier setup's public site is a candidate for deletion, but only after the owner confirms. This is a note, not an action.

First-run proof for this repo (**not run here**):

1. Push to `staging`. All jobs are green.
2. `docker buildx imagetools inspect ghcr.io/hungnh1812dev/project-me/cms-api:staging-<sha7>` shows `linux/amd64`.
3. The deploy repo `staging` branch has one bump commit per published app.
4. On the staging node, `node -e "require('sharp')"` loads inside the cms-api image (the earlier sharp check in `k3s-traefik.md` covered the other CPU architecture only).
5. Repeat on `main`. The image shows `linux/amd64`.

The manager records the result under LG-0 item 3.

## 4. Deploy repo contract (k3s + Flux)

Everything in this section is **deploy repo**. The deploy repo owns its Flux layout: GitRepository, Kustomization or HelmRelease, and paths. This repo has no record of that layout and does not fix it. The deploy repo must provide each item below. The example YAML in `k3s-traefik.md` is a reference to copy from, not a required layout.

### 4.1 Flux reconciliation

Status: the source, the bump file and the reconcile flow are **verified earlier** (verified earlier by the owner on a VPS with k3s and FluxCD (user report, 2026-10-27)). The Abyss manifests, the `$` substitution check and the `dependsOn` order are **not run here**.

- A Flux source that tracks `<deploy-repo>`, branch `main` on the production cluster and `staging` on the staging cluster. The bump commit (section 3.4) is the only thing that changes an image tag.
- `<DEPLOYMENT_CLUSTER_PATH>/<app>-sync-overlay.yaml` for `cms-api`, `web` and `cms-admin`. Each file has exactly one line `APP_IMAGE_TAG: "<tag>"`, and that value ends up as the image tag of that app. The owner's earlier deployment used the same file pattern and line (section 3.4). For `cms-api` it is the tag of both containers. How the deploy repo maps the value to the manifests is its own choice: for example a Flux Kustomization with `spec.postBuild.substitute.APP_IMAGE_TAG`.
- If the deploy repo uses Flux `postBuild` variable substitution: Flux substitutes `${...}` in every manifest of that Kustomization. Shell scripts inside manifests (the backup job in `k3s-traefik.md` §7, written with `$$`) must then either be in a Kustomization without substitution, carry the annotation `kustomize.toolkit.fluxcd.io/substitute: disabled`, or escape `$` as `$$`. **Not run**: check it with `flux build kustomization <name> --path <path>` before the first apply.
- SOPS decryption on the Kustomization that applies Secrets: `spec.decryption: { provider: sops, secretRef: { name: sops-age } }`. The `sops-age` Secret is created once by hand (`k3s-secrets-sops.md` §3).
- No Flux image automation (ImageRepository, ImagePolicy, ImageUpdateAutomation) on these images. CI already writes the tag, and two writers would fight over the same field.
- Recommended order of application (deploy repo decision): config and Secrets, then cms-api, then web and cms-admin. With Flux this is `dependsOn` plus `wait: true` on the cms-api Kustomization, so a new web never waits on an API that is still migrating. **Not run**.

### 4.2 Namespace, pull secret, cluster prerequisites

- Namespace: recommended `abyss` on both clusters (one cluster per environment, `k3s-secrets-sops.md` §2). In the commands below it is written `<ns>`.
- The GHCR packages are private (owner, 2026-10-27), so the cluster needs a `kubernetes.io/dockerconfigjson` Secret `ghcr-pull` in `<ns>`, referenced as `imagePullSecrets` by all three Deployments. Its token needs only `read:packages`. GHCR does not accept fine-grained PATs for packages, so a classic PAT with only that scope, from an account that can read the packages, is the usual choice. **Not run**: check it with `kubectl -n <ns> run pull-test --image=ghcr.io/hungnh1812dev/project-me/cms-admin:<tag> --overrides='{"spec":{"imagePullSecrets":[{"name":"ghcr-pull"}]}}' --restart=Never`, then delete the pod.
- K3s with its bundled Traefik. A `HelmChartConfig` sets `externalTrafficPolicy: Local` and redirects `web` to `websecure` (`k3s-traefik.md` §1, §2).
- The node's CPU architecture matches the environment's image platform (section 3.2). Check with `kubectl get nodes -o wide` and `kubectl get node <n> -o jsonpath='{.status.nodeInfo.architecture}'`.

### 4.3 Workloads

| Workload          | Kind       | Replicas | Containers                                                                         | Probes                                                           | Strategy                                            |
| ----------------- | ---------- | -------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------- | --------------------------------------------------- |
| `cms-api`         | Deployment | 1        | init `migrate` (`npm run --silent deploy:migrate`), main `cms-api` (image default) | live `/api/v1/health/live`, ready `/api/v1/health/ready` on 3000 | `RollingUpdate`, `maxSurge: 1`, `maxUnavailable: 0` |
| `web`             | Deployment | 1        | `web`                                                                              | `/` on 8080                                                      | same                                                |
| `cms-admin`       | Deployment | 1        | `cms-admin`                                                                        | `/` on 8080                                                      | same                                                |
| `postgres-backup` | CronJob    | -        | `dump`                                                                             | -                                                                | `concurrencyPolicy: Forbid`                         |

Exactly one replica each (`k3s-traefik.md` §8). Pod security: `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, drop all capabilities. Resource starting points and full manifests: `k3s-traefik.md` §3-§5. `web` gets `API_INTERNAL_URL=http://cms-api.<ns>.svc.cluster.local:3000/api/v1` and `WEB_REVALIDATE_SECONDS=60` as plain `env`. `cms-admin` has no runtime config.

Note: In this repo (`apps/web`), web loads the Secret `web-secrets` through `envFrom`: `API_INTERNAL_URL` and `WEB_REVALIDATE_SECONDS`. The plain-`env` description here is the reference design, not what this repo deploys.

Routing (IngressRoutes, `k3s-traefik.md` §1): `<domain>` with `/api` at priority 20 goes to `cms-api:3000`; `<domain>` at priority 10 goes to `web:8080`; `admin.<domain>` goes to `cms-admin:8080`. Never StripPrefix.

### 4.4 ConfigMaps

`cms-api-config`, which both cms-api containers read (`envFrom`). The authoritative key list is `apps/cms-api/.env.example`.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cms-api-config
  namespace: <ns>
data:
  NODE_ENV: production
  PORT: '3000'
  # Supabase session pooler (section 5): host from Dashboard > Connect > Session pooler
  DB_HOST: <pooler-host>
  DB_PORT: '5432' # session pooler; never 6543
  DB_NAME: postgres
  DB_SSL_MODE: verify-full # disable (default) | require | verify-full
  DB_SSL_ROOT_CERT_PATH: /etc/abyss/database-ca/ca.crt # absolute path; required with verify-full
  TRUST_PROXY_HOPS: '1'
  CLIENT_IP_HEADER: cf-connecting-ip # only when Cloudflare proxies and the origin accepts Cloudflare ranges only
  ADMIN_ORIGIN: https://admin.<domain>
  WEB_ORIGIN: https://<domain>
  MAIL_PROVIDER: smtp
  SMTP_HOST: <relay>
  SMTP_PORT: '<port>'
  SMTP_SECURE: '<true|false>'
  MAIL_FROM: Abyss CMS <no-reply@<domain>>
  MEDIA_PROVIDER: cloudinary
  CLOUDINARY_CLOUD_NAME: <name>
  CLOUDINARY_API_KEY: <key>
  CLOUDINARY_FOLDER: <folder>
  TURNSTILE_EXPECTED_HOSTNAME: <domain>
  JWT_ACCESS_KID: <kid>
  TOTP_ENC_KID: <kid>
  TOTP_ISSUER: <name shown in authenticator apps>
  # Backup download (ADR 0013); all six BACKUP_STORAGE_* keys or none
  BACKUP_STORAGE_ENDPOINT: https://<account-id>.r2.cloudflarestorage.com
  BACKUP_STORAGE_REGION: auto
  BACKUP_STORAGE_BUCKET: <bucket>
  BACKUP_STORAGE_PREFIX: postgres/
```

Never set these in production: `LOGIN_RATE_LIMIT_*`, `REFRESH_RATE_LIMIT_IP`, `ALLOW_LOGIN_RATE_LIMIT_OVERRIDE` (boot fails), `OWNER_EMAIL` / `OWNER_DISPLAY_NAME` (CLI only). `DB_USERNAME` goes in the Secrets, not here (section 4.5).

Database TLS keys (both go in `cms-api-config`, read by the init container and the main container; neither is a secret):

| Key                     | Value in production             | Notes                                                                                                                                                                                               |
| ----------------------- | ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DB_SSL_MODE`           | `verify-full`                   | `disable` is the default and is only for local stacks. `require` encrypts without checking the server and is not used. `verify-full` also checks the CA and that the certificate matches `DB_HOST`. |
| `DB_SSL_ROOT_CERT_PATH` | `/etc/abyss/database-ca/ca.crt` | Absolute path of the mounted CA (PEM). Required with `verify-full`; the process fails at boot, naming this key, when the file is missing, unreadable or not a PEM certificate.                      |

`DB_HOST` must be the pooler host exactly as in the certificate. With `verify-full`, an IP address or an alias that the certificate does not list fails the connection. The backup job uses the libpq names for the same CA (`PGSSLMODE`, `PGSSLROOTCERT`, below).

`database-ca` holds the Supabase CA certificate, which is public. It is mounted read-only at `/etc/abyss/database-ca` in both cms-api containers and in the backup job:

```yaml
apiVersion: v1
kind: ConfigMap
metadata: { name: database-ca, namespace: <ns> }
data:
  ca.crt: |
    -----BEGIN CERTIFICATE-----
    <the certificate downloaded in step S1>
    -----END CERTIFICATE-----
```

`postgres-backup-config` (backup job, section 6): `DB_HOST`, `DB_PORT`, `DB_NAME` (the same values as above), `PGSSLMODE=verify-full`, `PGSSLROOTCERT=/etc/abyss/database-ca/ca.crt`, `BACKUP_BUCKET`, `BACKUP_PREFIX=postgres/`, `BACKUP_MAX_DATABASE_BYTES=400000000`, `BACKUP_MAX_DUMP_BYTES=200000000`.

### 4.5 Secrets (SOPS-encrypted in the deploy repo)

| Secret               | Keys                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | Mounted into                                  |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| `cms-api-secrets`    | `DB_USERNAME`, `DB_PASSWORD`, `JWT_ACCESS_SECRET`, `OTP_PEPPER`, `TOTP_ENC_KEY`, `CLOUDINARY_API_SECRET`, `TURNSTILE_SECRET_KEY`, `SMTP_USER`, `SMTP_PASSWORD`, `BACKUP_STORAGE_ACCESS_KEY_ID`, `BACKUP_STORAGE_SECRET_ACCESS_KEY`; temporary: `OWNER_SETUP_TOKEN` (first install), `TOTP_ENC_PREVIOUS_KEY` (rotation)                                                                                                                                               | main container `cms-api` (and init in mode A) |
| `cms-api-migrate-db` | `DB_USERNAME=postgres.<project-ref>`, `DB_PASSWORD` (the project's database password)                                                                                                                                                                                                                                                                                                                                                                                | init container `migrate` only (mode B)        |
| `postgres-backup`    | `DB_USERNAME=abyss_backup.<project-ref>`, `DB_PASSWORD`, rclone remote `offsite` as env: `RCLONE_CONFIG_OFFSITE_TYPE=s3`, `RCLONE_CONFIG_OFFSITE_PROVIDER=Cloudflare`, `RCLONE_CONFIG_OFFSITE_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com`, `RCLONE_CONFIG_OFFSITE_ACCESS_KEY_ID`, `RCLONE_CONFIG_OFFSITE_SECRET_ACCESS_KEY`, `RCLONE_CONFIG_OFFSITE_NO_CHECK_BUCKET=true`, `BACKUP_AGE_RECIPIENT` (public key, kept with the job's config, as in BK-doc) | backup CronJob only                           |
| `ghcr-pull`          | registry login (the packages are private)                                                                                                                                                                                                                                                                                                                                                                                                                            | all Deployments, as `imagePullSecrets`        |
| `sops-age`           | the cluster's age private key; created by hand, never in git                                                                                                                                                                                                                                                                                                                                                                                                         | Flux (its own namespace)                      |

The value of each secret, its length rule and how to rotate it: `k3s-secrets-sops.md` §1, §7. `JWT_ACCESS_SECRET`, `OTP_PEPPER` and `TOTP_ENC_KEY` must each be at least 32 bytes (`openssl rand -base64 48`). The rclone keys are **not run**; the first backup run proves them (section 6).

### 4.6 Database credential modes for cms-api

Pick one per environment and record the choice under LG-0 item 6.

| Mode                                               | When                                                   | init `migrate` `envFrom`                                      | main `cms-api` `envFrom`            | `cms-api-secrets.DB_USERNAME` |
| -------------------------------------------------- | ------------------------------------------------------ | ------------------------------------------------------------- | ----------------------------------- | ----------------------------- |
| **A: shared account** (ADR 0012 §8, accepted risk) | until LG-db-1 and LG-db-2 are committed and S3 has run | `cms-api-config`, `cms-api-secrets`                           | `cms-api-config`, `cms-api-secrets` | `postgres.<project-ref>`      |
| **B: split roles** (target, ADR 0012 §9)           | after LG-db-1, LG-db-2 and Supabase steps S3-S6        | `cms-api-config`, `cms-api-migrate-db` (no `cms-api-secrets`) | `cms-api-config`, `cms-api-secrets` | `abyss_api.<project-ref>`     |

Both modes also mount `database-ca` (both containers) and need the image with LG-db-6 (B1) to reach Supabase. In mode A, the boot warning from LG-db-5 (once built) shows in the cms-api log on every start; that is expected. Mode A needs the owner's written acceptance (LG-0 item 6).

Volume snippet for both containers:

```yaml
volumeMounts:
  - { name: database-ca, mountPath: /etc/abyss/database-ca, readOnly: true }
# pod spec
volumes:
  - name: database-ca
    configMap: { name: database-ca }
```

### 4.7 Routing and CORS

**Rule:** Traefik must not redirect (308 or any other 3xx) any request to `/api/v1/*`, including the CORS preflight `OPTIONS`, from the admin and web origins. A browser does not follow a redirect on a preflight, so a trailing-slash redirect on the API breaks browser calls. The only allowed redirect is `web` to `websecure` (HTTP to HTTPS), which browsers never reach because the apps call `https://` URLs. Do not add a redirect or trailing-slash middleware to the `/api` router, and pass the path through unchanged (no StripPrefix).

Origins the API must allow (set in the cms-api ConfigMap, scheme + host, no path, no trailing slash):

- `ADMIN_ORIGIN` = `https://admin.<domain>` (the only CORS origin).
- `WEB_ORIGIN` = `https://<domain>` (not a CORS origin; it is in the Origin allowlist of the refresh-cookie endpoints). Use the exact key name from `apps/cms-api/.env.example`.

Check, for each origin (expect a 2xx status and no `Location` header):

```bash
curl -i -X OPTIONS "https://<domain>/api/v1/<path>" \
  -H "Origin: https://admin.<domain>" \
  -H "Access-Control-Request-Method: POST"
```

Repeat with `Origin: https://<domain>` and with a path that ends in `/`. A `3xx` status or a `Location` header means a router or middleware redirects the API: fix it in the Traefik config (`k3s-traefik.md` §1).

## 5. Supabase setup (once per project)

Run from a workstation with `psql` 17 and the Supabase CA. Never from a pod. The detailed guide is `supabase-database.md` section 3; the owner's dashboard steps (S1, S2) with their checks are in `supabase-owner-setup.md`. The step names S1-S8 are those of ADR 0012 §9.6.

Values to copy from the dashboard: `<project-ref>`, and `<pooler-host>` (Connect > Session pooler, port 5432). Connection user names always carry the suffix: `<role>.<project-ref>`. Inside the database, and in the script variables, the plain role name is used.

| Step | What                                                                                                                                                                                                                                                                                  | Status                                                                                                                                            |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| S1   | In the dashboard: Data API off; "Automatically expose new tables" off where it is still shown; Database > SSL: "Enforce SSL on incoming connections" on; download the CA certificate (it goes into `database-ca`); network restrictions to the VPS egress IP if the plan offers them. | owner, doable now. Turn "Enforce SSL" on once the image with LG-db-6 is deployed and `DB_SSL_MODE=verify-full` is set, or the app cannot connect. |
| S2   | `psql "host=<pooler-host> port=5432 dbname=postgres user=postgres.<project-ref> sslmode=verify-full sslrootcert=ca.crt" -c 'select version()'` succeeds and shows PostgreSQL 17.                                                                                                      | **not run**; this step is its own proof                                                                                                           |
| S3   | Roles script, first run: `psql "<S2 connection string>" -v ON_ERROR_STOP=1 -v hosting=supabase -v migrator_role=postgres -v api_role=abyss_api -v backup_role=abyss_backup -v data_api_roles=anon,authenticated,service_role -f scripts/db/database-roles.sql`                        | script built (LG-db-2); **not run** on Supabase                                                                                                   |
| S4   | `\password abyss_backup` at the psql prompt (value from `openssl rand -base64 32`). `abyss_api` already has the password the owner set.                                                                                                                                               | after S3; `supabase-database.md` S4                                                                                                               |
| S5   | Write `cms-api-config`, `database-ca`, `cms-api-secrets`, `cms-api-migrate-db`, `postgres-backup` (section 4) with SOPS, commit to the deploy repo, let Flux apply them, roll out. The init container migrates as `postgres`.                                                         | **deploy repo**, **not run**                                                                                                                      |
| S6   | Run S3 again. It must end without error (the self-check; the meta tables are now restricted).                                                                                                                                                                                         | after S5; **not run**                                                                                                                             |
| S7   | `curl -fsS https://<domain>/api/v1/health/ready` returns `{"status":"ok"}`; no database role warning in `kubectl -n <ns> logs deploy/cms-api -c cms-api`; a request to `https://<project-ref>.supabase.co/rest/v1/` with the anon key returns no app table.                           | **not run** (LG-db-7)                                                                                                                             |
| S8   | Rotation: `\password abyss_api` or `\password abyss_backup`; rotate the `postgres` password in the dashboard; then update the matching Secret and restart the workload that uses it.                                                                                                  | runbook                                                                                                                                           |

Supabase limits to watch:

- The free project pauses after 7 days of low activity. The owner accepted this for launch (Q-DB6). While the project is paused, `/health/ready` fails and web shows errors. Restore the project in the dashboard.
- The database limit is 500 MB, and the backup job warns at 400 MB (section 6).
- **Not run:** one cms-api pod opens up to three `pg` pools (Prisma adapter plus two content pools, `pg` default `max` 10 each). During a rollout, two pods run at the same time. Compare that with the session pooler's pool size (Dashboard > Database > Connection pooling). If the total can pass the pool size, say so before launch. Pool sizes have no env key today, so a cap would be a new task.
- Never use port 6543 (transaction pooler): it breaks Prisma migrate and the advisory locks.

## 6. Backups: R2 bucket and nightly job

Design: ADR 0013. The final text (bucket rules, the CronJob, the size checks, the restore drill with `age -d`, the cms-admin download) is `k3s-traefik.md` §7; Supabase specifics are in `supabase-database.md` section 7. All of it is **not run** (LG-0 item 4).

Setup order (owner, then deploy repo):

1. R2 bucket with no public access and no custom domain, lifecycle rules (`postgres/daily/` 14 days, `postgres/monthly/` 92 days), the two bucket-scoped tokens, and the bucket lock rules (B7, Q-OPS6): `k3s-traefik.md` §7, "Off-site bucket".
2. Generate the age key pair on the owner's machine. The public key becomes `BACKUP_AGE_RECIPIENT`; the private key stays offline in two copies, never on the VPS.
3. The deploy repo builds the job image (Q-OPS8: `pg_dump` and `psql` 17, `age`, `rclone`, a shell with `pipefail`) and adds the CronJob, the ConfigMap `postgres-backup-config` and the Secret `postgres-backup` (section 4). Check `$` and Flux substitution (section 4.1).
4. Give cms-api the read-only token as `BACKUP_STORAGE_*` (section 4.4, 4.5).
5. Alerts (deploy repo): the job failed, or no new `daily/` object in 26 hours.
6. Run the job once by hand (section 7 step 10), then the restore drill. Those two runs are the proof.

## 7. First install, in order

1. Section 2 blockers B1-B3 solved or accepted (Q-OPS2). B5 (LG-pg17) is done.
2. CI first run green on `staging` (section 3.5).
3. Staging cluster: k3s, Traefik config, Flux bootstrapped on `<deploy-repo>` branch `staging`, the `sops-age` Secret and `ghcr-pull` (deploy repo).
4. Supabase S1 and S2. Then S3 and S4 (mode B), or skip to mode A.
5. R2 bucket, tokens and age key (section 6).
6. Write the ConfigMaps and Secrets (section 4) for staging. Add `OWNER_SETUP_TOKEN` (`openssl rand -base64 32`) for the first install.
7. Flux applies the manifests. Check in this order: `flux get sources git`, `flux get kustomizations` (all Ready), then `kubectl -n <ns> get pods`. The cms-api pod goes `Init:0/1`, then `Running`. `kubectl -n <ns> logs <pod> -c migrate` lists the applied migrations.
8. S6, then S7.
9. Owner: open `https://admin.<domain>/setup`, create the owner, turn on TOTP, then remove `OWNER_SETUP_TOKEN` and restart (`k3s-traefik.md` §3, "First install").
10. Trigger the backup job once by hand: `kubectl -n <ns> create job --from=cronjob/postgres-backup backup-manual-1`. The object appears in R2 and on the admin Backups page. Run the restore drill once.
11. Release checklist in `k3s-traefik.md` §9. Repeat steps 3-10 for production on `main`, still private (Q-OPS4). Then hand over to LG-3.

## 8. A normal release and the rollout order

1. Merge into `staging` (or `main`). CI publishes the changed apps and pushes one bump commit per app into the deploy repo.
2. Flux sees the commit on its next interval. To pull it at once: `flux reconcile source git <source>` and `flux reconcile kustomization <name>`.
3. cms-api: the new pod's init container runs `deploy:migrate`. The old pod keeps serving (`maxUnavailable: 0`). The new main container starts only after the init container exits 0, and the old pod stops when the new one is ready.
4. web and cms-admin roll the same way. If the deploy repo applies the recommended `dependsOn` (section 4.1), they roll after cms-api is ready.
5. Check: `kubectl -n <ns> rollout status deploy/cms-api` (then `web`, `cms-admin`), `curl -fsS https://<domain>/api/v1/health/ready`, and the release checklist in `k3s-traefik.md` §9.

Rules for every release:

- Migrations are forward only. Prisma `migrate deploy` and `content:migrate` have no down step. During a rollout the old pod runs against the new schema, so a destructive change (dropping or renaming a column, a table or a content type) needs two releases: expand first, contract later (`k3s-traefik.md` §3).
- A new content type takes effect only through a committed generated migration. CI fails a missing one.
- A change to a build-time value (section 3.3) needs a new image: push a commit, or re-run the publish.

## 9. Rollback and failure handling

| Situation                                                     | What to do                                                                                                                                                                                                                                                                                                                                                                               | Status                                       |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| Bad app release, schema compatible                            | In the deploy repo, `git revert <bump commit>`, or set `APP_IMAGE_TAG` back to the previous `<branch>-<sha7>`, and push. Flux rolls back. Do not use `kubectl rollout undo`: Flux would put the new tag back.                                                                                                                                                                            | **not run**                                  |
| Need to stop Flux from changing anything                      | `flux suspend kustomization <name>`; resume with `flux resume kustomization <name>`. The next CI bump waits in git and is not applied while suspended.                                                                                                                                                                                                                                   | **not run**                                  |
| Init container fails (`Init:Error` / `Init:CrashLoopBackOff`) | The old pod keeps serving. Read the cause with `kubectl -n <ns> logs <pod> -c migrate`. A config error lists the key names. A wrong DB password: fix the Secret. A failed migration: fix forward with a new commit, or revert the bump.                                                                                                                                                  | ready (behaviour checked on the smoke stack) |
| A Prisma migration failed halfway                             | Prisma records it as failed and refuses every later `migrate deploy`. Repair the database by hand as the migrator, then run `npx prisma migrate resolve --rolled-back <migration>` (or `--applied`) with the migrator credentials in a one-off pod from the same image. Run the next rollout. Take the Prisma command from the Prisma 7 docs at the time; this step was never rehearsed. | **not run**                                  |
| Release changed the schema and must be undone                 | There is no down migration. Either fix forward, or restore the latest dump into a new database (restore drill, `k3s-traefik.md` §7), point `DB_NAME` / `DB_HOST` at it and roll out the old tag. Data written since the dump is lost.                                                                                                                                                    | **not run**                                  |
| Supabase project paused                                       | Restore it in the dashboard, then `kubectl -n <ns> rollout restart deploy/cms-api` if readiness does not recover by itself.                                                                                                                                                                                                                                                              | **not run**                                  |
| Secret leaked                                                 | Rotate per `k3s-secrets-sops.md` §7, then the age key if it was the cause.                                                                                                                                                                                                                                                                                                               | runbook                                      |

## 10. Verification list (everything still "not run here")

| Item                                                                    | Proven by                                                                   | Recorded under    |
| ----------------------------------------------------------------------- | --------------------------------------------------------------------------- | ----------------- |
| CI publish and the deploy repo bump (contract verified earlier)         | section 3.5 first-run proof for this repo                                   | LG-0 item 3       |
| Flux applies the bump (flow verified earlier); `$` substitution is safe | `flux build kustomization`, then the first staging rollout (section 7)      | LG-0 item 4       |
| GHCR pull from the cluster                                              | the pull test in section 4.2                                                | LG-0 item 4       |
| DB TLS `verify-full` from cms-api                                       | LG-db-6 manual proof, then S7                                               | LG-db-6, LG-db-7  |
| Roles and grants on Supabase                                            | S3 and S6 self-check                                                        | LG-db-7           |
| Data API closed                                                         | S7 anon request                                                             | LG-db-7           |
| Pooler connection budget                                                | section 5 check                                                             | LG-0 item 4       |
| Real client IP through Cloudflare and Traefik                           | `k3s-traefik.md` §9 step 5, SPEC §12-8                                      | LG-0 item 4, LG-3 |
| Backup job, R2 tokens, lifecycle, lock                                  | manual job run (section 7 step 10); a delete attempt with the job key fails | LG-0 item 4       |
| Restore drill                                                           | `k3s-traefik.md` §7                                                         | LG-0 item 4       |
| Rollback by revert                                                      | one revert on staging after the first release                               | LG-0 item 4       |
| `readOnlyRootFilesystem` on cms-admin                                   | `k3s-traefik.md` §5                                                         | LG-0 item 4       |

## 11. Open owner decisions

Each question has a recommended answer. When the owner answers, the planner records it here and in the task files.

- **Q-OPS1** Answered in part (2026-10-27): the same deploy repo as the earlier setup. Still open: its `owner/name`, for this file only, because CI reads it from `DEPLOYMENT_REPO`.
- **Q-OPS2** Supabase blockers B1-B3. Recommended: un-pause LG-db-6 (TLS, required for any Supabase deploy), LG-db-1 and LG-db-2 now, and launch in mode B. Trade-off: mode A needs only LG-db-6, but it keeps the shared `postgres` account in the API (ADR 0012 §8) and needs the owner's written acceptance.
- **Q-OPS3** Answered (2026-10-27): direct push, as built. No required reviewers on `production` in v1; the gate is the protected `main` branch plus the `main`-only deployment branch rule.
- **Q-OPS4** How do we keep the first production deploy private until the launch approval? Recommended: Cloudflare Access on `<domain>` and `admin.<domain>`, allowing only the owner's and the testers' e-mails, removed at launch. Trade-off: the alternative (no DNS record, a hosts-file entry on the testers' machines) needs no Cloudflare setup, but TLS and the Cloudflare client-IP header are then not tested the way they will run in production.
- **Q-OPS5** Do we want a git tag or a GitHub Release per production deploy? Recommended: not for v1. The `main-<sha7>` image tag and the deploy repo's bump commits are the release log. Trade-off: semver tags make releases easier to name, but they need a new CI task.
- **Q-OPS6** R2 delete protection for the job key (B7). Recommended: an R2 bucket lock rule on `postgres/daily/` (14 days) and `postgres/monthly/` (92 days), proven by a delete attempt with the job key. Trade-off: without it, the "cannot delete" rule of ADR 0013 does not hold, and a stolen VPS key can wipe the backups.
- **Q-OPS7** Answered (2026-10-27): private, with the `ghcr-pull` Secret. The owner checks GitHub Packages after the first push. The old package of the earlier site is deleted only after the owner confirms.
- **Q-OPS8** Where is the backup job image built? Recommended: in the deploy repo, as a small Alpine image with `postgresql17-client`, `age` and `rclone`, pinned by digest. Trade-off: installing packages at job start needs no image, but it is slow, it depends on the network at 02:15, and it is not pinned.
- **Q-OPS9** Which namespace? Recommended: `abyss` on both clusters.
