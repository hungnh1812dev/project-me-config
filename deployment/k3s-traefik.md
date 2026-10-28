# Deployment guide: K3s + Traefik

For the separate deploy repo (SPEC §1, §6, D7). Deploy order, blockers and the repo-to-deploy-repo contract: `docs/deployment/devops-runbook.md`. This repo builds and publishes the images (`docs/ci-cd.md`); the deploy repo owns the manifests, secrets and backups. Everything below is a contract plus example manifests to copy from, not files that live here. Names in `<angle brackets>` are yours to choose. The database is either the in-cluster PostgreSQL StatefulSet (sections 3 and 7, the self-managed path) or a Supabase project (production, `docs/deployment/supabase-database.md`); each place below says which one it describes.

Scope in v1: one VPS, K3s with the bundled Traefik, **one replica per app**, PostgreSQL 17 in the cluster on a PVC.

## 1. Images and the three public hosts

| Image (from `docs/ci-cd.md`)                 | Runs as                      | Port | Role                                                 |
| -------------------------------------------- | ---------------------------- | ---- | ---------------------------------------------------- |
| `ghcr.io/hungnh1812dev/project-me/cms-api`   | uid 1000                     | 3000 | REST + GraphQL API, and the migration init container |
| `ghcr.io/hungnh1812dev/project-me/web`       | uid 1000                     | 8080 | public site, Next.js standalone on Node (not nginx)  |
| `ghcr.io/hungnh1812dev/project-me/cms-admin` | uid 101 (nginx-unprivileged) | 8080 | admin console, static files                          |

Every image has a numeric non-root user, so `runAsNonRoot: true` works. Pin the images with the tag the publish job writes to `APP_IMAGE_TAG` in the overlay; cms-api uses **one tag for both of its containers**.

| Host               | Path            | Goes to                  |
| ------------------ | --------------- | ------------------------ |
| `domain.com`       | `/api/*`        | cms-api Service (3000)   |
| `domain.com`       | everything else | web Service (8080)       |
| `admin.domain.com` | all             | cms-admin Service (8080) |

Rules that matter:

- **Never StripPrefix.** cms-api serves under `/api/v1`; the router passes the path through untouched.
- **`/api` must win over the web catch-all.** Set explicit `priority` values (below) instead of relying on rule length.
- Web and API share the origin `https://domain.com` (refresh cookie `__Secure-abyss_rt` is host-only, `Path=/api/v1/auth`). The admin is a different origin and is the only CORS origin.
- TLS terminates at Traefik (`websecure`); nothing in the apps speaks TLS.
- **No redirect on `/api/v1/*`**, not even a trailing-slash 308, and never on a CORS preflight `OPTIONS`. See `devops-runbook.md` section 4.7 for the check.

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: abyss-public
  namespace: <namespace>
spec:
  entryPoints: [websecure]
  routes:
    - kind: Rule
      match: Host(`domain.com`) && PathPrefix(`/api`)
      priority: 20
      services:
        - name: cms-api
          port: 3000
    - kind: Rule
      match: Host(`domain.com`)
      priority: 10
      services:
        - name: web
          port: 8080
  tls:
    secretName: <domain-com-tls> # or certResolver: <resolver>
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: abyss-admin
  namespace: <namespace>
spec:
  entryPoints: [websecure]
  routes:
    - kind: Rule
      match: Host(`admin.domain.com`)
      services:
        - name: cms-admin
          port: 8080
  tls:
    secretName: <admin-domain-com-tls>
```

Add a `web` entrypoint redirect to HTTPS in your Traefik config. The smoke stack (`docker-compose.smoke.yml`) uses the same routers with labels; the assertions in `pnpm smoke` check `/api` reaching cms-api, the web catch-all and the admin host.

## 2. Client IP: `externalTrafficPolicy: Local` and `TRUST_PROXY_HOPS`

Rate limits (login, refresh, reviewer sessions) are keyed by client IP. cms-api reads it from `X-Forwarded-For`, so the IP Traefik sees must be the real one (SPEC D7).

1. Set `externalTrafficPolicy: Local` on the Traefik Service. With the default `Cluster`, kube-proxy source-NATs the connection and every client appears as a node IP, so all visitors share one rate-limit bucket. On K3s the bundled Traefik is configured through a `HelmChartConfig` in `kube-system`:

   ```yaml
   apiVersion: helm.cattle.io/v1
   kind: HelmChartConfig
   metadata:
     name: traefik
     namespace: kube-system
   spec:
     valuesContent: |-
       service:
         spec:
           externalTrafficPolicy: Local
   ```

   The Traefik pod must run on the node that receives the traffic (one VPS: it does). Check with `kubectl -n kube-system get svc traefik -o jsonpath='{.spec.externalTrafficPolicy}'`.

2. Set `TRUST_PROXY_HOPS` on cms-api to the number of proxies between the client and the API that append to `X-Forwarded-For`:

   | Topology                                   | `TRUST_PROXY_HOPS` | `CLIENT_IP_HEADER` |
   | ------------------------------------------ | ------------------ | ------------------ |
   | client -> Traefik -> cms-api               | `1` (default)      | unset              |
   | client -> Cloudflare -> Traefik -> cms-api | `1`                | `cf-connecting-ip` |

   Never `true`: it trusts every hop and lets a client forge its IP. Behind Cloudflare, Traefik's peer is a Cloudflare address, so use `CLIENT_IP_HEADER=cf-connecting-ip`, and only when the origin accepts traffic from Cloudflare ranges alone (firewall or Traefik `forwardedHeaders.trustedIPs`), otherwise a client can send that header itself. Do not add other proxies (an extra ingress, a service mesh) without raising the value.

## 3. cms-api: init container + main container

One Deployment, one pod template, **the same image for both containers**:

| Container | Kind | Command                       | Does                                                                                                                                                                                                                    |
| --------- | ---- | ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `migrate` | init | `npm run deploy:migrate`      | `db:migrate` (Prisma `migrate deploy`, then the idempotent role/permission seed), then `content:migrate` (apply pending `content/migrations` and sync `content._content_types` from `content/migrations/snapshot.json`) |
| `cms-api` | main | `node dist/main.js` (default) | serves the API                                                                                                                                                                                                          |

A new or changed `content/schemas/*.json` takes effect only after `pnpm content:generate` and a commit of the generated migration (SPEC D10); the init container never reads the schemas.

Behaviour to rely on:

- The main container starts only after the init container **exits 0**. A failed migration leaves the pod in `Init:Error` / `Init:CrashLoopBackOff` and, with `maxUnavailable: 0`, the old ReplicaSet keeps serving. Look at it with `kubectl logs <pod> -c migrate`.
- It applies only **committed** migrations. It never runs `content:generate` (CI fails a missing migration with `content:generate --check`) and never creates the owner (setup page or `owner:bootstrap`, see First install).
- Concurrent runs are safe: Prisma takes its own migrate lock and the content runner takes `pg_advisory_xact_lock`. v1 still runs a single replica.
- The command is safe to re-run: with nothing pending it prints "No pending migrations to apply." / "No pending content migrations." and exits 0.
- During a rollout the old pod keeps running against the **new** schema while the init container runs. Destructive content migrations (drop or rename a column or content type) therefore need expand/contract: release 1 adds the new shape and the code that tolerates both, release 2 removes the old one.
- The init container loads only the database part of the configuration (`DB_*`, `NODE_ENV`), so it gets `cms-api-config` plus its own Secret `cms-api-migrate-db` (`DB_USERNAME` and `DB_PASSWORD` of the migration role), and **not** `cms-api-secrets`. The main container gets `cms-api-config` plus `cms-api-secrets` (the API role and every app secret). Neither container holds the other's database credential. `DB_USERNAME` is therefore in neither ConfigMap nor shared Secret.
- Use `RollingUpdate` with `maxSurge: 1`, `maxUnavailable: 0`, so the new pod migrates before the old one stops. Do not use `Recreate`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cms-api
  namespace: <namespace>
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }
  selector:
    matchLabels: { app: cms-api }
  template:
    metadata:
      labels: { app: cms-api }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
      initContainers:
        - name: migrate
          image: ghcr.io/hungnh1812dev/project-me/cms-api:<APP_IMAGE_TAG>
          command: ['npm', 'run', '--silent', 'deploy:migrate']
          envFrom:
            - configMapRef: { name: cms-api-config }
            - secretRef: { name: cms-api-migrate-db } # migration role only; no app secrets
          volumeMounts: # Supabase only (DB_SSL_MODE=verify-full)
            - {
                name: database-ca,
                mountPath: /etc/abyss/database-ca,
                readOnly: true,
              }
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits: { memory: 512Mi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
      containers:
        - name: cms-api
          image: ghcr.io/hungnh1812dev/project-me/cms-api:<APP_IMAGE_TAG>
          ports:
            - containerPort: 3000
          envFrom:
            - configMapRef: { name: cms-api-config }
            - secretRef: { name: cms-api-secrets } # API role + app secrets
          volumeMounts: # Supabase only (DB_SSL_MODE=verify-full)
            - {
                name: database-ca,
                mountPath: /etc/abyss/database-ca,
                readOnly: true,
              }
          livenessProbe:
            httpGet: { path: /api/v1/health/live, port: 3000 }
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: /api/v1/health/ready, port: 3000 }
            periodSeconds: 5
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits: { memory: 768Mi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
      volumes: # Supabase only: the public CA certificate (ConfigMap `database-ca`)
        - name: database-ca
          configMap: { name: database-ca }
---
apiVersion: v1
kind: Service
metadata:
  name: cms-api
  namespace: <namespace>
spec:
  selector: { app: cms-api }
  ports:
    - port: 3000
```

Probes: `GET /api/v1/health/live` and `/ready` answer `{"status":"ok"}` only. `ready` checks the database. Memory: image uploads are re-encoded with sharp, which at the 50-megapixel guard uses about 200 MB on top of the Node baseline (about 120 MB idle), so keep the limit at 768Mi or more. The numbers above are starting points; adjust after watching `kubectl top pod`. The image bundles the sharp binary for its own platform (checked: `node -e "require('sharp')"` loads sharp 0.35.5 on linux/arm64 Alpine); after building for another architecture run the same check.

### First install: the owner

The owner is created once, through the admin setup page (primary) or the `owner:bootstrap` CLI (fallback). Neither is part of init. The setup page is open only while `OWNER_SETUP_TOKEN` is set and no owner exists; with no token configured the route answers 404.

1. Generate a token (at least 32 bytes): `openssl rand -base64 32`.
2. Add it to the encrypted Secret as `OWNER_SETUP_TOKEN` (`docs/deployment/k3s-secrets-sops.md`), apply, and roll out cms-api so both containers read it.
3. Open `https://admin.<domain>/setup`, enter the token, the owner email, an optional display name and a password (12 characters or more), and submit. The page sends you to the login page; sign in, then turn on two-factor in Security settings.
4. Remove `OWNER_SETUP_TOKEN` from the Secret, apply and restart. Once an owner exists the route is closed anyway (404), and cms-api logs a warning at boot while the token is still set. Leaving it in the Secret only keeps a dead credential around.

A wrong token answers 401 and is audited (`owner.setup_rejected`); the route is throttled to 5 submits per 15 minutes per client IP. The token goes only in the request body, never in a URL, and is never a build arg.

Fallback, when the setup page is not usable (for example the admin is not deployed yet):

```
kubectl -n <namespace> exec -it deploy/cms-api -c cms-api -- \
  env OWNER_EMAIL=owner@domain.com npm run owner:bootstrap
```

The password is typed at a hidden prompt (use `--password-stdin` to pipe it). Both paths share one rule: a second owner is refused (`OWNER_EXISTS` from the CLI, 404 from the route). Break-glass: `npm run owner:reset-2fa -- --email <email>` the same way as the CLI above.

### Database roles (first install)

Three login roles, so that a compromised API process cannot change the schema (SPEC D19, ADR 0012):

| Role (default name) | Used by                                         | Rights                                                                                    |
| ------------------- | ----------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `abyss_migrator`    | init container `migrate`, the restore drill     | owns the database; runs the DDL of the migrations                                         |
| `abyss_api`         | main container `cms-api` and the CLIs run in it | `SELECT, INSERT, UPDATE, DELETE` and sequence use; `SELECT` only on the three meta tables |
| `abyss_backup`      | backup CronJob                                  | read only (`pg_read_all_data`)                                                            |

On Supabase the same split is run by `docs/deployment/supabase-database.md` (steps S1 to S8). For the in-cluster PostgreSQL, once per environment, with the superuser inside the Postgres pod. `scripts/db/database-roles.sql` is the only place that creates roles and grants; it holds no password.

1. The Postgres StatefulSet is up with the Secret `postgres-superuser` (`POSTGRES_USER`, `POSTGRES_PASSWORD`). No app pod mounts it.
2. Run the script as the superuser (first run, before the first rollout):

   ```
   kubectl -n <ns> exec -i postgres-0 -- psql -U <superuser> -d <db> -v ON_ERROR_STOP=1 \
     -v hosting=self_managed -v migrator_role=abyss_migrator -v api_role=abyss_api -v backup_role=abyss_backup \
     -f - < scripts/db/database-roles.sql
   ```

3. Set the three passwords at a psql prompt, so they never land in a file or in the shell history. Generate each with `openssl rand -base64 32`:

   ```
   kubectl -n <ns> exec -it postgres-0 -- psql -U <superuser> -d <db>
   \password abyss_migrator
   \password abyss_api
   \password abyss_backup
   ```

4. Write the Secrets `cms-api-secrets` (`DB_USERNAME=abyss_api`), `cms-api-migrate-db` (`DB_USERNAME=abyss_migrator`) and `postgres-backup` (`DB_USERNAME=abyss_backup`) with SOPS (`docs/deployment/k3s-secrets-sops.md`), keep `DB_USERNAME` out of `cms-api-config`, and apply.
5. Roll out cms-api. The init container migrates as `abyss_migrator`.
6. Run step 2 again. It must end without error: the meta tables now exist, so the script restricts them, and the self-check proves it. A missed second run shows here.
7. Rotation, per role: `\password <role>` at a psql prompt, update that role's Secret, then restart its user (cms-api: `rollout restart`; migrator: the next rollout; backup: the next run).

In production, cms-api logs one warning at boot when its own role can run DDL (superuser, `CREATE` on the database or on `public` or `content`, or owner of objects there). It still starts. Seeing it on `abyss_api` means step 2 did not run.

## 4. web

Next.js standalone server run by Node as uid 1000. It is not behind nginx; its security headers (CSP with a per-request nonce) come from Next.js itself.

| Kind        | Name                             | Value in this deployment                                                           |
| ----------- | -------------------------------- | ---------------------------------------------------------------------------------- |
| build arg   | `NEXT_PUBLIC_API_BASE_URL`       | `/api/v1` (same origin). Baked into the browser bundle at **image build**.         |
| build arg   | `NEXT_PUBLIC_ADMIN_URL`          | `https://admin.domain.com` (optional; hides the "Open CMS" link when empty)        |
| build arg   | `NEXT_PUBLIC_TURNSTILE_SITE_KEY` | public Cloudflare site key (optional; hides "Reviewer access" when empty)          |
| runtime env | `API_INTERNAL_URL`               | in-cluster Service URL: `http://cms-api.<namespace>.svc.cluster.local:3000/api/v1` |
| runtime env | `WEB_REVALIDATE_SECONDS`         | `60` (data cache for server-side fetches; `0` disables it)                         |
| runtime env | `WEB_PORT`                       | `8080` (image default)                                                             |

The build args are GitHub Environment variables (`docs/ci-cd.md`, "What you must create in GitHub"); changing one means a new image, not a new rollout of the old one. The runtime variables are read by the Node server at start, so changing them needs a pod restart. `API_INTERNAL_URL` is server-only: it never reaches the browser, and the server calls cms-api anonymously.

Note: In this repo (`apps/web`), web loads the Secret `web-secrets` through `envFrom`: `API_INTERNAL_URL` and `WEB_REVALIDATE_SECONDS`. The plain-`env` description here is the reference design, not what this repo deploys.

```yaml
containers:
  - name: web
    image: ghcr.io/hungnh1812dev/project-me/web:<APP_IMAGE_TAG>
    ports:
      - containerPort: 8080
    env:
      - {
          name: API_INTERNAL_URL,
          value: 'http://cms-api.<namespace>.svc.cluster.local:3000/api/v1',
        }
      - { name: WEB_REVALIDATE_SECONDS, value: '60' }
    readinessProbe:
      httpGet: { path: /, port: 8080 }
      periodSeconds: 5
    livenessProbe:
      httpGet: { path: /, port: 8080 }
      initialDelaySeconds: 10
      periodSeconds: 10
    resources:
      requests: { cpu: 50m, memory: 128Mi }
      limits: { memory: 384Mi }
    securityContext:
      allowPrivilegeEscalation: false
      capabilities: { drop: [ALL] }
```

The probe on `/` renders the home page on the server, which fetches content from cms-api, so a pod whose API is down may report not ready; `kubectl rollout status` then waits on the API too. Resources: the Node process idles around 60 MiB and grows with the data cache and concurrent renders; 128Mi request and 384Mi limit are a starting point. The web response carries no `X-Powered-By` header.

## 5. cms-admin

Static files on `nginx-unprivileged` (uid 101, port 8080). `VITE_API_BASE_URL` is a **build arg**: the full API base, for example `https://api.<domain>/api/v1`. The CSP `connect-src` is derived from it at container start; `CSP_CONNECT_SRC` (space-separated origins) overrides it at run time if the API origin ever differs. No other runtime configuration. Probe `GET /` on 8080.

```yaml
containers:
  - name: cms-admin
    image: ghcr.io/hungnh1812dev/project-me/cms-admin:<APP_IMAGE_TAG>
    ports:
      - containerPort: 8080
    readinessProbe:
      httpGet: { path: /, port: 8080 }
    resources:
      requests: { cpu: 20m, memory: 32Mi }
      limits: { memory: 128Mi }
    securityContext:
      allowPrivilegeEscalation: false
      capabilities: { drop: [ALL] }
```

If you set `readOnlyRootFilesystem: true`, mount `emptyDir` volumes on `/tmp`, `/var/cache/nginx` and `/etc/nginx/security` (the entrypoint renders the CSP file there). This was not tried; test it before relying on it.

## 6. Environment contract (cms-api)

Validated at boot by `apps/cms-api/src/config/Env.schema.ts`; the process refuses to start on any error. The authoritative, commented list is `apps/cms-api/.env.example`. Put the Secret column in a Secret, the rest in a ConfigMap.

| Variable                                                                                             |  Secret  |      Required in production      | Production value                                                                                                                         |
| ---------------------------------------------------------------------------------------------------- | :------: | :------------------------------: | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `NODE_ENV`                                                                                           |          |               yes                | `production` (enables the guards below)                                                                                                  |
| `PORT`                                                                                               |          |                                  | `3000`                                                                                                                                   |
| `DB_HOST`, `DB_NAME`                                                                                 |          |               yes                | the Postgres Service or the Supabase session pooler host; database                                                                       |
| `DB_PORT`                                                                                            |          |                                  | `5432` (on Supabase always the session pooler, never `6543`)                                                                             |
| `DB_USERNAME`                                                                                        |   yes    |               yes                | per container: `abyss_api` in `cms-api-secrets`, `abyss_migrator` in `cms-api-migrate-db` (on Supabase with the `.<project-ref>` suffix) |
| `DB_PASSWORD`                                                                                        |   yes    |               yes                | the password of that role, next to its `DB_USERNAME`                                                                                     |
| `DB_SSL_MODE`                                                                                        |          |                                  | `verify-full` on Supabase; `disable` (default) for the in-cluster Postgres                                                               |
| `DB_SSL_ROOT_CERT_PATH`                                                                              |          |        with `verify-full`        | `/etc/abyss/database-ca/ca.crt` (ConfigMap `database-ca`, read-only mount)                                                               |
| `TRUST_PROXY_HOPS`, `CLIENT_IP_HEADER`                                                               |          |                                  | see section 2                                                                                                                            |
| `ADMIN_ORIGIN`                                                                                       |          |               yes                | `https://admin.domain.com` (scheme + host, no trailing slash)                                                                            |
| `WEB_ORIGIN`                                                                                         |          |               yes                | `https://domain.com`                                                                                                                     |
| `MAIL_PROVIDER`                                                                                      |          |               yes                | `smtp` (`console` is rejected in production)                                                                                             |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURE`, `MAIL_FROM`                                                 |          |           with `smtp`            | your mail relay; `MAIL_FROM` e.g. `Abyss CMS <no-reply@domain.com>`                                                                      |
| `SMTP_USER`, `SMTP_PASSWORD`                                                                         |   yes    |         both or neither          |                                                                                                                                          |
| `MEDIA_PROVIDER`                                                                                     |          |               yes                | `cloudinary` (`fake` is rejected in production)                                                                                          |
| `CLOUDINARY_CLOUD_NAME`, `CLOUDINARY_API_KEY`, `CLOUDINARY_FOLDER`                                   |          | name and key (with `cloudinary`) | from the Cloudinary console                                                                                                              |
| `CLOUDINARY_API_SECRET`                                                                              |   yes    |               yes                |                                                                                                                                          |
| `TURNSTILE_SECRET_KEY`                                                                               |   yes    |      for reviewer sessions       | real key; unset answers 503 on `POST /reviewer/sessions`                                                                                 |
| `TURNSTILE_EXPECTED_HOSTNAME`                                                                        |          |                                  | `domain.com`                                                                                                                             |
| `JWT_ACCESS_SECRET`, `OTP_PEPPER`, `TOTP_ENC_KEY`                                                    |   yes    |               yes                | each at least 32 bytes: `openssl rand -base64 48`                                                                                        |
| `JWT_ACCESS_KID`, `TOTP_ENC_KID`                                                                     |          |               yes                | key ids; change them when rotating the matching secret                                                                                   |
| `TOTP_ENC_PREVIOUS_KEY` / `TOTP_ENC_PREVIOUS_KID`                                                    | yes / no |                                  | only during a TOTP key rotation (both or neither)                                                                                        |
| `TOTP_ISSUER`                                                                                        |          |                                  | name shown in authenticator apps                                                                                                         |
| `BACKUP_STORAGE_ENDPOINT`, `BACKUP_STORAGE_REGION`, `BACKUP_STORAGE_BUCKET`, `BACKUP_STORAGE_PREFIX` |          |         all six or none          | the backup bucket (section 7, "Backup download"); none set turns the Backups page off                                                    |
| `BACKUP_STORAGE_ACCESS_KEY_ID`, `BACKUP_STORAGE_SECRET_ACCESS_KEY`                                   |   yes    |       with the four above        | a read-only bucket token (list and get)                                                                                                  |
| `LOGIN_RATE_LIMIT_*`, `REFRESH_RATE_LIMIT_IP`, `ALLOW_LOGIN_RATE_LIMIT_OVERRIDE`                     |          |                                  | **never set in production** (startup fails; smoke/e2e only)                                                                              |

Web and admin have no secrets (section 4 and 5). Database: the API runs as `abyss_api` (no DDL) and `deploy:migrate` runs as the migration role, each with its own Secret; the roles and the first-install steps are in section 3, "Database roles (first install)", and for Supabase in `docs/deployment/supabase-database.md`. Never reuse the Cloudflare always-pass test keys outside test stacks.

### Secrets: SOPS or sealed-secrets

Secrets never go into the deploy repo in plain text. Pick one:

- **SOPS + age**: keep `cms-api-secrets.sops.yaml` in the deploy repo, encrypted to an age key; the cluster decrypts with Flux/Argo's SOPS support (or `sops -d | kubectl apply -f -` in a manual flow). Keep the private age key off the repo and back it up separately.
- **sealed-secrets**: run the controller in the cluster, create the Secret locally, `kubeseal` it, commit the `SealedSecret`. Back up the controller's sealing key; without it the committed files cannot be decrypted after a cluster rebuild.

Layout, creation and rotation with SOPS are in `docs/deployment/k3s-secrets-sops.md`. Either way: one Secret per app, rotate with the KID variables (`JWT_ACCESS_KID`, `TOTP_ENC_KID`) changed together with the key, and restart the pod after any Secret change (env is read at start).

## 7. PostgreSQL: where it runs, nightly dump, restore drill

PostgreSQL 17 in both cases. One database holds everything: the Prisma-managed `public` tables and the content engine's `content` schema, so **one dump of those two schemas covers the whole app** and a restore needs nothing else.

Where it runs:

- **Supabase (production).** A free project reached through the session pooler on 5432. Roles, TLS, secrets and the Supabase specifics of the backup: `docs/deployment/supabase-database.md`. The free plan has no automatic backups, so the job below is the only copy.
- **In-cluster (self-managed alternative).** `postgres:17-alpine` as a single-replica StatefulSet with a PVC (K3s `local-path` storage class is enough on one VPS; it is node-local, so the off-site dump is the only copy that survives losing the disk). Roles: section 3, "Database roles (first install)".

The `pg_dump` in the backup image must be at least the server's major version (17); an older `pg_dump` refuses to dump a newer server.

What the backup covers: the whole database (accounts, audit logs, `file_library` rows, all content and its migration history). It does **not** contain the uploaded files themselves: they live in Cloudinary (`MEDIA_PROVIDER=cloudinary`); back that up with Cloudinary's own tooling.

Design and decisions: ADR 0013 (nothing on the VPS, encrypted, a bucket that holds at most about 20 objects).

### Off-site bucket (Cloudflare R2, owner)

1. Create the bucket `<bucket>` with **no public access and no custom domain**. The endpoint is the S3 API host `https://<account-id>.r2.cloudflarestorage.com`. It is the endpoint for rclone and for `BACKUP_STORAGE_ENDPOINT`. Presigned download URLs work only on that host, not on a custom domain.
2. Lifecycle rules (bucket Settings > Object Lifecycle Rules), expiring objects by prefix: `postgres/daily/` after 14 days, `postgres/monthly/` after 92 days. R2 removes an expired object typically within 24 hours of its expiry time, so a day or two more than 14 daily objects may exist for a short while. If you change `BACKUP_PREFIX`, change the prefixes here.
3. Two API tokens, each limited to this bucket:
   - the **job token**: Object Read & Write. It puts and lists objects. R2 has no write level without delete, so this token can also delete until step 4 is in place.
   - the **cms-api token**: Object Read only (list and get). It goes into `cms-api-secrets` as `BACKUP_STORAGE_*`.
4. Bucket lock rules (bucket Settings > Bucket lock rules): `postgres/daily/` for 14 days and `postgres/monthly/` for 92 days. A lock blocks deleting or overwriting an object for its period, whoever asks, and it takes precedence over the lifecycle rule, which then deletes the object when the period ends. This is what makes "the job key cannot delete" true. Prove it once: a `rclone deletefile` with the job key on a fresh object must fail (`devops-runbook.md` Q-OPS6, blocker B7).
5. Generate an age key pair on the owner's machine with `age-keygen -o abyss-backup.agekey`. Only the public key (`age1...`) goes to the job, as `BACKUP_AGE_RECIPIENT`. **The private key is kept offline in two copies and is never on the VPS or in the cluster.** Losing it makes every dump unreadable.

Object keys are `<prefix>daily/abyss-<YYYYMMDDTHHMMSSZ>.dump.age` and `<prefix>monthly/abyss-<YYYYMMDDTHHMMSSZ>.dump.age`, with `<prefix>` `postgres/` by default.

### Nightly CronJob

One stream, no temporary file, no volume: `pg_dump -Fc | age | rclone rcat`. The job pod has no writable volume besides the read-only CA mount. The image (built in the deploy repo) needs `pg_dump` and `psql` 17, `age`, `rclone` and a shell with `pipefail` (check `sh -c 'set -o pipefail'` in your image; Alpine's busybox `sh` supports it).

Config the job reads (names only; values are yours):

- ConfigMap `postgres-backup-config`: `DB_HOST`, `DB_PORT`, `DB_NAME` (the same as `cms-api-config`), `PGSSLMODE`, `PGSSLROOTCERT` (Supabase: `verify-full` and `/etc/abyss/database-ca/ca.crt`), `BACKUP_BUCKET`, `BACKUP_PREFIX`, `BACKUP_MAX_DATABASE_BYTES`, `BACKUP_MAX_DUMP_BYTES`.
- Secret `postgres-backup`: `DB_USERNAME`, `DB_PASSWORD`, the rclone remote `offsite` as `RCLONE_CONFIG_OFFSITE_*` variables, and `BACKUP_AGE_RECIPIENT` (a public key, kept with the job's config). Layout and template: `docs/deployment/k3s-secrets-sops.md`.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-backup
  namespace: <namespace>
spec:
  schedule: '15 2 * * *' # UTC
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          restartPolicy: Never
          securityContext:
            { runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000 }
          containers:
            - name: dump
              image: <image with pg_dump 17, psql, age, rclone>
              command: ['sh', '-c']
              args:
                - |
                  set -eu -o pipefail
                  export PGPASSWORD="$$DB_PASSWORD"
                  conn="-h $$DB_HOST -p $$DB_PORT -U $$DB_USERNAME -d $$DB_NAME"
                  stamp="$$(date -u +%Y%m%dT%H%M%SZ)"
                  name="abyss-$${stamp}.dump.age"
                  daily="offsite:$${BACKUP_BUCKET}/$${BACKUP_PREFIX}daily/$${name}"
                  status=0

                  size="$$(psql $$conn -Atc 'select pg_database_size(current_database())')"
                  echo "database size: $${size} bytes"
                  if [ "$$size" -gt "$$BACKUP_MAX_DATABASE_BYTES" ]; then echo "WARN database over limit"; status=1; fi

                  pg_dump $$conn -Fc -n public -n content \
                    | age -r "$$BACKUP_AGE_RECIPIENT" \
                    | rclone rcat \
                        --header-upload "Content-Type: application/octet-stream" \
                        --header-upload "Content-Disposition: attachment; filename=\"$${name}\"" \
                        "$$daily"

                  dump="$$(rclone size --json "$$daily" | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p')"
                  echo "dump size: $${dump} bytes"
                  if [ "$$dump" -gt "$$BACKUP_MAX_DUMP_BYTES" ]; then echo "WARN dump over limit"; status=1; fi

                  if [ "$$(date -u +%d)" = 01 ]; then
                    rclone copyto "$$daily" "offsite:$${BACKUP_BUCKET}/$${BACKUP_PREFIX}monthly/$${name}"
                  fi
                  exit "$$status"
              envFrom:
                - configMapRef: { name: postgres-backup-config }
                - secretRef: { name: postgres-backup }
              volumeMounts: # Supabase only
                - {
                    name: database-ca,
                    mountPath: /etc/abyss/database-ca,
                    readOnly: true,
                  }
              resources:
                requests: { cpu: 50m, memory: 128Mi }
                limits: { memory: 384Mi }
              securityContext:
                allowPrivilegeEscalation: false
                capabilities: { drop: [ALL] }
          volumes: # Supabase only
            - name: database-ca
              configMap: { name: database-ca }
```

- `$$` is for Flux `postBuild` substitution, which replaces `${...}` in every manifest of a Kustomization. Without it, write plain `$`. Check with `flux build kustomization <name> --path <path>` before the first apply (`devops-runbook.md` section 4.1).
- `set -o pipefail` makes a failed `pg_dump` fail the job. An S3 multipart upload becomes visible only when it completes, so a half-written dump is never listed.
- The size checks warn, keep the dump, and exit 1 at the end, so the failure alert fires and a backup still exists: before the dump, the database size against `BACKUP_MAX_DATABASE_BYTES` (400000000 for Supabase free, 80 percent of its 500 MB limit); after the upload, the object size against `BACKUP_MAX_DUMP_BYTES` (200000000).
- On the first day of each month (UTC) the job also copies that night's object to `monthly/` with a server-side copy; the bytes never pass through the VPS.
- Space bound: about 14 to 16 daily plus 3 to 4 monthly objects. At the 200 MB cap the bucket stays under 4 GB, inside the R2 free 10 GB.
- The job's memory limit covers rclone's upload buffers. If the pod is killed for memory, lower `RCLONE_S3_UPLOAD_CONCURRENCY` or `RCLONE_S3_CHUNK_SIZE` in `postgres-backup-config` before raising the limit.
- Alerts (deploy repo): the job failed, or no new `daily/` object in 26 hours. The cms-admin Backups page also shows a stale warning after 26 hours.

### Restore drill

A backup that was never restored is not a backup. Run this at setup and then every quarter, into a **scratch** database on a throwaway server of the same major version, never over production. For Supabase use a local `postgres:17` container; the drill proves the dump, not the Supabase restore.

```
# 0. decrypt the dump with the offline private key
age -d -i abyss-backup.agekey abyss-<stamp>.dump.age > abyss-<stamp>.dump
# 1. on the scratch server: run scripts/db/database-roles.sql (hosting=self_managed) once,
#    then, as the superuser, create the scratch database owned by the migrator
createdb -h <db-host> -U <superuser> -O abyss_migrator abyss_restore
# 2. restore as the migrator (stop at the first error); the dump's grants for abyss_api come with it
pg_restore -h <db-host> -U abyss_migrator -d abyss_restore --no-owner --exit-on-error abyss-<stamp>.dump
# 3. the schema is complete: the migration commands find nothing pending
#    (run the cms-api image with DB_NAME=abyss_restore and the migrator credentials)
npm run --silent deploy:migrate        # expect exit 0, "No pending ..." twice
# 4. spot-check data
psql -h <db-host> -U abyss_migrator -d abyss_restore -c 'select count(*) from accounts' \
     -c 'select count(*) from content._migrations'
# 5. drop it, and delete the decrypted dump
dropdb -h <db-host> -U <superuser> abyss_restore
rm abyss-<stamp>.dump
```

Record the date, the dump used and the time it took. The decrypted dump holds the whole database: delete it when the drill ends.

For a real disaster: run the roles script on the target server first (Supabase: steps S1 to S4 of `supabase-database.md`), restore into the new database, point `DB_HOST` and `DB_NAME` at it, roll out (the init container confirms the schema is current), then check `GET /api/v1/health/ready`.

### Backup download (cms-admin)

The owner can list and download the encrypted dumps from the Backups page in cms-admin. cms-api never runs `pg_dump` and never proxies the bytes: it lists the bucket and hands out a presigned URL that is valid for 60 seconds.

- Keys: all six `BACKUP_STORAGE_*` keys or none (section 6). `BACKUP_STORAGE_ENDPOINT`, `BACKUP_STORAGE_REGION`, `BACKUP_STORAGE_BUCKET` and `BACKUP_STORAGE_PREFIX` go in `cms-api-config`; `BACKUP_STORAGE_ACCESS_KEY_ID` and `BACKUP_STORAGE_SECRET_ACCESS_KEY` go in `cms-api-secrets`. With none set the page is off and the endpoints answer `404 BACKUPS_NOT_CONFIGURED`.
- The key pair is the read-only R2 token of the bucket steps (list and get, this bucket only). It is never the job's write token.
- Only the owner can use the page and every link needs the owner's password plus a 2FA code. Each issued link is audited (`backup.download_link_created`); the URL is never logged. The owner must have 2FA turned on.
- The file is ciphertext: decrypt it locally with `age -d -i <key file>`. The bucket needs no CORS rule (the browser navigates to the URL).

## 8. Single replica in v1

Run exactly one replica of cms-api, web and cms-admin. cms-api keeps the rate-limit store and the permission-version cache (`VersionCache`) in memory (`docs/modules/access-control.md`, "Swap point"); a second replica would split the rate-limit counters, and permission changes made on one replica reach the other only after the 5 s cache TTL. Before scaling out, replace `VersionCache` and the rate-limit store as described there, and revisit `TRUST_PROXY_HOPS`. PostgreSQL is a single instance too: a node loss means downtime until the pod is rescheduled or the dump is restored. The rolling update (section 3) briefly runs two cms-api pods; that is safe because migrations are lock-protected and the in-memory state is rebuilt per process.

## 9. Release checklist

1. The publish job pushed the three images and bumped `APP_IMAGE_TAG` in the overlays (`docs/ci-cd.md`, "Publish").
2. The cms-api pod shows `Init:0/1` then `Running`; `kubectl logs <pod> -c migrate` ends with "No pending ..." or the applied list.
3. `curl -fsS https://domain.com/api/v1/health/ready` returns `{"status":"ok"}`.
4. `https://domain.com/` and `https://admin.domain.com/` load, and the browser console shows no CSP violations.
5. Sign in as the owner; the Traefik access log shows real client IPs, not node IPs (section 2).
6. The last nightly dump exists off-site, and the last restore drill is younger than three months.
