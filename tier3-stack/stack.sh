#!/bin/sh
# Tier 3 stack lifecycle (ADR-0003). Runs on the host and calls only docker.
set -eu

K3S_IMAGE="rancher/k3s:v1.36.4-k3s1"
TOOLS_IMAGE="project-me-tier3-tools:local"
K3S_CONTAINER="project-me-tier3-k3s"
TOOLS_CONTAINER="project-me-tier3-tools"
KUBECONFIG_VOLUME="project-me-tier3-kubeconfig"
K3S_DATA_VOLUME="project-me-tier3-k3s-data"
STACK_LABEL="project-me.tier3=true"
KUBECONFIG_FILE="kubeconfig.yaml"
KUBECONFIG_WAIT_SECONDS=120
KUBECONFIG_POLL_SECONDS=2
# World-readable: the tools user is not root. The volume is mounted read-only there and never published.
KUBECONFIG_MODE="0644"
PASS_THROUGH_COMMANDS="sync check curl status"

STACK_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$STACK_DIR")"

usage() {
  echo "usage: stack.sh up | down | ${PASS_THROUGH_COMMANDS% *} ${PASS_THROUGH_COMMANDS##* }" >&2
  exit 2
}

labelled_containers() {
  docker ps -a -q --filter "label=$STACK_LABEL"
}

labelled_volumes() {
  docker volume ls -q --filter "label=$STACK_LABEL"
}

run_in_tools_container() {
  docker run --rm --name "$TOOLS_CONTAINER" --label "$STACK_LABEL" \
    --cap-drop ALL --security-opt no-new-privileges \
    --network "container:$K3S_CONTAINER" \
    -v "$REPO_DIR:/repo:ro" \
    -v "$KUBECONFIG_VOLUME:/kubeconfig:ro" \
    "$TOOLS_IMAGE" "$@"
}

wait_for_kubeconfig() {
  waited=0
  until docker exec "$K3S_CONTAINER" test -s "/output/$KUBECONFIG_FILE" 2>/dev/null; do
    if [ "$waited" -ge "$KUBECONFIG_WAIT_SECONDS" ]; then
      echo "k3s wrote no kubeconfig within ${KUBECONFIG_WAIT_SECONDS}s" >&2
      exit 1
    fi
    sleep "$KUBECONFIG_POLL_SECONDS"
    waited=$((waited + KUBECONFIG_POLL_SECONDS))
  done
}

up() {
  if [ -n "$(labelled_containers)" ]; then
    echo "a tier 3 stack already exists: use 'stack.sh sync' to update it or 'stack.sh down' first" >&2
    exit 1
  fi
  docker build --label "$STACK_LABEL" -t "$TOOLS_IMAGE" "$STACK_DIR"
  docker volume create --label "$STACK_LABEL" "$KUBECONFIG_VOLUME" >/dev/null
  docker volume create --label "$STACK_LABEL" "$K3S_DATA_VOLUME" >/dev/null
  docker run -d --privileged --name "$K3S_CONTAINER" --label "$STACK_LABEL" \
    -e "K3S_KUBECONFIG_OUTPUT=/output/$KUBECONFIG_FILE" \
    -e "K3S_KUBECONFIG_MODE=$KUBECONFIG_MODE" \
    -v "$K3S_DATA_VOLUME:/var/lib/rancher/k3s" \
    -v "$KUBECONFIG_VOLUME:/output" \
    "$K3S_IMAGE" server >/dev/null
  wait_for_kubeconfig
  run_in_tools_container up
}

down() {
  containers="$(labelled_containers)"
  # shellcheck disable=SC2086 -- ids never contain spaces
  [ -z "$containers" ] || docker rm -f $containers >/dev/null
  volumes="$(labelled_volumes)"
  # shellcheck disable=SC2086
  [ -z "$volumes" ] || docker volume rm $volumes >/dev/null
}

is_pass_through() {
  for name in $PASS_THROUGH_COMMANDS; do
    [ "$name" = "$1" ] && return 0
  done
  return 1
}

[ $# -ge 1 ] || usage
command="$1"
shift
case "$command" in
  up) up ;;
  down) down ;;
  *) if is_pass_through "$command"; then run_in_tools_container "$command" "$@"; else usage; fi ;;
esac
