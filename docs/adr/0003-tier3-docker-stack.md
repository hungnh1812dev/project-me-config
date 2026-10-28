# ADR-0003: tier 3 stack: k3s in Docker, driven by the Docker CLI (no Compose)

Status: Accepted, revision 2 (owner, 2026-10-28: engine option D), built in tasks TS-T1 .. TS-T6; usage
in `docs/TIER3-STACK.md`. Answers 2-10 of revision 1 are accepted and folded in below. Revision 1 (k3s under Docker Compose, option C) was rejected by the owner:
Docker Compose is not used in this deploy repo. Planning notes of 2026-10-28 are folded into §2-§4
(where the CA is applied, mode A database login); the version numbers are still to be supplied.
Date: 2026-10-28
Deciders: planner (task SG-T1, DESIGN and REPLAN), to be accepted by the owner

## Context

This repo has no runtime check before staging. Phase checks fall back to tier 1 (static review), and
the runtime items stay open until the owner checks them on staging (project.md "Tier 3 fallback").
Three items are open now and are the first things the stack must run:

| Item | What it needs at runtime |
|---|---|
| SEC-AF-T1-1, CAF-9 | Traefik sends `<domain>/api/v1` to cms-api and `<domain>/` to web (route priority); the cms-api certificate lists `api.<domain>` and `<domain>`; `http://<domain>/api/v1/...` redirects to https; `/api/v1/health/ready` on the bare domain is answered by cms-api; a same-origin POST to `/api/v1/reviewer/sessions` is not rejected by CORS; any cms-api `Set-Cookie` on `<domain>` is Secure, HttpOnly and scoped |
| SEC-DC-T5-1 | both Ingresses serve TLS, http redirects to https, the Ingress hosts are right, and `cms-api-sync` and `web-sync` are Ready with their pods 1/1 |

The production-like target is what the clusters run (`docs/DEPLOYMENT.md` §2-§10): k3s with its
bundled Traefik (class `traefik`, `traefik.io/v1alpha1` Middleware), cert-manager with a
ClusterIssuer, Flux v2.9.5 with source-controller and kustomize-controller
(`cluster/me/staging/project-me-staging/gotk-components.yaml`), one Flux instance per namespace,
`postBuild.substituteFrom` reading `shared-configmap` and the per-app ConfigMap, and hand-made
Secrets and ConfigMaps from `templates/*.example.yaml`.

Constraints (user rules, conventions.md, owner answers):

- Everything runs inside Docker. Nothing is installed on the host (no kind, k3d, kubectl or flux binary).
  The only host tool used is the Docker CLI that is already there.
- No Docker Compose (owner, answer 1 of revision 1).
- No step reads a `.env*` file except `.env.example`. Throwaway local values go in `.localEnv.agent`
  (test-tiers), which is git-ignored and never printed.
- Public repo: committed files hold no real values. `tier3-stack/values.yaml` is the one stated
  exception (answer 10, see §5).
- The workstation is arm64 (Apple Silicon), so every image the stack runs must have an arm64 build.

## Decision

### 1. Engine: k3s server container and a tools container, started by one host script (option D)

`tier3-stack/stack.sh` runs on the host and calls only `docker`. It never runs `kubectl`, `flux` or
`git` on the host, and it reads no file other than the ones it passes to `docker build`. It starts two
containers:

- `project-me-tier3-k3s`: the official `rancher/k3s` server image, `docker run -d --privileged`
  (as k3s needs), single node, with its bundled Traefik and servicelb. This is the same distribution
  as the clusters and the image k3d runs under the hood. The k3s version matches the clusters
  (answer 2). k3s writes its kubeconfig into a named volume (`K3S_KUBECONFIG_OUTPUT`), and its data
  lives in a second named volume, so a kept cluster survives between tools runs.
- `project-me-tier3-tools`: a short-lived `docker run --rm` of the image built from
  `tier3-stack/Dockerfile`, with pinned `kubectl`, `flux` (same version as the clusters), `curl`,
  `openssl`, `git`, `jq`. It runs with `--network container:project-me-tier3-k3s`, so it shares the
  k3s network namespace: `127.0.0.1:6443` is the Kubernetes API and `127.0.0.1:80/443` is Traefik.
  It mounts the repo read-only and the kubeconfig volume read-only, and runs
  `tier3-stack/cluster.sh <command>`, which does all the cluster work.

Every container and volume carries the label `project-me.tier3=true`. `stack.sh down` removes
exactly the containers and volumes with that label (`docker rm -f`, `docker volume rm`), so the
stop needs no state file and cannot touch other Docker objects. `stack.sh up` refuses to start when a
container with the label already exists and names `sync` or `down` instead.

No port is published to the host (answer 8), no Docker network is created (the tools container joins
the k3s container's namespace), and the Docker socket is never mounted into any container. Because the
tools container lives in the node's network namespace, it also reaches every Service ClusterIP
(kube-proxy rules apply there). The stack relies on ClusterIPs, not on NodePorts or hostPorts on
`127.0.0.1`, because loopback access to those depends on kube-proxy and CNI settings that differ by
k3s version. The repo mount is marked `safe.directory` in the tools image so `git` accepts it.

Split of work: `stack.sh` owns the Docker lifecycle (build the tools image, start, stop, run a tools
command); `cluster.sh` owns everything inside the cluster (install, seed, sync, check, curl).
Neither does the other's job, so a change to the checks never touches the Docker commands.

### 2. How the repo reaches Flux: an OCI artifact from a git commit (answer 7)

The clusters pull a GitRepository from GitHub. The tier 3 stack tests commits that are not
pushed yet (pushing waits for user actions), so it uses an artifact instead:

1. `cluster.sh up` applies `tier3-stack/registry.yaml`, a plain `registry` Deployment with a
   ClusterIP Service, inside the cluster (not managed by Flux, so it exists before Flux has a source).
2. `cluster.sh sync [<commit>]` (default `HEAD`) builds the artifact from
   `git archive <commit>`: tracked files only, so untracked state files, filled-in templates and every
   git-ignored `.env*` file are never in it. The script fails if the file list has any `.env*` path
   other than `.env.example`. It pushes with `flux push artifact` to the in-cluster registry at its
   Service ClusterIP (read with `kubectl`) and points one `OCIRepository` (`insecure: true`, the
   Service's in-cluster DNS name) at the pushed artifact's `sha256` digest (`spec.ref.digest`), not at a
   tag, so a replaced tag is never applied. Flux therefore shows the digest as the revision; the commit
   sha is in the artifact metadata and is printed as the `commit:` line of `stack.sh status`.
3. A root Flux Kustomization named `project-me-tier3` applies `./cluster/tier3`.

`cluster/tier3/kustomization.yaml` is the tier 3 counterpart of `cluster/me/staging/kustomization.yaml`:
namespace `project-me-tier3`, resources `../../cluster-base` plus `postgres.yaml`, and one
patch that sets `sourceRef` of every `.*-sync` Kustomization to `kind: OCIRepository`,
`name: project-me-tier3`. Nothing in `cluster-base/`, `apps/` or `cluster/me/` changes, so the tier 3
stack applies exactly the manifests staging applies.

Flux itself is installed by `flux install --namespace=project-me-tier3
--components=source-controller,kustomize-controller` with the pinned CLI, the same components and
version as `gotk-components.yaml`.

### 3. TLS: a local CA through cert-manager

`cluster/tier3/ca-issuer.yaml` holds a self-signed ClusterIssuer, a CA Certificate, and a CA
ClusterIssuer `tier3-ca`. `APP_TLS_CLUSTER_ISSUER` is `tier3-ca`, so every Ingress gets a real
cert-manager certificate with the same SAN list as on staging. `cluster.sh up` applies this file
itself, after cert-manager and before the seed, not through the Flux root: the seed needs the CA for
`database-ca-configmap` before the first sync, and the root's namespace transform would move the CA
Certificate out of the `cert-manager` namespace, where a ClusterIssuer's CA Secret must live.
The tools image trusts this CA at
check time (`curl --cacert`, read from the cluster). ACME and HTTP-01 are not exercised (no public DNS).
cert-manager is installed from its pinned release manifest (answer 2).

### 4. Database: in-cluster Postgres with TLS from the same CA (answer 4)

cms-api's readiness checks the database, and its init container runs migrations with
`DB_SSL_MODE=verify-full`. `cluster/tier3/postgres.yaml` runs one Postgres pod and Service in
`project-me-tier3`, with a server certificate from `tier3-ca`. `database-ca-configmap` gets that CA's
`ca.crt`, so the real mount path and `DB_SSL_ROOT_CERT_PATH` rule are exercised end to end. Until the
app team answers open question 3, tier 3 uses mode A (`deployment/devops-runbook.md` §4.6): the image
creates the one role, password and database from `api-init-secrets`, and `api-secrets` uses the same
login. The init script for further roles, grants and extensions is added to the same file once the
app team answers.

### 5. Secrets and ConfigMaps: rendered from the templates, never from `.env*`

`tier3-stack/seed.sh` (run inside the tools container by `cluster.sh up` and `cluster.sh sync`)
builds every object from `templates/*.example.yaml`:

- The object name, namespace and **key set** come from the template. The value of each key comes from
  `tier3-stack/values.yaml`, keyed by object name, then key. The values are throwaway local values only
  (answer 10: `APP_NAMESPACE=project-me`, `APP_ENV=tier3`, domain `project-me.localhost`, issuer
  `tier3-ca`, `REVIEWER_FEATURE_ENABLED=true`, ports per the image table in
  `deployment/k3s-traefik.md`, the in-cluster Postgres host). They are not real and are fine in a
  public repo; this file is the stated exception to "placeholders only", which stays in force for
  `templates/`, `docs/` and `README.md`.
- External providers (SMTP, Cloudinary, Turnstile, backup storage) get placeholder-shaped values until
  the app team says which ones cms-api needs at boot (answer 5).
- A value written as `generate: <name>` is a random value made at seed time with `openssl rand`.
  The same `<name>` gives the same value in every object (for example the database password in
  `api-secrets`, `api-init-secrets` and Postgres). Generated values go straight into
  `kubectl apply --server-side -f -` and are never written to disk or printed.
- A value written as `local: <KEY>` comes from `.localEnv.agent` (answer 3: the staging image
  repositories, an optional pull token). `tier3-stack/.env.example` lists those key names only. The
  pull token is a throwaway value only, never a real token, because the tools user must read
  `.localEnv.agent`. The tools container reads `.localEnv.agent` from the read-only repo mount; the host script
  never reads it.
- `APP_IMAGE_TAG` defaults to the `APP_IMAGE_TAG:` line of the matching
  `cluster/me/staging/<svc>-sync-overlay.yaml` and is added as one extra key to that app's ConfigMap
  in the tier 3 cluster only (the tier 3 root has no inline `substitute`, so `substituteFrom` supplies
  it). The mapping app ConfigMap to overlay file is one entry per app in `values.yaml`. An optional
  `APP_IMAGE_TAG` per app in `.localEnv.agent` overrides it, because the staging tag can predate the
  manifests under test (answer 3).
- The seed fails, naming object and key, when a template key has no value or `values.yaml` has a key
  that is not in the template. So template drift shows up as a failed start, not as a pod that boots
  with a missing key.

### 6. Commands and what "URL" means here

Proposed `project.md` lines (the manager adds them after the owner accepts this ADR):

```
- full stack (tier 3): tier3-stack/stack.sh up      # build tools image, start k3s, cert-manager, Flux, seed, sync HEAD, wait until every *-sync is Ready
  then: tier3-stack/stack.sh check                  # runtime checks, one pass/fail line per item
  then: tier3-stack/stack.sh down                   # stop: every container and volume labelled project-me.tier3=true is removed
- kept mode: the same start without the stop; to load a new commit into the kept cluster:
  tier3-stack/stack.sh sync [<commit>]
- stop (kept mode): tier3-stack/stack.sh down
- URL: https://project-me.localhost (web), https://api.project-me.localhost (cms-api),
  https://admin.project-me.localhost (cms-admin), reachable only inside the tools container:
  tier3-stack/stack.sh curl [curl args] https://project-me.localhost/
  For a Flux repo, "the app is up" means: flux -n project-me-tier3 get kustomizations shows every *-sync Ready
  and every pod is 1/1 (tier3-stack/stack.sh status prints both).
```

Every `stack.sh` command other than `up` and `down` is one `docker run --rm` of the tools image with
`cluster.sh <command> [args]`; `stack.sh` adds no logic of its own to them. `up` is: build the tools
image, start the k3s container, wait for its kubeconfig, then `cluster.sh up`.

`cluster.sh curl` is plain curl plus two arguments: `--cacert` with the `tier3-ca` certificate read
from the cluster, and `--resolve <host>:80:<ip>` and `--resolve <host>:443:<ip>` for every tier 3 host,
where `<ip>` is the ClusterIP of the bundled Traefik Service (`kube-system/traefik`). So the request
carries the real Host header and SNI, reaches the same Traefik router as on the clusters, and needs no
DNS, hosts-file or published port anywhere. Any other curl argument is passed through unchanged.

`cluster.sh check` runs the items of SEC-AF-T1-1, CAF-9 and SEC-DC-T5-1 against the tier 3 domain (the
same list as the curl block in `docs/DEPLOYMENT.md` §18, plus the redirect, SAN, CORS-with-`Origin`
and `Set-Cookie` checks) and prints one line per item. The checkers still read the raw output; the
script only removes typing.

### 7. Target file map

| Path | Holds |
|---|---|
| `tier3-stack/stack.sh` | host entry point, Docker CLI only: `up`, `down`, and the pass-through of `sync`, `check`, `curl`, `status` to the tools container; container and volume names, the label, the run flags |
| `tier3-stack/Dockerfile` | the tools image with pinned versions |
| `tier3-stack/cluster.sh` | in-cluster entry point (tools container): `up` (registry, cert-manager, Flux, seed, first sync, wait), `sync`, `check`, `curl`, `status` |
| `tier3-stack/seed.sh` | renders and applies the Secrets and ConfigMaps (separate use case, called by `cluster.sh up` and `sync`) |
| `tier3-stack/values.yaml` | tier 3 values per object and key |
| `tier3-stack/registry.yaml` | the in-cluster artifact registry (Deployment and ClusterIP Service) |
| `tier3-stack/.env.example` | names of the `.localEnv.agent` keys, no values |
| `cluster/tier3/kustomization.yaml` | the tier 3 Flux root |
| `cluster/tier3/ca-issuer.yaml` | self-signed issuer, CA, `tier3-ca` ClusterIssuer |
| `cluster/tier3/postgres.yaml` | Postgres, its Service, its Certificate (the roles init script once the app team answers) |
| `docs/TIER3-STACK.md` | how to run it, what it does not cover |
| `.gitignore` | one line: `.localEnv.agent` |

Twelve paths, one owner each (revision 1's `compose.yaml` is gone; `cluster.sh` takes the in-cluster
half of the old `stack.sh`). The stack owns its folder; Flux roots stay under `cluster/`.
`cluster/tier3/` is outside the `cluster/me/*/` glob, so no tooling or doc that walks the real
environments picks it up. Scope (answer 6): `tier3-stack/`, `cluster/tier3/` and `.gitignore` go to
the core-builder scope, and `tier3-stack/` to the high-risk paths; the manager updates `project.md`.

## Options considered

### A. kind

- Pro: widely used, fast, good CI support.
- Con: not k3s. No bundled Traefik or servicelb, so Traefik must be installed and versioned separately,
  and the router priority being checked would come from a Traefik that differs from the clusters'.
- Con: the `kind` CLI has no official image; running it means a host binary (not allowed) or a
  home-made image with the Docker socket mounted.

### B. k3d (CLI in its container image, Docker socket mounted)

- Pro: k3s, same as the clusters; one CLI call creates and deletes the cluster; built-in registry and
  DNS wiring.
- Con: the CLI creates sibling containers through the host Docker socket. A mounted socket gives the
  container root on the Docker host.
- Con: one more tool and version to pin, for wiring this design does not need (the registry runs in
  the cluster, and the tools container shares the node's network).
- This is the fallback if the owner prefers a ready-made cluster CLI over a home-made host script
  (question 1).

### C. k3s server image under Docker Compose (revision 1, rejected)

- Rejected by the owner: Docker Compose is not used in this deploy repo.

### D. k3s server image started by a host script with plain `docker run` (chosen)

- Pro: the same k3s and bundled Traefik as the clusters; no Compose, no extra host tool, no Docker
  socket mount, no host port, no Docker network.
- Pro: the lifecycle is still declared in one place (`stack.sh`), and the label makes `down` exact.
- Con: `stack.sh` must do what Compose did for free: ordering (wait for the kubeconfig), the
  "already running" guard, and cleanup. That is about four Docker calls, kept in one function each.
- Con: single node only (the clusters are single node too, `docs/DEPLOYMENT.md` §2).
- Con: the k3s container is privileged, as with A, B and C.

### Source: GitRepository from GitHub instead of an OCI artifact

- Rejected: needs a push, and pushing waits for the cluster user actions. A git server container
  would keep `kind: GitRepository`, but Flux needs http(s) or ssh and one more image to pin; one
  `sourceRef` patch in the tier 3 root is smaller.

## Consequences

- The three open runtime items can be checked before staging. A tier 3 pass closes the parts tier 3
  shows (answer 9): route priority, SAN list, https redirect, readiness, CORS on same-origin POST,
  cookie flags. ACME issuance and HTTP-01, public DNS, the real Supabase database, and the hand-made
  objects on each cluster (user actions 1-3) move to new, smaller staging and prod entries.
- The stack is heavy: k3s, cert-manager, Flux, Postgres and three apps need about 4 GB of memory in
  Docker. `up` takes minutes, so qc keeps the stack in kept mode across one checkpoint.
- The tier 3 root re-uses `cluster-base/` unchanged; a manifest bug that only staging's overlay
  triggers (its inline `APP_IMAGE_TAG` substitute) is not covered.
- The k3s container is privileged. No port is published, and the API is reachable only from the tools
  container.
- The host needs a shell that runs `stack.sh` (POSIX `sh` or bash, already on macOS) and the Docker
  CLI. Nothing else is installed.

### Extension path

A new app under `apps/<svc>/` is added as today: `cluster-base/<svc>-sync.yaml`, its templates, and
`cluster/me/<env>/<svc>-sync-overlay.yaml`. The tier 3 root includes `../../cluster-base`, its
`sourceRef` patch matches every `.*-sync`, and the seed walks `templates/*.example.yaml`. So the only
tier 3 change is the new app's entries in `tier3-stack/values.yaml`; the seed names every missing
key. No stack command changes. A new runtime check is one more item in `cluster.sh check`; a new
in-cluster command is one function in `cluster.sh` and one pass-through name in `stack.sh`.

### Relation to task SG-T1

SG-T1 asks for "kind or k3d". This ADR picks the k3s image that k3d runs under the hood, started by
plain `docker run` without the k3d CLI or Compose, so the Docker socket is never mounted (question 1).
The other SG-T1 outputs are §2 and the Dockerfile (pinned versions, answer 2), §6 (start, kept mode,
stop, URL), §2 and §5 (Flux `${VAR}` substitution and placeholder objects without reading `.env*`),
§1 (Docker only, nothing on the host) and the extension path above. `project.md` is not changed by
this ADR.

### After acceptance

The owner accepted the engine (question 1). The build tasks are TS-T1 .. TS-T7 (planner, 2026-10-28),
with one checkpoint whose outputs are: `stack.sh up` reaches all
`*-sync` Ready on a clean clone, `stack.sh check` prints one line per item, `stack.sh down` leaves no
container or volume with the label `project-me.tier3=true`, `stack.sh up` refuses to start over a
kept cluster, and `stack.sh sync` refuses a commit whose file list holds a `.env*` path other than
`.env.example`.

## Owner answers to revision 1 (2026-10-28)

1. Engine (Compose, option C): rejected; re-designed as option D above.
2. Pinned versions: confirmed as listed: k3s = the version on the VPS (also fixes Traefik),
   cert-manager = the version on the clusters, Flux CLI v2.9.5, pinned Alpine base with the kubectl
   minor of the k3s version, the official `registry` image pinned, Postgres = the Supabase major.
3. App images: the staging repositories via `.localEnv.agent`, staging overlay tag by default,
   per-app `APP_IMAGE_TAG` override.
4. Database: in-cluster Postgres, TLS from the local CA, `verify-full`.
5. External providers: placeholders until the app team answers.
6. Scope and gates: yes to both.
7. What is tested: a commit (`HEAD` by default).
8. Host access: no host port; checks only from the tools container.
9. Closing the open entries: yes, split as in Consequences.
10. Tier 3 values: yes, committed in `tier3-stack/values.yaml` as a stated exception.

## Open questions

1. **Engine without Compose.** Answered 2026-10-28: yes, D. Plain `docker run` driven by a host script `tier3-stack/stack.sh`
   that calls only the Docker CLI (option D)? Recommended: yes, D. Trade-off: no Compose, no Docker
   socket mount and no extra tool, at the cost of about four Docker calls the script owns (start
   order, "already running" guard, labelled cleanup). The alternative is B (k3d image with the Docker
   socket mounted): less script, but the k3d container gets root on the Docker host.
2. **Exact version numbers.** Answer 2 confirms where each version comes from, but the k3s and
   cert-manager numbers must be read on the VPS (`k3s --version`; `kubectl -n cert-manager get deploy
   cert-manager -o jsonpath='{..image}'`), and the Postgres major from the Supabase project.
   Recommended: the owner supplies these three values before the first build task starts; the build
   task is `blocked` until then. Flux v2.9.5 is already known.
3. **Database roles (app team, from answer 4).** Which roles, grants and extensions do the migrations
   expect? Recommended: ask the app team together with question 5 of revision 1; until then the init
   script creates only the role named in `api-init-secrets`, and a migration failure in tier 3 is
   reported as an app team input, not a stack bug.
