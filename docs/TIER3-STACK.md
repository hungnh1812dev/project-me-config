# Tier 3 stack: a production-like cluster in Docker

This stack runs k3s (with its bundled Traefik), cert-manager, Flux, Postgres and the three apps (cms-api, web, cms-admin) inside Docker, from a git commit that is not pushed yet. It exists to check, before staging, what static review cannot show: route priority, certificates, redirects, CORS, cookie flags and Flux sync.

Design and reasons: [ADR-0003](adr/0003-tier3-docker-stack.md).

## What it needs

- The Docker CLI and a running Docker engine. Nothing else is installed on the host (no kubectl, flux, kind or k3d). No Docker Compose.
- About 4 GB of memory for Docker. `up` takes minutes.
- A shell that runs `tier3-stack/stack.sh` (POSIX `sh`, already on macOS and Linux).
- An arm64 or amd64 workstation; every image must have a build for it.
- `.localEnv.agent` in the repo root (git-ignored, never committed) with the key names listed in `tier3-stack/.env.example`: the three `TIER3_*_IMAGE_REPO` keys (staging image repositories), optional `TIER3_*_IMAGE_TAG` overrides, and optional pull credentials (`TIER3_REGISTRY_SERVER`, `TIER3_REGISTRY_USERNAME`, `TIER3_REGISTRY_TOKEN`). Use throwaway values only; never put a real token there, because the tools container must read the file.

No step of the stack reads any `.env*` file other than `tier3-stack/.env.example`. All ports stay inside Docker: nothing is published to the host and the Docker socket is never mounted.

## Commands

All commands run from any directory as `tier3-stack/stack.sh <command>`.

| Command | What it does |
|---|---|
| `stack.sh up` | Builds the tools image, starts the k3s container, then installs the in-cluster registry, cert-manager, the local CA, Flux and Postgres, seeds the Secrets and ConfigMaps, syncs `HEAD` and waits until every `*-sync` Kustomization is Ready. Refuses to start when a tier 3 container already exists |
| `stack.sh sync [<commit>]` | Loads a commit (default `HEAD`) into the running cluster and waits for the syncs. This is kept mode: leave the cluster running and sync again after each new commit |
| `stack.sh check` | Runs the runtime checks and prints one `PASS` or `FAIL` line per item. Exits non-zero when any item fails |
| `stack.sh status` | Prints the Flux sources and Kustomizations, the `commit:` line, and the pods |
| `stack.sh curl [curl args] <url>` | Runs curl inside the tools container with the local CA and the host resolution set up, so the request reaches Traefik with the real Host header and SNI |
| `stack.sh down` | Removes every container and volume labelled `project-me.tier3=true`, and nothing else |

Typical run: `stack.sh up`, `stack.sh check`, `stack.sh down`. Typical kept run: `stack.sh up` once, then `stack.sh sync` and `stack.sh check` per commit, `stack.sh down` at the end.

URLs (reachable only through `stack.sh curl`):

- `https://project-me.localhost` (web, and cms-api under `/api/v1`)
- `https://api.project-me.localhost` (cms-api)
- `https://admin.project-me.localhost` (cms-admin)

Example: `tier3-stack/stack.sh curl -sS -o /dev/null -w '%{http_code}\n' https://project-me.localhost/`.

"The app is up" means `stack.sh status` shows every `*-sync` Ready and every pod 1/1.

## What gets tested: a commit, not the working tree

`sync` builds an artifact with `git archive <commit>`: tracked files only, so untracked files, filled-in templates and git-ignored files never reach the cluster. It fails when the file list holds a `.env*` path other than `.env.example`, a symlink, or a submodule. The artifact is pushed to the in-cluster registry and Flux is pointed at it by digest, not by tag. `stack.sh status` prints `commit: <sha>` (the commit inside the artifact); Flux itself shows the artifact digest as the revision.

The tier 3 Flux root is `cluster/tier3/`. It re-uses `cluster-base/` unchanged and only switches the `sourceRef` of every `*-sync` Kustomization to the OCI artifact, so it applies the same manifests as staging.

Secrets and ConfigMaps are made by `tier3-stack/seed.sh` from `templates/*.example.yaml`, with values from `tier3-stack/values.yaml` (throwaway local values; a stated exception to "placeholders only"). The seed fails, naming object and key, when a template key has no value or `values.yaml` has an extra key.

## What each check item covers

| Item | Covers | Closes |
|---|---|---|
| `web-https` | web answers 200 over https | SEC-DC-T5-1 |
| `admin-https` | cms-admin answers 200 over https | SEC-DC-T5-1 |
| `api-health` | cms-api health on the api host answers 200 | SEC-DC-T5-1 |
| `api-bare-route` | `/api/v1` health on the bare domain is answered by cms-api, like on the api host (route priority) | SEC-AF-T1-1, CAF-9 |
| `http-redirect` | http redirects (301 or 308) to https on the same host, for all three hosts | SEC-AF-T1-1, SEC-DC-T5-1 |
| `tls-san` | the api host certificate lists both names, and every host certificate verifies against `tier3-ca` | SEC-AF-T1-1, CAF-9 |
| `cors-post` | a same-origin POST to the reviewer sessions path is not rejected by CORS | SEC-AF-T1-1, CAF-9 |
| `cookie-flags` | a cms-api `Set-Cookie` on the bare domain is Secure, HttpOnly, has no wider Domain and a Path under `/api/v1`; FAIL when no cookie is seen | SEC-AF-T1-1 |
| `ingress-hosts` | the Ingress hosts and paths are exactly the expected set | SEC-DC-T5-1, SEC-AF-T1-1 |
| `syncs-pods` | the three app syncs are Ready and every pod is fully ready | SEC-DC-T5-1 |

The checks print raw results; checkers still read the output. A `FAIL` prints indented detail under its line.

## Reading a failure

- Items that need an app pod (`web-https`, `admin-https`, `api-health`, `api-bare-route`, `cors-post`, `cookie-flags`, `syncs-pods`) stay red until the three `TIER3_*_IMAGE_REPO` keys point at real staging images and, for a private registry, a pull token exists. A pod in `ImagePullBackOff` is an environment input, not a stack bug.
- The external providers (SMTP, Cloudinary, Turnstile, backup storage) hold placeholder-shaped values. If cms-api fails at boot on one of them, that is an app team input (open question APP-2), not a stack bug.
- Mode A database login (`deployment/devops-runbook.md` section 4.6) is used, and the init script creates only the role named in `api-init-secrets`. A cms-api migration failure about missing roles, grants or extensions is an app team input (open question APP-1), not a stack bug.
- `cookie-flags` fails when no `Set-Cookie` is seen. Trigger one (for example the sessions POST) before reading it as a flag problem.
- Routing, certificate, redirect and Ingress failures (`http-redirect`, `tls-san`, `ingress-hosts`) are manifest findings and count against the commit under test.

## What it does not cover

- ACME issuance and HTTP-01 (no public DNS; the local CA signs instead).
- Public DNS and the real client path to the VPS.
- The real Supabase database (an in-cluster Postgres with TLS from the same CA stands in, so the `verify-full` mount path is exercised).
- The hand-made Secrets and ConfigMaps on each real cluster.
- Staging's inline `APP_IMAGE_TAG` substitute: tier 3 supplies the tag through the app ConfigMap instead.
- External providers (placeholders only) and multi-node behaviour.

These stay with the staging and prod entries.

## Extension path

- A new app under `apps/<svc>/` needs only its entries in `tier3-stack/values.yaml`; the Flux root patch matches every `*-sync` and the seed walks `templates/*.example.yaml`. The seed names every missing key.
- A new runtime check is one more row in the check table of `tier3-stack/cluster.sh` and its function.
- A new in-cluster command is one function in `cluster.sh` and one name in the pass-through list of `stack.sh`.

## Files

| Path | Holds |
|---|---|
| `tier3-stack/stack.sh` | host entry point, Docker CLI only |
| `tier3-stack/Dockerfile` | tools image (pinned kubectl and flux) |
| `tier3-stack/cluster.sh` | in-cluster commands: up, sync, status, check, curl |
| `tier3-stack/seed.sh` | renders and applies Secrets and ConfigMaps |
| `tier3-stack/values.yaml` | tier 3 values per object and key |
| `tier3-stack/registry.yaml` | in-cluster artifact registry |
| `tier3-stack/.env.example` | names of the `.localEnv.agent` keys |
| `cluster/tier3/` | Flux root, local CA issuer, Postgres |
