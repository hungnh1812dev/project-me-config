#!/bin/sh
# Tier 3 seed (ADR-0003 section 5): renders every Secret and ConfigMap of templates/*.example.yaml with the
# values of tier3-stack/values.yaml, then applies them all at once. Runs in the tools container, called by
# cluster.sh. Usage: seed.sh [<tree>]  (default /repo; a tree is a checkout of the commit under test).
# Values live in shell variables and pipes only: never on a command line, on disk or in the output.
set -eu

DEFAULT_TREE="/repo"
LOCAL_ENV_FILE="/repo/.localEnv.agent"
TEMPLATES_GLOB="templates/*.example.yaml"
VALUES_FILE="tier3-stack/values.yaml"
TARGET_NAMESPACE="project-me-tier3"
FIELD_MANAGER="tier3-seed"
CA_NAMESPACE="cert-manager"
GENERATED_BYTES=32
IMAGE_TAG_KEY="APP_IMAGE_TAG"
PULL_SECRET_NAME="tier3-registry-credentials"
PULL_SERVICE_ACCOUNT="default"
LOCAL_REGISTRY_SERVER_KEY="TIER3_REGISTRY_SERVER"
LOCAL_REGISTRY_USERNAME_KEY="TIER3_REGISTRY_USERNAME"
LOCAL_REGISTRY_TOKEN_KEY="TIER3_REGISTRY_TOKEN"

TREE="${1:-$DEFAULT_TREE}"
NL='
'
TAB="$(printf '\t')"

values_json=""
generated=""
items=""
resolved=""

fail() {
  echo "seed: $*" >&2
  exit 1
}

read_local_key() {
  [ -r "$LOCAL_ENV_FILE" ] || return 1
  line="$(grep -m1 "^$1=" "$LOCAL_ENV_FILE")" || return 1
  value="${line#*=}"
  value="${value#\"}"
  value="${value%\"}"
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

require_local_key() {
  resolved="$(read_local_key "$1")" || fail "$2: key $3 needs $1 in .localEnv.agent (see tier3-stack/.env.example)"
}

resolve_generated() {
  stored="$(printf '%s' "$generated" | awk -F"$TAB" -v name="$1" '$1 == name { print $2 }')"
  if [ -z "$stored" ]; then
    stored="$(openssl rand -hex "$GENERATED_BYTES")"
    generated="${generated}$1${TAB}${stored}${NL}"
  fi
  resolved="$stored"
}

resolve_cluster_ca() {
  resolved="$(kubectl -n "$CA_NAMESPACE" get secret "$1" -o json | jq -r '.data["ca.crt"] // empty' | base64 -d)"
  [ -n "$resolved" ] || fail "$2: key $3 found no ca.crt in Secret $1 of $CA_NAMESPACE"
}

resolve_image_tag() {
  overlay="$(printf '%s' "$1" | jq -r '.["image-tag"].overlay // empty')"
  override_key="$(printf '%s' "$1" | jq -r '.["image-tag"].local // empty')"
  [ -n "$overlay" ] || fail "$2: key $3 has an image-tag form without overlay"
  if [ -n "$override_key" ] && resolved="$(read_local_key "$override_key")"; then
    return 0
  fi
  [ -f "$TREE/$overlay" ] || fail "$2: key $3 overlay $overlay is not in the tree"
  resolved="$(yq -r '.spec.postBuild.substitute.APP_IMAGE_TAG // ""' "$TREE/$overlay")"
  [ -n "$resolved" ] || fail "$2: key $3 found no $IMAGE_TAG_KEY in $overlay"
}

value_form() {
  printf '%s' "$1" | jq -r '
    if type == "null" then "missing"
    elif type == "object" then (if length == 1 then keys_unsorted[0] else "invalid" end)
    else "literal" end'
}

resolve_value() {
  node="$1"
  form="$(value_form "$node")"
  case "$form" in
    missing) fail "$2: key $3 has no value in $VALUES_FILE" ;;
    invalid) fail "$2: key $3 has a value form with more than one entry" ;;
    literal) resolved="$(printf '%s' "$node" | jq -r 'tostring')" ;;
    generate) resolve_generated "$(printf '%s' "$node" | jq -r '.generate')" ;;
    local) require_local_key "$(printf '%s' "$node" | jq -r '.local')" "$2" "$3" ;;
    cluster-ca) resolve_cluster_ca "$(printf '%s' "$node" | jq -r '.["cluster-ca"]')" "$2" "$3" ;;
    image-tag) resolve_image_tag "$node" "$2" "$3" ;;
    *) fail "$2: key $3 has the unknown value form $form" ;;
  esac
}

template_keys() {
  yq -o=json -I=0 '(.data // .stringData // {})' "$1" | jq -r 'keys_unsorted[]'
}

values_keys() {
  printf '%s' "$values_json" | jq -r --arg object "$1" '.[$object] | keys_unsorted[]'
}

node_of() {
  printf '%s' "$values_json" | jq -c --arg object "$1" --arg key "$2" '.[$object][$key]'
}

# Keys of values.yaml that the template lacks are allowed only for image-tag entries.
extra_keys_of() {
  for key in $(values_keys "$2"); do
    if template_keys "$1" | grep -qx -- "$key"; then continue; fi
    [ "$(value_form "$(node_of "$2" "$key")")" = "image-tag" ] || fail "$2: key $key is in $VALUES_FILE but not in the template"
    echo "$key"
  done
}

render_object() {
  kind="$1" name="$2" type="$3" pairs="$4"
  printf '%s' "$pairs" | jq -Rnc --arg kind "$kind" --arg name "$name" --arg type "$type" --arg namespace "$TARGET_NAMESPACE" '
    [inputs | select(length > 0) | split("\t")]
    | (map({ (.[0]): .[1] }) | add // {}) as $data
    | if $kind == "Secret"
      then { apiVersion: "v1", kind: "Secret", type: $type, metadata: { name: $name, namespace: $namespace }, data: $data }
      else { apiVersion: "v1", kind: "ConfigMap", metadata: { name: $name, namespace: $namespace }, data: ($data | map_values(@base64d)) }
      end'
}

seed_template() {
  template="$1"
  kind="$(yq -r '.kind' "$template")"
  name="$(yq -r '.metadata.name' "$template")"
  type="$(yq -r '.type // "Opaque"' "$template")"
  case "$kind" in Secret | ConfigMap) ;; *) fail "$template: kind $kind is not a Secret or a ConfigMap" ;; esac
  printf '%s' "$values_json" | jq -e --arg object "$name" 'has($object)' >/dev/null || fail "$name: no entry in $VALUES_FILE"

  keys="$(template_keys "$template")${NL}$(extra_keys_of "$template" "$name")"
  pairs=""
  names=""
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    resolve_value "$(node_of "$name" "$key")" "$name" "$key"
    encoded="$(printf '%s' "$resolved" | base64 | tr -d '\n')"
    pairs="${pairs}${key}${TAB}${encoded}${NL}"
    names="$names $key"
  done <<EOF
$keys
EOF
  items="${items}$(render_object "$kind" "$name" "$type" "$pairs")${NL}"
  echo "seed: $kind $name:${names:- (no keys)}"
}

fail_on_values_without_template() {
  expected="$(for template in "$TREE"/$TEMPLATES_GLOB; do yq -r '.metadata.name' "$template"; done)"
  for object in $(printf '%s' "$values_json" | jq -r 'keys_unsorted[]'); do
    printf '%s\n' "$expected" | grep -qx -- "$object" || fail "$object: is in $VALUES_FILE but has no template"
  done
}

add_pull_credentials() {
  token="$(read_local_key "$LOCAL_REGISTRY_TOKEN_KEY")" || return 0
  server="$(read_local_key "$LOCAL_REGISTRY_SERVER_KEY")" || fail "pull credentials: $LOCAL_REGISTRY_TOKEN_KEY is set, so $LOCAL_REGISTRY_SERVER_KEY is needed"
  username="$(read_local_key "$LOCAL_REGISTRY_USERNAME_KEY")" || fail "pull credentials: $LOCAL_REGISTRY_TOKEN_KEY is set, so $LOCAL_REGISTRY_USERNAME_KEY is needed"
  docker_config="$(TIER3_S="$server" TIER3_U="$username" TIER3_T="$token" jq -nc '
    { auths: { (env.TIER3_S): { username: env.TIER3_U, password: env.TIER3_T, auth: ((env.TIER3_U + ":" + env.TIER3_T) | @base64) } } }')"
  encoded="$(printf '%s' "$docker_config" | base64 | tr -d '\n')"
  secret="$(printf '%s' "$encoded" | jq -Rnc --arg name "$PULL_SECRET_NAME" --arg namespace "$TARGET_NAMESPACE" '
    input as $data
    | { apiVersion: "v1", kind: "Secret", type: "kubernetes.io/dockerconfigjson", metadata: { name: $name, namespace: $namespace }, data: { ".dockerconfigjson": $data } }')"
  account="$(jq -nc --arg name "$PULL_SERVICE_ACCOUNT" --arg secret "$PULL_SECRET_NAME" --arg namespace "$TARGET_NAMESPACE" '
    { apiVersion: "v1", kind: "ServiceAccount", metadata: { name: $name, namespace: $namespace }, imagePullSecrets: [{ name: $secret }] }')"
  items="${items}${secret}${NL}${account}${NL}"
  echo "seed: Secret $PULL_SECRET_NAME and ServiceAccount $PULL_SERVICE_ACCOUNT imagePullSecrets"
}

apply_items() {
  printf '%s' "$items" | jq -sc '{ apiVersion: "v1", kind: "List", items: . }' \
    | kubectl apply --server-side --force-conflicts --field-manager="$FIELD_MANAGER" -f -
}

[ -f "$TREE/$VALUES_FILE" ] || fail "$VALUES_FILE is not in the tree $TREE"
if [ -e "$LOCAL_ENV_FILE" ] && [ ! -r "$LOCAL_ENV_FILE" ]; then
  fail ".localEnv.agent exists but the tools user cannot read it; the file may then hold throwaway values only, never a real token"
fi
values_json="$(yq -o=json -I=0 '.' "$TREE/$VALUES_FILE")"
fail_on_values_without_template
for template in "$TREE"/$TEMPLATES_GLOB; do
  seed_template "$template"
done
add_pull_credentials
apply_items
