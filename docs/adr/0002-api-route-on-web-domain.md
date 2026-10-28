# ADR-0002: route `/api/v1` on the bare domain to cms-api

Status: Accepted (owner, 2026-10-28, answer Q-AF2: `/api/v1`)
Date: 2026-10-28
Deciders: planner (routing decision delegated by the owner, apps team feedback round 2), accepted by the owner
Supersedes: the earlier rule "cms-api stays on `api.<domain>`; no Ingress change" (deploy-config
update, round 1)

## Context

The web bundle calls cms-api from the browser on its own origin, at `https://<domain>/api/v1`.
Today every path on `<domain>` goes to web (`apps/web/ingress.yaml`, path `/`), so these calls get
Next's 404: reviewer sessions, the account menu and the status card fail. Building web with
`https://api.<domain>/api/v1` instead is not possible: cms-api's CORS allows only the admin origin
(`ADMIN_ORIGIN`). cms-api serves its routes under `/api/v1` itself, so no path rewrite is needed.

Source: the apps team feedback (round 2, section 2, 2026-10-28).

## Decision

`apps/cms-api/ingress.yaml` gets a second rule for the bare domain with one path, `/api/v1`,
`pathType: Prefix`, to the cms-api Service on the port name `http`. The bare domain is added to the
same Ingress's `tls.hosts`. The `api.<domain>` rule stays unchanged (cms-admin uses it).

- The bare host uses the fail-closed form `${APP_DOMAIN:=APP_DOMAIN-is-not-set}` in both `tls` and
  `rules`, the same as `apps/web/ingress.yaml`. A plain `${APP_DOMAIN}` would substitute to
  nothing and drop the host, which turns the rule into a catch-all for `/api/v1` on every host.
- No `StripPrefix` or other path middleware: cms-api expects the `/api/v1` prefix.
- Traefik orders routers by rule length, so `Host(<domain>) && PathPrefix(/api/v1)` wins over web's
  `Host(<domain>) && PathPrefix(/)`. web's Ingress does not change.

## Options considered

### A. Rule in cms-api's Ingress, path `/api/v1` (chosen)

- Pro: the module that owns the cms-api Service owns every public route to it. web's Ingress
  never names another app's Service, and its substitution variables stay its own.
- Pro: only the versioned REST prefix that web uses moves; web keeps every other path, including
  any future Next route under `/api/...` outside `/api/v1`.
- Con: a new cms-api prefix that the browser must reach on `<domain>` (for example `/api/v2`)
  needs one more path entry in this rule.

### B. Same rule, path `/api` (the apps team's proposal)

- Pro: covers a future `/api/v2` without an edit.
- Con: takes every `/api...` path away from web. Traefik's `PathPrefix` is not split on `/`, so it
  also catches paths such as `/api-docs` on web. The spec needs only `/api/v1`.

### C. Path in web's Ingress pointing at the cms-api Service

- Con: web's Ingress would name cms-api's Service, but `${APP_SERVICE_NAME}` there is `web`, so it
  needs a new substitution key or a hard-coded name. Two modules would own routes to one Service.

### D. Build web with `https://api.<domain>/api/v1`

- Rejected by the source: cms-api's CORS allows only the admin origin.

## Consequences

- cert-manager reissues the cms-api certificate (`<svc>-<env>-tls`) with the bare domain as a
  second name. Until it is ready, Traefik can still serve web's certificate for `<domain>`, which
  is also valid.
- cms-api's public surface is the same set of routes, now on two hosts. Admin and auth routes
  under `/api/v1` are reachable on `<domain>` too; CORS, rate limits and `TRUST_PROXY_HOPS` are
  unchanged because the request path through Traefik is the same.
- Check after rollout: `curl -fsS https://<domain>/api/v1/health/ready` is answered by cms-api,
  and `curl -fsSI https://<domain>/` still by web (docs/DEPLOYMENT.md, section 18).
- `deployment/*.md` stay unedited (owner, Q-AF3). Their text that puts cms-api only on
  `api.<domain>` is superseded in this repo by this ADR and `docs/`.
- Open point for the apps team (not blocking): the web bundle makes no browser call to cms-api
  outside `/api/v1` (for example GraphQL). If it does, add that path to the same rule.

## Module ownership, names, extension

- Owner of public routes to cms-api: `apps/cms-api/ingress.yaml` (one Ingress, one rule per host).
- Owner of the bare domain's default route: `apps/web/ingress.yaml` (path `/`), unchanged.
- Next similar case (another cms-api prefix on the web origin, or another app behind a path on the
  bare domain): add one path entry to the owning app's own Ingress rule for the bare host, with the
  fail-closed host form. No other module changes.
- File map: `apps/cms-api/ingress.yaml` (manifest), `docs/components/cms-api.md`,
  `docs/components/web.md`, `docs/components/configuration.md`, `docs/DEPLOYMENT.md`, `README.md`
  (docs).
