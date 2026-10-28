# cms-admin

The CMS admin UI: a static single-page app served by nginx. It runs entirely in the browser and
calls cms-api at `api.<domain>`.

- **Base:** `apps/cms-admin/`
- **Flux Kustomization:** `cms-admin-sync` in the environment's namespace (`cluster-base/cms-admin-sync.yaml`,
  image tag in `cluster/me/<env>/cms-admin-sync-overlay.yaml`)
- **ConfigMaps:** `shared-configmap` (template `templates/shared-configmap.example.yaml`)
  and `admin-configmap` (template `templates/admin-configmap.example.yaml`), both in `<ns>`
- **Secret:** `admin-secrets` (template `templates/admin-secrets.example.yaml`)

Names below use `<name>` for `<APP_SERVICE_NAME>-<APP_ENV>` (see
[configuration.md](configuration.md)).

## Resources

| Kind | Name | File |
|---|---|---|
| Deployment | `<name>` | `apps/cms-admin/deployment.yaml` |
| Service (ClusterIP) | `<name>` | `apps/cms-admin/service.yaml` |
| Ingress | `<name>` | `apps/cms-admin/ingress.yaml` |
| Middleware (Traefik) | `<name>-https-redirect` | `apps/cms-admin/middleware.yaml` |

## Networking

| | Value |
|---|---|
| Host | `admin.<APP_DOMAIN>`, all paths |
| TLS | `<name>-tls`, issued by cert-manager from `APP_TLS_CLUSTER_ISSUER` |
| HTTP | permanently redirected to HTTPS by the Middleware |
| Port | container `8080` (named `http`), Service `80` → `http` |

Port 8080 comes from the image (`nginx-unprivileged`), so it's fixed in the manifests instead of
being a variable until the image supports `ADMIN_PORT`.

## Probes

| Probe | Check | Initial delay | Period |
|---|---|---|---|
| Readiness | `GET /` on `http` | — | 10s |
| Liveness | `GET /` on `http` | 5s | 20s |

nginx serves `index.html` at `/`, with no upstream involved, so the probes don't depend on cms-api.

## Resources (CPU / memory)

Requests 10m / 32Mi, limits 200m / 128Mi.

## Configuration

**ConfigMaps (for Flux):** the shared one holds `APP_NAME`, `APP_NAMESPACE`, `APP_ENV`, `APP_DOMAIN`
and `APP_TLS_CLUSTER_ISSUER`. cms-admin's own holds `APP_SERVICE_NAME` and `APP_IMAGE_REPO` (no
`APP_PORT`: port 8080 is fixed until the image supports `ADMIN_PORT`). `APP_IMAGE_TAG` is in the sync file.

**Runtime:** nothing. The cms-api URL is built into the image (`VITE_API_BASE_URL`, set to
`https://api.<APP_DOMAIN>/api/v1` in the app repository's build). To point cms-admin at a different API,
rebuild the image. Changing the ConfigMap won't do it.

cms-api must list `https://admin.<APP_DOMAIN>` in its `CORS_ORIGINS`, or the browser blocks
every API call.

## Security

- `automountServiceAccountToken: false`.
- Pod `seccompProfile: RuntimeDefault` and `runAsNonRoot: true`.
- Container: `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, no capability added
  back. `nginx-unprivileged` (uid 101) listens on 8080 and needs none.

## Dependencies

- **cms-api** at `api.<APP_DOMAIN>`, for the browser, not for the pod. The pod starts and is Ready
  without it.
- **Traefik** and **cert-manager** with the ClusterIssuer named in the shared ConfigMap.
- **The namespace** must exist before the first reconcile.

## Known limits

- The sync file's `APP_IMAGE_TAG` is `dev` until the app repository commits a real tag. If the
  registry has no `dev` tag, the pod stays in `ImagePullBackOff` ([AUDIT.md](../AUDIT.md), finding 9).
- One replica, so a rollout or a node drain has a short gap.
