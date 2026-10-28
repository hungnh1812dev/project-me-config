#!/bin/sh
# Tier 3 in-cluster entry point (ADR-0003). Runs in the tools container, started by stack.sh.
set -eu

FLUX_NAMESPACE="project-me-tier3"
FLUX_COMPONENTS="source-controller,kustomize-controller"
CERT_MANAGER_VERSION="v1.21.2"
CERT_MANAGER_MANIFEST_URL="https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
# Recorded from the v1.21.2 release asset (two downloads agreed); the owner confirms it against an independent source.
CERT_MANAGER_MANIFEST_SHA256="e03b668ec8675214af6b0a671699d088f2601fa3878e0dbe1b41d3feafd1879f"
CERT_MANAGER_MANIFEST_FILE="/tmp/cert-manager.yaml"
CERT_MANAGER_NAMESPACE="cert-manager"
CERT_MANAGER_DEPLOYMENTS="cert-manager cert-manager-cainjector cert-manager-webhook"
REGISTRY_DEPLOYMENT="tier3-registry"
CA_CLUSTER_ISSUER="tier3-ca"
STACK_DIR="/repo/tier3-stack"
REGISTRY_MANIFEST="$STACK_DIR/registry.yaml"
CA_ISSUER_MANIFEST="/repo/cluster/tier3/ca-issuer.yaml"
SEED_SCRIPT="$STACK_DIR/seed.sh"
REPO_DIR="/repo"
DEFAULT_COMMIT="HEAD"
SOURCE_NAME="project-me-tier3"
ROOT_KUSTOMIZATION_NAME="project-me-tier3"
ROOT_KUSTOMIZATION_PATH="./cluster/tier3"
REGISTRY_PORT=5000
REGISTRY_REPOSITORY="project-me-tier3"
REGISTRY_DNS_NAME="${REGISTRY_DEPLOYMENT}.${FLUX_NAMESPACE}.svc.cluster.local"
SOURCE_RECONCILE_INTERVAL="10m"
ROOT_RECONCILE_INTERVAL="1m"
ROOT_APPLY_TIMEOUT="5m"
SYNC_FIELD_MANAGER="tier3-sync"
SYNC_KUSTOMIZATION_SUFFIX="-sync"
SYNC_READY_TIMEOUT="300s"
API_WAIT_SECONDS=120
ROLLOUT_TIMEOUT="180s"
READY_TIMEOUT="120s"
# The cert-manager webhook can answer rollout checks before its CA bundle is injected, so applies are retried.
APPLY_RETRY_SECONDS=90
APPLY_RETRY_POLL_SECONDS=3
VALUES_FILE="$STACK_DIR/values.yaml"
TRAEFIK_NAMESPACE="kube-system"
TRAEFIK_SERVICE="traefik"
CA_CERTIFICATE_FILE="/tmp/tier3-ca.crt"
HTTP_PORT=80
HTTPS_PORT=443
HEALTH_PATH="/api/v1/health/ready"
SESSIONS_PATH="/api/v1/reviewer/sessions"
COOKIE_PATH_PREFIX="/api/v1"
CURL_TIMEOUT_SECONDS=20
EXPECTED_SYNC_COUNT=3
PASS_LABEL="PASS"
FAIL_LABEL="FAIL"

usage() {
  echo "usage: cluster.sh up | sync [<commit>] | check | curl [curl args] | status" >&2
  exit 2
}

wait_for_api() {
  waited=0
  until kubectl get --raw /readyz >/dev/null 2>&1; do
    if [ "$waited" -ge "$API_WAIT_SECONDS" ]; then
      echo "the Kubernetes API was not ready within ${API_WAIT_SECONDS}s" >&2
      exit 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
}

wait_for_deployments() {
  namespace="$1"
  shift
  for deployment in "$@"; do
    kubectl -n "$namespace" rollout status "deployment/$deployment" --timeout="$ROLLOUT_TIMEOUT"
  done
}

apply_with_retry() {
  waited=0
  until kubectl apply --server-side -f "$1"; do
    if [ "$waited" -ge "$APPLY_RETRY_SECONDS" ]; then
      echo "could not apply $1 within ${APPLY_RETRY_SECONDS}s" >&2
      exit 1
    fi
    sleep "$APPLY_RETRY_POLL_SECONDS"
    waited=$((waited + APPLY_RETRY_POLL_SECONDS))
  done
}

install_flux() {
  # Network policies stay off: staging's gotk-components.yaml has none, and they would cut Traefik off from the app pods.
  flux install --namespace="$FLUX_NAMESPACE" --components="$FLUX_COMPONENTS" --network-policy=false
  wait_for_deployments "$FLUX_NAMESPACE" source-controller kustomize-controller
}

install_registry() {
  kubectl apply --server-side -f "$REGISTRY_MANIFEST"
  wait_for_deployments "$FLUX_NAMESPACE" "$REGISTRY_DEPLOYMENT"
}

install_cert_manager_and_ca() {
  curl -fsSLo "$CERT_MANAGER_MANIFEST_FILE" "$CERT_MANAGER_MANIFEST_URL"
  echo "$CERT_MANAGER_MANIFEST_SHA256  $CERT_MANAGER_MANIFEST_FILE" | sha256sum -c - \
    || { echo "cert-manager manifest does not match the pinned sha256" >&2; exit 1; }
  kubectl apply --server-side -f "$CERT_MANAGER_MANIFEST_FILE"
  # shellcheck disable=SC2086 -- fixed list of names
  wait_for_deployments "$CERT_MANAGER_NAMESPACE" $CERT_MANAGER_DEPLOYMENTS
  apply_with_retry "$CA_ISSUER_MANIFEST"
  kubectl wait --for=condition=Ready "clusterissuer/$CA_CLUSTER_ISSUER" --timeout="$READY_TIMEOUT"
}

up() {
  wait_for_api
  install_flux
  install_registry
  install_cert_manager_and_ca
  sync "$DEFAULT_COMMIT"
}

# CD never reads .env*: nothing is pushed for a commit that holds one other than .env.example.
fail_on_env_files() {
  offenders="$(git -C "$REPO_DIR" ls-tree -r -z --name-only "$1" | tr '\0' '\n' \
    | awk -F/ '$NF ~ /^\.env/ && $NF != ".env.example"')"
  [ -z "$offenders" ] || { echo "refusing to sync: the commit holds .env* paths:" >&2; echo "$offenders" >&2; exit 1; }
}

# A symlink could point the seed at a .env* file of the read-only /repo mount; a submodule is not in the archive.
fail_on_links_and_submodules() {
  offenders="$(git -C "$REPO_DIR" ls-tree -r -z --full-tree "$1" | tr '\0' '\n' \
    | awk -F'\t' '$1 ~ /^(120000|160000) / { print substr($0, index($0, "\t") + 1) }')"
  [ -z "$offenders" ] || { echo "refusing to sync: the commit holds symlinks or submodules:" >&2; echo "$offenders" >&2; exit 1; }
}

# The OCIRepository is pinned to the digest this push returns, not to a tag, so a replaced tag is never applied.
push_artifact() {
  registry_ip="$(kubectl -n "$FLUX_NAMESPACE" get service "$REGISTRY_DEPLOYMENT" -o jsonpath='{.spec.clusterIP}')"
  flux push artifact "oci://${registry_ip}:${REGISTRY_PORT}/${REGISTRY_REPOSITORY}:$2" \
    --path="$1" --source="$SOURCE_NAME" --revision="$3" --insecure-registry --output json | jq -r '.digest'
}

apply_source_and_root() {
  kubectl apply --server-side --force-conflicts --field-manager="$SYNC_FIELD_MANAGER" -f - <<EOF
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: $SOURCE_NAME
  namespace: $FLUX_NAMESPACE
spec:
  interval: $SOURCE_RECONCILE_INTERVAL
  url: oci://${REGISTRY_DNS_NAME}:${REGISTRY_PORT}/${REGISTRY_REPOSITORY}
  insecure: true
  ref:
    digest: $1
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: $ROOT_KUSTOMIZATION_NAME
  namespace: $FLUX_NAMESPACE
spec:
  interval: $ROOT_RECONCILE_INTERVAL
  retryInterval: $ROOT_RECONCILE_INTERVAL
  sourceRef:
    kind: OCIRepository
    name: $SOURCE_NAME
  path: $ROOT_KUSTOMIZATION_PATH
  prune: true
  wait: true
  timeout: $ROOT_APPLY_TIMEOUT
EOF
}

wait_for_sync_kustomizations() {
  names="$(kubectl -n "$FLUX_NAMESPACE" get kustomizations.kustomize.toolkit.fluxcd.io -o name | grep -- "${SYNC_KUSTOMIZATION_SUFFIX}\$" || true)"
  [ -n "$names" ] || { echo "no *$SYNC_KUSTOMIZATION_SUFFIX Kustomization exists after the sync" >&2; exit 1; }
  for name in $names; do
    kubectl -n "$FLUX_NAMESPACE" wait --for=condition=Ready "$name" --timeout="$SYNC_READY_TIMEOUT" \
      || { status; exit 1; }
  done
}

sync() {
  commit_name="${1:-$DEFAULT_COMMIT}"
  commit_sha="$(git -C "$REPO_DIR" rev-parse --verify --end-of-options "${commit_name}^{commit}")" \
    || { echo "not a commit: $commit_name" >&2; exit 1; }
  fail_on_env_files "$commit_sha"
  fail_on_links_and_submodules "$commit_sha"
  tree="$(mktemp -d)"
  trap 'rm -rf "$tree"' EXIT
  git -C "$REPO_DIR" archive "$commit_sha" | tar -x -C "$tree"
  "$SEED_SCRIPT" "$tree"
  digest="$(push_artifact "$tree" "$commit_sha" "${commit_name}@sha1:${commit_sha}")"
  case "$digest" in sha256:*) ;; *) echo "flux push returned no sha256 digest" >&2; exit 1 ;; esac
  apply_source_and_root "$digest"
  flux -n "$FLUX_NAMESPACE" reconcile kustomization "$ROOT_KUSTOMIZATION_NAME" --with-source \
    || echo "root Kustomization is not Ready yet; checking the *$SYNC_KUSTOMIZATION_SUFFIX Kustomizations" >&2
  wait_for_sync_kustomizations
}

status() {
  # Before the first sync there is no source and no Kustomization, which flux reports as an error.
  flux -n "$FLUX_NAMESPACE" get sources oci || true
  flux -n "$FLUX_NAMESPACE" get kustomizations || true
  # Flux shows the artifact digest as the revision; the commit sha travels in the artifact metadata.
  kubectl -n "$FLUX_NAMESPACE" get ocirepository "$SOURCE_NAME" -o json 2>/dev/null \
    | jq -r '"commit: " + (.status.artifact.metadata["org.opencontainers.image.revision"] // "none")' || true
  kubectl -n "$FLUX_NAMESPACE" get pods
}

# --- curl and check: reach the three tier 3 hosts through Traefik with the local CA ---

values_of() {
  yq -r ".\"$1\".$2" "$VALUES_FILE"
}

# Sets DOMAIN, ADMIN_HOST, API_HOST, TRAEFIK_IP and writes the public CA certificate (no private key is read).
prepare_hosts() {
  DOMAIN="$(values_of shared-configmap APP_DOMAIN)"
  ADMIN_HOST="admin.$DOMAIN"
  API_HOST="api.$DOMAIN"
  TRAEFIK_IP="$(kubectl -n "$TRAEFIK_NAMESPACE" get service "$TRAEFIK_SERVICE" -o jsonpath='{.spec.clusterIP}')"
  kubectl -n "$CERT_MANAGER_NAMESPACE" get secret "$CA_CLUSTER_ISSUER" -o jsonpath='{.data.ca\.crt}' | base64 -d >"$CA_CERTIFICATE_FILE"
}

# Plain curl, the local CA, and the three hosts resolved to Traefik's ClusterIP. stdin is closed so a caller's read loop is safe.
stack_curl() {
  curl --cacert "$CA_CERTIFICATE_FILE" --max-time "$CURL_TIMEOUT_SECONDS" \
    --resolve "$DOMAIN:$HTTP_PORT:$TRAEFIK_IP" --resolve "$DOMAIN:$HTTPS_PORT:$TRAEFIK_IP" \
    --resolve "$ADMIN_HOST:$HTTP_PORT:$TRAEFIK_IP" --resolve "$ADMIN_HOST:$HTTPS_PORT:$TRAEFIK_IP" \
    --resolve "$API_HOST:$HTTP_PORT:$TRAEFIK_IP" --resolve "$API_HOST:$HTTPS_PORT:$TRAEFIK_IP" \
    "$@" </dev/null
}

curl_command() {
  prepare_hosts
  stack_curl "$@"
}

# The checks, one row each: function|item-id|entry ids|what. A new check is one row and one function.
CHECK_TABLE='check_web_serves|web-https|SEC-DC-T5-1|web https root answers 200
check_admin_serves|admin-https|SEC-DC-T5-1|cms-admin https root answers 200
check_api_health|api-health|SEC-DC-T5-1|cms-api health on the api host answers 200
check_api_route_on_bare_domain|api-bare-route|SEC-AF-T1-1,CAF-9|bare domain /api/v1 health is answered by cms-api like the api host
check_http_redirects|http-redirect|SEC-AF-T1-1,SEC-DC-T5-1|http redirects (301/308) to https on the same host, all three hosts
check_certificates|tls-san|SEC-AF-T1-1,CAF-9|api host cert lists both names and every host cert verifies against tier3-ca
check_same_origin_post|cors-post|SEC-AF-T1-1,CAF-9|same-origin POST to the sessions path is not a CORS rejection
check_cookie_flags|cookie-flags|SEC-AF-T1-1|cms-api Set-Cookie on the bare domain has Secure, HttpOnly, no wider Domain, Path under /api/v1 (FAIL when none seen)
check_ingress_hosts|ingress-hosts|SEC-DC-T5-1,SEC-AF-T1-1|Ingress hosts and paths are exactly the expected set
check_syncs_and_pods|syncs-pods|SEC-DC-T5-1|three app syncs Ready and every pod fully ready'

# Prints the status code of GET $1 and keeps the body in $2.
fetch_status() {
  stack_curl -sS -o "$2" -w '%{http_code}' "$1" 2>/dev/null || echo "000"
}

expect_status_200() {
  code="$(fetch_status "$1" /dev/null)"
  [ "$code" = "200" ] || { DETAIL="$1 answered $code"; return 1; }
}

check_web_serves() { expect_status_200 "https://$DOMAIN/"; }
check_admin_serves() { expect_status_200 "https://$ADMIN_HOST/"; }

check_api_health() {
  API_HEALTH_CODE="$(fetch_status "https://$API_HOST$HEALTH_PATH" "$WORK_DIR/api-health.body")"
  [ "$API_HEALTH_CODE" = "200" ] || { DETAIL="https://$API_HOST$HEALTH_PATH answered $API_HEALTH_CODE"; return 1; }
}

check_api_route_on_bare_domain() {
  code="$(stack_curl -sS -D "$WORK_DIR/bare-health.headers" -o "$WORK_DIR/bare-health.body" -w '%{http_code}' "https://$DOMAIN$HEALTH_PATH" 2>/dev/null || echo "000")"
  [ "$code" = "200" ] || { DETAIL="https://$DOMAIN$HEALTH_PATH answered $code"; return 1; }
  [ "${API_HEALTH_CODE:-}" = "200" ] || { DETAIL="no reference answer: the api host check did not pass"; return 1; }
  cmp -s "$WORK_DIR/api-health.body" "$WORK_DIR/bare-health.body" \
    || { DETAIL="the body on the bare domain differs from the api host"; return 1; }
}

check_http_redirects() {
  for host in "$DOMAIN" "$ADMIN_HOST" "$API_HOST"; do
    answer="$(stack_curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "http://$host/" 2>/dev/null || echo "000 ")"
    code="${answer%% *}"
    target="${answer#* }"
    case "$code" in 301 | 308) ;; *) DETAIL="http://$host/ answered $code"; return 1 ;; esac
    case "$target" in "https://$host/"*) ;; *) DETAIL="http://$host/ redirects to a different place"; return 1 ;; esac
  done
}

# Prints the handshake output for SNI host $1 when its certificate verifies against the local CA for that name.
served_certificate() {
  handshake="$(openssl s_client -connect "$TRAEFIK_IP:$HTTPS_PORT" -servername "$1" -CAfile "$CA_CERTIFICATE_FILE" \
    -verify_hostname "$1" </dev/null 2>&1)" || true
  echo "$handshake" | grep -q 'Verify return code: 0 (ok)' || return 1
  echo "$handshake"
}

check_certificates() {
  for host in "$DOMAIN" "$ADMIN_HOST"; do
    served_certificate "$host" >/dev/null \
      || { DETAIL="the certificate served for $host does not verify against $CA_CLUSTER_ISSUER for that name"; return 1; }
  done
  api_handshake="$(served_certificate "$API_HOST")" \
    || { DETAIL="the certificate served for $API_HOST does not verify against $CA_CLUSTER_ISSUER for that name"; return 1; }
  names="$(echo "$api_handshake" | openssl x509 -noout -ext subjectAltName 2>/dev/null)"
  for host in "$API_HOST" "$DOMAIN"; do
    echo "$names" | grep -qE "DNS:$host(,|$)" || { DETAIL="the certificate served for $API_HOST has no SAN $host"; return 1; }
  done
}

check_same_origin_post() {
  origin="https://$DOMAIN"
  code="$(stack_curl -sS -D "$WORK_DIR/post.headers" -o /dev/null -w '%{http_code}' -X POST \
    -H "Origin: $origin" -H 'Content-Type: application/json' --data '{}' "$origin$SESSIONS_PATH" 2>/dev/null || echo "000")"
  # Only allowlisted headers are printed; a Set-Cookie keeps its attributes and loses everything before the first ";".
  DETAIL="$(tr -d '\r' <"$WORK_DIR/post.headers" | awk '
    NR == 1 || tolower($0) ~ /^(access-control-[a-z-]*|vary|location):/ { print }
    tolower($0) ~ /^set-cookie:/ { sub(/^[^;]*/, "Set-Cookie: <redacted>"); print }')"
  KEEP_DETAIL=1
  # 000 is no answer; 502/503/504 come from Traefik with no cms-api behind it, which proves nothing about CORS.
  case "$code" in 000 | 403 | 502 | 503 | 504) DETAIL="status $code
$DETAIL"; return 1 ;; esac
  allow_origin="$(tr -d '\r' <"$WORK_DIR/post.headers" | sed -n 's/^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin: *//p')"
  [ -z "$allow_origin" ] || [ "$allow_origin" = "$origin" ] || { DETAIL="Access-Control-Allow-Origin is $allow_origin
$DETAIL"; return 1; }
}

check_cookie_flags() {
  cookies="$(cat "$WORK_DIR/bare-health.headers" "$WORK_DIR/post.headers" 2>/dev/null | tr -d '\r' | grep -i '^set-cookie:' || true)"
  [ -n "$cookies" ] || { DETAIL="no Set-Cookie seen: cookie flags not verified"; return 1; }
  echo "$cookies" | awk -v host="$DOMAIN" -v pathPrefix="$COOKIE_PATH_PREFIX" '
    { line = tolower($0) }
    line !~ /; *secure( |;|$)/ { bad = 1 }
    line !~ /; *httponly( |;|$)/ { bad = 1 }
    match(line, /; *domain=[^;]*/) {
      domain = substr(line, RSTART, RLENGTH); sub(/^; *domain=/, "", domain); sub(/^\./, "", domain)
      if (domain != host) bad = 1
    }
    match(line, /; *path=[^;]*/) {
      cookiePath = substr(line, RSTART, RLENGTH); sub(/^; *path=/, "", cookiePath)
      if (index(cookiePath, pathPrefix) != 1) bad = 1
    }
    !match(line, /; *path=[^;]*/) { bad = 1 }
    END { exit bad }' || { DETAIL="a Set-Cookie lacks Secure or HttpOnly, has a Domain other than $DOMAIN, or a Path outside $COOKIE_PATH_PREFIX"; return 1; }
}

check_ingress_hosts() {
  env_name="$(values_of shared-configmap APP_ENV)"
  web="$(values_of web-configmap APP_SERVICE_NAME)-$env_name"
  admin="$(values_of admin-configmap APP_SERVICE_NAME)-$env_name"
  api="$(values_of api-configmap APP_SERVICE_NAME)-$env_name"
  expected="$(printf '%s\n' "$web $DOMAIN /" "$admin $ADMIN_HOST /" "$api $API_HOST /" "$api $DOMAIN /api/v1" | sort)"
  actual="$(kubectl -n "$FLUX_NAMESPACE" get ingress -o json \
    | jq -r '.items[] | .metadata.name as $n | .spec.rules[] | (.host // "NO-HOST") as $h | .http.paths[] | "\($n) \($h) \(.path)"' | sort)"
  [ "$actual" = "$expected" ] || { DETAIL="Ingress rules differ. expected:
$expected
actual:
$actual"; return 1; }
}

check_syncs_and_pods() {
  syncs="$(kubectl -n "$FLUX_NAMESPACE" get kustomizations.kustomize.toolkit.fluxcd.io -o json \
    | jq -r --arg suffix "$SYNC_KUSTOMIZATION_SUFFIX" '[.items[] | select(.metadata.name | endswith($suffix))] | "\(length) " + ([.[] | select(([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length) == 0) | .metadata.name] | join(","))')"
  sync_count="${syncs%% *}"
  not_ready_syncs="${syncs#* }"
  [ "$sync_count" -ge "$EXPECTED_SYNC_COUNT" ] && [ -z "$not_ready_syncs" ] \
    || { DETAIL="sync Kustomizations found: $sync_count; not Ready: $not_ready_syncs"; return 1; }
  not_ready_pods="$(kubectl -n "$FLUX_NAMESPACE" get pods -o json \
    | jq -r '[.items[] | select(.status.phase != "Succeeded") | select((.status.containerStatuses // []) | (length == 0) or any(.ready | not)) | .metadata.name] | join(" ")')"
  [ -z "$not_ready_pods" ] || { DETAIL="pods not ready: $not_ready_pods"; return 1; }
}

run_checks() {
  prepare_hosts
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "$WORK_DIR"' EXIT
  failures=0
  while IFS='|' read -r check_function item_id entry_ids what <&3; do
    DETAIL=""
    KEEP_DETAIL=0
    if "$check_function"; then label="$PASS_LABEL"; else label="$FAIL_LABEL"; failures=$((failures + 1)); KEEP_DETAIL=1; fi
    echo "$label $item_id $entry_ids $what"
    if [ "$KEEP_DETAIL" = 1 ] && [ -n "$DETAIL" ]; then echo "$DETAIL" | sed 's/^/  /'; fi
  done 3<<ROWS
$CHECK_TABLE
ROWS
  [ "$failures" -eq 0 ]
}

[ $# -ge 1 ] || usage
command="$1"
shift
case "$command" in
  up) up ;;
  sync) sync "$@" ;;
  status) status ;;
  check) run_checks ;;
  curl) curl_command "$@" ;;
  *) usage ;;
esac
