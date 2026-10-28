# cms-api

The CMS backend: a Node server with Prisma on Postgres, serving REST under `/api/v1` and GraphQL.
The cms-admin SPA calls it from the browser, and web calls it from its server.

- **Base:** `apps/cms-api/`
- **Flux Kustomization:** `cms-api-sync` in the environment's namespace (`cluster-base/cms-api-sync.yaml`,
  image tag in `cluster/me/<env>/cms-api-sync-overlay.yaml`)
- **ConfigMaps:** `shared-configmap` (template `templates/shared-configmap.example.yaml`)
  and `api-configmap` (template `templates/api-configmap.example.yaml`), both in `<ns>`
- **Secrets:** `api-secrets` for the main container (template `templates/api-secrets.example.yaml`) and
  `api-init-secrets` for the init container only (template `templates/api-init-secrets.example.yaml`)

Names below use `<name>` for `<APP_SERVICE_NAME>-<APP_ENV>` and `<ns>` for
`<APP_NAMESPACE>-<APP_ENV>` (see [configuration.md](configuration.md)).

## Resources

| Kind | Name | File |
|---|---|---|
| Deployment | `<name>` | `apps/cms-api/deployment.yaml` |
| Service (ClusterIP) | `<name>` | `apps/cms-api/service.yaml` |
| Ingress | `<name>` | `apps/cms-api/ingress.yaml` |
| Middleware (Traefik) | `<name>-https-redirect` | `apps/cms-api/middleware.yaml` |

All four are in `apps/cms-api/kustomization.yaml`, the same layout as cms-admin and web.

## Networking

| | Value |
|---|---|
| Host | `api.<APP_DOMAIN>`, all paths; `<APP_DOMAIN>`, only `/api/v1` (browser calls from web, [ADR-0002](../adr/0002-api-route-on-web-domain.md)) |
| TLS | `<name>-tls`, one certificate for both hosts, issued by cert-manager from `APP_TLS_CLUSTER_ISSUER` |
| HTTP | permanently redirected to HTTPS by the Middleware |
| Port | `APP_PORT` (1024 or higher) for the container (named `http`), the Service and `PORT` in the app |
| In-cluster URL | `http://<name>.<ns>.svc.cluster.local:<APP_PORT>` |

The container command is `sh -c "PORT=${APP_PORT} exec node dist/main.js"`. Setting `PORT` there
overrides any `PORT` in `api-secrets`, so the app and the Service always use the same port. The
command must stay in sync with the `CMD` in the app repository's Dockerfile.

## Startup and probes

1. **Init container `init`** (the same image and tag as the app) runs `npm run --silent deploy:migrate`
   against the database in `api-init-secrets`. If migrations fail, the app container never starts.
2. **Container `app`** (`<APP_IMAGE_REPO>:<APP_IMAGE_TAG>`) starts the server.

| Probe | Check | Initial delay | Period |
|---|---|---|---|
| Readiness | `GET /api/v1/health/ready` on `http` | 5s | 10s |
| Liveness | `GET /api/v1/health/live` on `http` | 15s | 20s |

Both endpoints are served under the `/api/v1` prefix. The probes use the port name `http`, never a number.

- `/api/v1/health/live` only checks that the process answers, with no dependency checks, so a database
  outage never gets cms-api restarted.
- `/api/v1/health/ready` also checks the database, so while the database is down the pod is taken out of
  the Service until it recovers.

## Resources (CPU / memory)

| Container | Requests | Limits |
|---|---|---|
| `init` | 50m / 128Mi | 500m / 512Mi |
| `app` | 100m / 128Mi | 500m / 512Mi |

## Configuration

**ConfigMaps (for Flux):** the shared one holds `APP_NAME`, `APP_NAMESPACE`, `APP_ENV`, `APP_DOMAIN`
and `APP_TLS_CLUSTER_ISSUER`. cms-api's own holds `APP_SERVICE_NAME`, `APP_IMAGE_REPO` and `APP_PORT`.
`APP_IMAGE_TAG` is in the sync file.

**Secret `api-secrets` (for the app container, via `envFrom`; the init container reads `api-init-secrets` instead):**

| Group | Keys | Required |
|---|---|---|
| Database login | `DB_USERNAME`, `DB_PASSWORD` | yes |
| Database connection | `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_SSL_MODE`, `DB_SSL_ROOT_CERT_PATH` | yes |
| Tokens and keys | `JWT_ACCESS_SECRET`, `OTP_PEPPER`, `TOTP_ENC_KEY`, `JWT_ACCESS_KID`, `TOTP_ENC_KID`, `TOTP_ISSUER` | yes |
| Key rotation | `TOTP_ENC_PREVIOUS_KEY`, `TOTP_ENC_PREVIOUS_KID` | |
| First install | `OWNER_SETUP_TOKEN` (remove after the owner exists) | |
| Runtime | `NODE_ENV`, `TRUST_PROXY_HOPS`, `CLIENT_IP_HEADER` (behind Cloudflare only) | `NODE_ENV`, `TRUST_PROXY_HOPS` |
| Origins | `ADMIN_ORIGIN` (the only CORS origin), `WEB_ORIGIN` | yes |
| Mail | `MAIL_PROVIDER`, `MAIL_FROM`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURE`, `SMTP_USER`, `SMTP_PASSWORD` (the two `SMTP_USER`/`SMTP_PASSWORD` go together) | yes |
| Media | `MEDIA_PROVIDER`, `CLOUDINARY_CLOUD_NAME`, `CLOUDINARY_API_KEY`, `CLOUDINARY_API_SECRET`, `CLOUDINARY_FOLDER` | yes |
| Reviewer | `TURNSTILE_SECRET_KEY`, `TURNSTILE_EXPECTED_HOSTNAME`, `REVIEWER_FEATURE_ENABLED` (`true` or `false`; off when unset) | |
| Backup download | `BACKUP_STORAGE_ENDPOINT`, `BACKUP_STORAGE_REGION`, `BACKUP_STORAGE_BUCKET`, `BACKUP_STORAGE_PREFIX`, `BACKUP_STORAGE_ACCESS_KEY_ID`, `BACKUP_STORAGE_SECRET_ACCESS_KEY` (all six or none; none turns the Backups page off) | |

Leave optional keys out rather than setting them to `""`. An empty value counts as set, and some
keys fail validation so the app won't boot. Don't set `PORT`. The full list is in
`apps/cms-api/.env.example` in the app repository.

## Security

- `automountServiceAccountToken: false`: the app never calls the Kubernetes API.
- Pod `seccompProfile: RuntimeDefault` and `runAsNonRoot: true` (the image runs as a numeric
  non-root user, checked by the app repository CI).
- Both containers: `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`.
- The CA file is mounted read-only at `/etc/project-me/database-ca` in both containers.
  `DB_SSL_ROOT_CERT_PATH` in `api-secrets` and in `api-init-secrets` must point to `ca.crt` in that
  directory (the `mountPath` in `apps/cms-api/deployment.yaml`).

## Dependencies

- **Postgres** outside the cluster, reachable from the pod at `DB_HOST:DB_PORT`.
- **Traefik** (k3s bundled) and **cert-manager** with the ClusterIssuer named in the shared ConfigMap.
- **The namespace and Secrets** must exist before the first reconcile.
- **Images:** one image and one tag serve both containers; the app repository pushes only `<tag>`.

## Known limits

- One replica, so each rollout has a short gap while the new pod runs migrations and becomes ready.
  Two replicas would both run `deploy:migrate` at start ([AUDIT.md](../AUDIT.md), finding 15).
- Migrations run on every pod start, not once per release. Prisma skips migrations that were already
  applied, so a restart is safe, but a slow database delays each start.
- Rolling back the image doesn't roll back the database. A release whose migration isn't
  backward-compatible can't be undone by reverting the tag.
