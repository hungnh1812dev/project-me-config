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
API_WAIT_SECONDS=120
ROLLOUT_TIMEOUT="180s"
READY_TIMEOUT="120s"
# The cert-manager webhook can answer rollout checks before its CA bundle is injected, so applies are retried.
APPLY_RETRY_SECONDS=90
APPLY_RETRY_POLL_SECONDS=3

usage() {
  echo "usage: cluster.sh up | status" >&2
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
  "$SEED_SCRIPT"
}

status() {
  # Before the first sync there is no source and no Kustomization, which flux reports as an error.
  flux -n "$FLUX_NAMESPACE" get sources oci || true
  flux -n "$FLUX_NAMESPACE" get kustomizations || true
  kubectl -n "$FLUX_NAMESPACE" get pods
}

[ $# -ge 1 ] || usage
command="$1"
shift
case "$command" in
  up) up ;;
  status) status ;;
  *) usage ;;
esac
