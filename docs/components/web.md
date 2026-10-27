# web

The public website: a Next.js standalone server with Auth.js. It renders pages from cms-api
content, which it fetches over GraphQL from its server.

- **Base:** `apps/web/`
- **Flux Kustomization:** `web-sync` in the environment's namespace (`cluster-base/web-sync.yaml`,
  image tag in `cluster/me/<env>/web-sync-overlay.yaml`)
- **ConfigMaps:** `shared-configmap` (template `templates/shared-configmap.example.yaml`)
  and `web-configmap` (template `templates/web-configmap.example.yaml`), both in `<ns>`
- **Secret:** `web-secrets` (template `templates/web-secrets.example.yaml`)

Names below use `<name>` for `<APP_SERVICE_NAME>-<APP_ENV>` (see
[configuration.md](configuration.md)).

## Resources

| Kind | Name | File |
|---|---|---|
| Deployment | `<name>` | `apps/web/deployment.yaml` |
| Service (ClusterIP) | `<name>` | `apps/web/service.yaml` |
| Ingress | `<name>` | `apps/web/ingress.yaml` |
| Middleware (Traefik) | `<name>-https-redirect` | `apps/web/middleware.yaml` |

## Networking

| | Value |
|---|---|
| Host | `<APP_DOMAIN>` (the bare domain), all paths |
| TLS | `<name>-tls`, issued by cert-manager from `APP_TLS_CLUSTER_ISSUER` |
| HTTP | permanently redirected to HTTPS by the Middleware |
| Port | `APP_PORT` (3000) for the container (named `http`) and the Service |

The image sets `PORT=3000` and Next listens there. `APP_PORT` only tells Kubernetes that port, so it
must equal the image's `PORT`. The Ingress host uses `${APP_DOMAIN:=APP_DOMAIN-is-not-set}`. A
bare `${APP_DOMAIN}` that was left empty would drop the host and match every request. The
placeholder isn't a valid hostname, so the apply fails instead.

## Probes

| Probe | Check | Initial delay | Period | Timeout |
|---|---|---|---|---|
| Readiness | `GET /api/health/ready` on `http` | — | 10s | 8s |
| Liveness | `GET /api/health/live` on `http` | 10s | 20s | 1s (default) |

These are chosen so that problems with cms-api don't take web down:

- `/api/health/ready` always returns 200 and reports cms-api's status in the body, so readiness
  only checks that the Next server answers.
- The route stops waiting for cms-api after 5s. The 8s probe timeout is longer, so a hanging cms-api
  doesn't mark the pod unready.
- `/api/health/live` never calls cms-api, so a slow cms-api never gets web restarted.

## Resources (CPU / memory)

Requests 100m / 192Mi, limits 500m / 512Mi.

## Configuration

**ConfigMaps (for Flux):** the shared one holds `APP_NAME`, `APP_NAMESPACE`, `APP_ENV`, `APP_DOMAIN`
and `APP_TLS_CLUSTER_ISSUER`. web's own holds `APP_SERVICE_NAME`, `APP_IMAGE_REPO` and
`APP_PORT`. `APP_IMAGE_TAG` is in the sync file.

**Set in the Deployment:**

| Env | Value | Why |
|---|---|---|
| `AUTH_TRUST_HOST` | `"true"` | Auth.js v5 behind a proxy (Traefik) has to trust the forwarded host |
| `HOSTNAME` | `"0.0.0.0"` | Next binds to `$HOSTNAME`, and the runtime sets it to the pod name |

**Secret (via `envFrom`):**

| Key | Required | Notes |
|---|---|---|
| `AUTH_SECRET` | yes | Auth.js session secret; the server throws without it |
| `CMS_API_URL` | yes | cms-api base for login/refresh/logout |
| `GRAPHQL_URL` | yes | `<cms-api-url>/graphql` |
| `REVALIDATE_SECRET` | yes | Shared with cms-api, which calls `/api/revalidate` to purge cached pages |
| `NEXT_ENV` | | `production` turns off dev-only request logging |
| `GRAPHQL_TOKEN`, `STRAPI_API_TOKEN` | | Optional bearer tokens for GraphQL |

Don't set `PORT` or `AUTH_TRUST_HOST` in the Secret. For the cms-api URLs, prefer the in-cluster
Service over the public host, so requests don't go out through Traefik and back:
`http://cms-api-<APP_ENV>.<APP_NAMESPACE>-<APP_ENV>.svc.cluster.local:<cms-api APP_PORT>`.

The public GraphQL URL used by the health check is built into the image (`FRONTEND_GRAPHQL_URL` in
the app repository), not set here. `FRONTEND_GRAPHQL_URL` (web build variable) is defined by the
app repository and keeps its name.

## Security

- `automountServiceAccountToken: false`.
- Pod `seccompProfile: RuntimeDefault`.
- Container: `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`.
- No `runAsNonRoot` yet, because the image's `USER` is set in the app repository
  ([AUDIT.md](../AUDIT.md), finding 4).

## Dependencies

- **cms-api**, for content and auth at request time. web still starts and stays Ready
  without it, but pages that need content fail. There's no Flux `dependsOn`
  ([AUDIT.md](../AUDIT.md), finding 12).
- **Traefik** and **cert-manager** with the ClusterIssuer named in the shared ConfigMap.
- **The namespace and Secret** must exist before the first reconcile.

## Known limits

- The sync file's `APP_IMAGE_TAG` is `dev` until the app repository commits a real tag
  ([AUDIT.md](../AUDIT.md), finding 9).
- One replica, so a rollout or a node drain has a short gap.
- Only the bare domain is served. `www.<domain>` needs its own DNS record and Ingress host.

## Cutover from frontend

web replaces the old `frontend` app. Its Flux Kustomization is `web-sync`, `APP_SERVICE_NAME` is
`web`, and its objects are `web-configmap` and `web-secrets`. Removing `frontend-sync` makes Flux
prune the old Deployment, Service, Ingress and Middleware. The hand-made objects stay until you
delete them, and no tool here deletes anything. Do these steps on staging first, then prod. The
steps for all apps are in [DEPLOYMENT.md](../DEPLOYMENT.md#moving-to-the-new-configmap-and-secret-names).

1. Copy the old ConfigMap and Secret to the new names, with `APP_SERVICE_NAME` set to `web`:

   ```bash
   kubectl -n <ns> get configmap frontend-config -o json \
     | jq '{apiVersion, kind, data, metadata: {name: "web-configmap", namespace: .metadata.namespace}} | .data.APP_SERVICE_NAME = "web"' \
     | kubectl apply --server-side -f -
   kubectl -n <ns> get secret frontend-secrets -o json \
     | jq '{apiVersion, kind, type, data, metadata: {name: "web-secrets", namespace: .metadata.namespace}}' \
     | kubectl apply --server-side -f -
   ```

2. Merge into the environment's branch. Check `cluster/me/<env>/web-sync-overlay.yaml` carries the
   tag the old `frontend-sync-overlay.yaml` had, and that no `frontend-sync-overlay.yaml` is left.
3. Check: `flux -n <ns> get kustomizations` shows `web-sync` Ready and no `frontend-sync`;
   `kubectl -n <ns> rollout status deploy/web-<env>`; the certificate `web-<env>-tls` is Ready;
   `curl -I https://<domain>/api/health/ready` returns 200.
4. Only then delete the old objects yourself: ConfigMap `frontend-config`, Secrets
   `frontend-secrets` and `frontend-<env>-tls`.

Until `web-configmap` and `web-secrets` exist, `web-sync` cannot start web. The old pod is pruned
when the merge lands, so expect a short outage of the public site (accepted on staging).
