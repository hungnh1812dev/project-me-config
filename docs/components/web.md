# web

The public website: a Next.js standalone server. It renders pages from cms-api
content, which it fetches from its server.

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
| Host | `<APP_DOMAIN>` (the bare domain), all paths except `/api/v1`, which cms-api's Ingress serves ([ADR-0002](../adr/0002-api-route-on-web-domain.md)) |
| TLS | `<name>-tls`, issued by cert-manager from `APP_TLS_CLUSTER_ISSUER` |
| HTTP | permanently redirected to HTTPS by the Middleware |
| Port | `APP_PORT` (1024 or higher) for the container (named `http`) and the Service |

The container command is `sh -c "PORT=${APP_PORT} exec node apps/web/server.js"`. The image CMD
copies `WEB_PORT` into `PORT`; setting `PORT` in the command makes `APP_PORT` the listen port. The
command must stay in sync with the image CMD. The recommended `APP_PORT` is the image's listen port
in the image table of [k3s-traefik.md](../../deployment/k3s-traefik.md). The Ingress host uses `${APP_DOMAIN:=APP_DOMAIN-is-not-set}`. A
bare `${APP_DOMAIN}` that was left empty would drop the host and match every request. The
placeholder isn't a valid hostname, so the apply fails instead.

## Probes

| Probe | Check | Initial delay | Period | Timeout |
|---|---|---|---|---|
| Readiness | `GET /` on `http` | — | 10s | 8s |
| Liveness | `GET /` on `http` | 10s | 20s | 1s (default) |

`/` renders the home page on the server, which fetches content from cms-api:

- The 8s readiness timeout covers a slow cms-api call during the render. A pod whose API is down
  may report not ready, and `kubectl rollout status` then waits on the API too.
- Liveness uses the same path with a 1s default timeout and a 20s period.

## Resources (CPU / memory)

Requests 100m / 192Mi, limits 500m / 512Mi.

## Configuration

**ConfigMaps (for Flux):** the shared one holds `APP_NAME`, `APP_NAMESPACE`, `APP_ENV`, `APP_DOMAIN`
and `APP_TLS_CLUSTER_ISSUER`. web's own holds `APP_SERVICE_NAME`, `APP_IMAGE_REPO` and
`APP_PORT`. `APP_IMAGE_TAG` is in the sync file.

**Set in the Deployment:**

| Env | Value | Why |
|---|---|---|
| `HOSTNAME` | `"0.0.0.0"` | Next binds to `$HOSTNAME`, and the runtime sets it to the pod name |

**Secret (via `envFrom`):**

| Key | Required | Notes |
|---|---|---|
| `API_INTERNAL_URL` | yes | cms-api base URL for server-side calls, never sent to the browser |
| `WEB_REVALIDATE_SECONDS` | yes | Seconds the data cache keeps server-side fetches (0 disables the cache) |
| `WEB_STATUS_PAGE_ENABLED` | no | `true` shows `/status`; unset or `false` answers 404 |

No other key is read. Don't set `PORT` or `WEB_PORT` in the Secret: the Deployment sets `PORT` from
`APP_PORT`. `API_INTERNAL_URL` uses the in-cluster Service, so requests don't go out through
Traefik and back:
`http://cms-api-<APP_ENV>.<APP_NAMESPACE>-<APP_ENV>.svc.cluster.local:<cms-api APP_PORT>/api/v1`.
If cms-api's `APP_PORT` changes, update `API_INTERNAL_URL` here too.

The browser calls cms-api on its own origin, at `/api/v1` (routed by cms-api's Ingress, see
[ADR-0002](../adr/0002-api-route-on-web-domain.md)). The base is a build variable of the image,
`NEXT_PUBLIC_API_BASE_URL`, set by the app team. Changing it needs a rebuild.

The same template serves staging and prod. After a trim, re-apply it with `--server-side` and check
that the Secret holds only these keys:
`kubectl -n <ns> get secret web-secrets -o json | jq -r '.data | keys[]'`. A Secret first made with a
plain `kubectl apply` or `create` keeps the dropped keys, and you remove them yourself.

## Security

- `automountServiceAccountToken: false`.
- Pod `seccompProfile: RuntimeDefault` and `runAsNonRoot: true`.
- Container: `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`.

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
   `curl -fsSI https://<domain>/` returns 200.
4. Only then delete the old objects yourself: ConfigMap `frontend-config`, Secrets
   `frontend-secrets` and `frontend-<env>-tls`.

Until `web-configmap` and `web-secrets` exist, `web-sync` cannot start web. The old pod is pruned
when the merge lands, so expect a short outage of the public site (accepted on staging).
