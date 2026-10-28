# ADR-0001: web listen port follows the image default (8080)

Status: Accepted
Date: 2026-10-28
Deciders: manager (delegated by the owner), planner

## Context

The web container port had two values in this repo:

- `deployment/k3s-traefik.md` (image table, lines 11-13, and section 4) and
  `deployment/devops-runbook.md` (lines 97-99) give the web image port as 8080: the image CMD copies
  `WEB_PORT` (default 8080) into `PORT`.
- An older `apps/web` comment and `docs/components/web.md` said the image sets `PORT=3000`. The
  same claim is still in `docs/AUDIT.md` findings E5 and E9 (from the frontend era).

Since commit 7119bbe the web Deployment no longer depends on the image's port. It runs
`sh -c "PORT=${APP_PORT} exec node apps/web/server.js"`, and `containerPort`, the Service `port`, the
probes and the Ingress backend all follow `APP_PORT` (probes, `targetPort` and the Ingress use the
port name `http`). So any value of 1024 or higher works. What is still open is the **value the
owner puts into `web-configmap` on each cluster**, and the number the docs recommend.

Evidence checked (read-only):

| Source | web port | Kind |
|---|---|---|
| `deployment/k3s-traefik.md` image table and section 4 | 8080 | reference doc from the app team, matches the image CMD (`WEB_PORT`) |
| `deployment/devops-runbook.md` image table and routing | 8080 | reference doc from the app team |
| Apps team feedback (`deploy-config-update` plan, sections 2 and 6) | 8080 | confirmed by the app team |
| `apps/web/deployment.yaml` before 7119bbe, `docs/components/web.md` before 923fc6a | 3000 | old frontend image (Next.js default), now removed |
| `docs/AUDIT.md` E5, E9 | 3000 | historical audit text about `frontend` |

The 3000 value comes from the old frontend image, where Next.js listened on its default port. The
current image and both reference docs say 8080.

## Decision

The recommended web listen port is the **image default, 8080**. The owner sets `APP_PORT` in
`web-configmap` to that value on staging and prod. Committed files keep the placeholder `<port>`
and point to the image table in `deployment/k3s-traefik.md`; that table stays the one place where
the number is written.

## Options considered

### A. 8080, the image default (chosen)

- Pro: matches the image CMD, both reference docs and the app team's feedback; no doc changes.
- Pro: if the `command` override ever drifts from the image CMD (the Deployment comment warns
  about this), the image still listens on 8080, so the probes and the Service keep working.
- Pro: one number per image in one table (cms-api 3000, web 8080, cms-admin 8080).
- Con: a cluster that still has the old value in `web-configmap` needs a re-apply and a reconcile.
  The change is safe: Service, probes and Ingress all follow `APP_PORT` by name.

### B. 3000, the old value

- Pro: no change on a cluster that already has it.
- Con: contradicts the image and the reference docs; the k3s-traefik.md table would have to be
  marked as "not used here", or the docs disagree again.
- Con: works only while the `command` override is in place. If it is dropped or the image CMD
  changes, the pod listens on 8080 while Kubernetes probes 3000, and the pod never becomes ready.

## Consequences

- Owner action (not an agent task, done with user action 2 of the deploy-config update): in
  `web-configmap` on each cluster, set `APP_PORT` in the filled copy to the image port from the
  table, re-apply with `kubectl apply --server-side`, and reconcile `web-sync`. Check that the web
  pod is ready and `https://<domain>/` answers.
- `docs/AUDIT.md` E5 and E9 get a one-line note that they describe the old frontend image and are
  superseded by this ADR (task WP-T1). The finding text itself stays as it was.
- No manifest, template or ConfigMap key changes. `WEB_PORT` stays unset in `web-secrets`.

## Module ownership, names, extension

- Owner of the listen port: the per-app ConfigMap key `APP_PORT`. The Deployment (`command`,
  `containerPort`) and the Service read it; probes and the Ingress use the port name `http`.
- Owner of the recommended number: the image table in `deployment/k3s-traefik.md`. Other docs link
  to it and never repeat the number.
- Next similar case (a new app image, or a new image port): add or change one row in the image
  table, and the owner sets that app's `APP_PORT`. No manifest changes. cms-admin joins this model
  once its image supports `ADMIN_PORT` (follow-up, not scheduled).
