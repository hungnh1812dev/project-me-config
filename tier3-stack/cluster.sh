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

usage() {
  echo "usage: cluster.sh up | sync [<commit>] | status" >&2
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

[ $# -ge 1 ] || usage
command="$1"
shift
case "$command" in
  up) up ;;
  sync) sync "$@" ;;
  status) status ;;
  *) usage ;;
esac
