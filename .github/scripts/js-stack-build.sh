#!/usr/bin/env bash
# Build @processmaker/* packages in dependency order, cascading downstream.
# Reads processmaker.downstream and processmaker.command from each package.json (source of truth).
set -euo pipefail

STACK_DIR="${STACK_DIR:-js-stack}"
STACK_DIR="$(cd "$(dirname "$STACK_DIR")" 2>/dev/null && pwd)/$(basename "$STACK_DIR")" || STACK_DIR="$(pwd)/${STACK_DIR}"
MANIFEST="${STACK_DIR}/manifest.json"
BRANCH_MAP="${BRANCH_MAP:-{}}"
TRIGGER_REPO="${TRIGGER_REPO:-}"
TRIGGER_REF="${TRIGGER_REF:-}"
GH_ORG="${GH_ORG:-ProcessMaker}"

declare -A NPM_NAMES=(
  [vue-multiselect]=vue-multiselect
  [vue-form-elements]=vue-form-elements
  [screen-builder]=screen-builder
  [modeler]=modeler
  [processmaker-bpmn-moddle]=processmaker-bpmn-moddle
  [processmaker]=processmaker
)

ALL_PACKAGES=(vue-multiselect vue-form-elements screen-builder modeler processmaker-bpmn-moddle processmaker)

is_known_package() {
  local pkg="$1"
  for p in "${ALL_PACKAGES[@]}"; do
    [[ "$p" == "$pkg" ]] && return 0
  done
  return 1
}

fetch_package_json() {
  local repo="$1"
  local ref="$2"
  ref=$(normalize_ref "$ref")
  gh api "repos/${GH_ORG}/${repo}/contents/package.json?ref=${ref}" --jq '.content' 2>/dev/null | base64 -d
}

default_branch() {
  local repo="$1"
  gh api "repos/${GH_ORG}/${repo}" --jq .default_branch
}

normalize_ref() {
  local ref="$1"
  ref="${ref#refs/heads/}"
  ref="${ref#refs/tags/}"
  echo "$ref"
}

resolve_ref() {
  local repo="$1"
  local from_map
  from_map=$(echo "$BRANCH_MAP" | jq -r --arg r "$repo" '.[$r] // empty')
  if [[ -n "$from_map" ]]; then
    echo "$from_map"
    return
  fi
  if [[ "$repo" == "$TRIGGER_REPO" && -n "$TRIGGER_REF" ]]; then
    echo "$TRIGGER_REF"
    return
  fi
  default_branch "$repo"
}

get_downstream() {
  if ! jq -e '.processmaker | has("downstream")' >/dev/null; then
    echo "::error::processmaker.downstream is required in package.json" >&2
    exit 1
  fi
  jq -r '.processmaker.downstream[]?'
}

get_build_command() {
  local cmd
  cmd=$(jq -r '.processmaker.command // empty')
  if [[ -z "$cmd" || "$cmd" == "null" ]]; then
    echo "::error::processmaker.command is required in package.json" >&2
    exit 1
  fi
  echo "$cmd"
}

get_pm_deps() {
  jq -r '
    [.dependencies, .devDependencies, .peerDependencies]
    | map(select(. != null))
    | add // {}
    | to_entries[]
    | select(.key | startswith("@processmaker/"))
    | .key
    | ltrimstr("@processmaker/")
  '
}

uses_yarn() {
  [[ -f yarn.lock ]]
}

declare -A BUILD_SET=()
declare -A EXPLICIT_SET=()

add_immediate_upstream() {
  local repo="$1"
  local candidate ref pkg_json
  for candidate in "${ALL_PACKAGES[@]}"; do
    [[ "$candidate" == "$repo" ]] && continue
    ref=$(resolve_ref "$candidate")
    pkg_json=$(fetch_package_json "$candidate" "$ref") || continue
    if echo "$pkg_json" | get_downstream | grep -qx "$repo"; then
      BUILD_SET[$candidate]=1
    fi
  done
}

add_downstream() {
  local repo="$1"
  local ref pkg_json down
  ref=$(resolve_ref "$repo")
  pkg_json=$(fetch_package_json "$repo" "$ref") || return 0
  while IFS= read -r down; do
    [[ -z "$down" ]] && continue
    is_known_package "$down" || continue
    if [[ -z "${BUILD_SET[$down]:-}" ]]; then
      BUILD_SET[$down]=1
      add_downstream "$down"
    fi
  done < <(echo "$pkg_json" | get_downstream)
}

while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue
  is_known_package "$repo" || continue
  BUILD_SET[$repo]=1
  EXPLICIT_SET[$repo]=1
done < <(echo "$BRANCH_MAP" | jq -r 'keys[]?')

if [[ -n "$TRIGGER_REPO" ]] && is_known_package "$TRIGGER_REPO" && [[ "$TRIGGER_REPO" != "processmaker" ]]; then
  BUILD_SET[$TRIGGER_REPO]=1
  EXPLICIT_SET[$TRIGGER_REPO]=1
fi

if [[ ${#BUILD_SET[@]} -eq 0 ]]; then
  echo "No JS packages to build."
  mkdir -p "$STACK_DIR"
  echo '{}' > "$MANIFEST"
  exit 0
fi

# When modeler is explicitly tagged, build its immediate upstream publishers first
if echo "$BRANCH_MAP" | jq -e '.modeler' >/dev/null 2>&1; then
  add_immediate_upstream modeler
fi

# Downstream cascade for everything in the build set
for _pass in 1 2 3 4 5; do
  for repo in "${!BUILD_SET[@]}"; do
    add_downstream "$repo"
  done
done

echo "Packages to build: ${!BUILD_SET[*]}"

FINAL_ORDER=()
declare -A VISITED_SORT=()

topo_visit() {
  local repo="$1"
  [[ -n "${VISITED_SORT[$repo]:-}" ]] && return 0
  VISITED_SORT[$repo]=1

  local ref pkg_json dep
  ref=$(resolve_ref "$repo")
  pkg_json=$(fetch_package_json "$repo" "$ref") || { FINAL_ORDER+=("$repo"); return 0; }

  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    [[ -z "${BUILD_SET[$dep]:-}" ]] && continue
    topo_visit "$dep"
  done < <(echo "$pkg_json" | get_pm_deps)

  FINAL_ORDER+=("$repo")
}

for repo in "${!BUILD_SET[@]}"; do
  topo_visit "$repo"
done

echo "Build order: ${FINAL_ORDER[*]}"

mkdir -p "$STACK_DIR/tarballs"
echo '{}' > "$MANIFEST"

BUILT_TARBALLS=()

build_package() {
  local repo="$1"
  local ref workdir
  ref=$(normalize_ref "$(resolve_ref "$repo")")
  workdir=$(mktemp -d)

  echo "=== Building ${repo} @ ${ref} ==="
  if ! git clone --depth 1 --branch "$ref" "https://github.com/${GH_ORG}/${repo}.git" "$workdir" 2>/dev/null; then
    git clone --depth 1 "https://github.com/${GH_ORG}/${repo}.git" "$workdir"
    git -C "$workdir" checkout "$ref"
  fi

  cd "$workdir"

  if uses_yarn; then
    yarn install --frozen-lockfile 2>/dev/null || yarn install
  else
    npm ci
  fi

  if [[ ${#BUILT_TARBALLS[@]} -gt 0 ]]; then
    echo "Installing upstream tarballs..."
    for tb in "${BUILT_TARBALLS[@]}"; do
      npm install "$tb" --no-save --force
    done
  fi

  local build_cmd
  build_cmd=$(get_build_command)

  if uses_yarn; then
    yarn run "$build_cmd"
  else
    npm run "$build_cmd"
  fi

  local pkg_name tarball dest
  pkg_name=$(jq -r .name package.json)
  tarball=$(npm pack --json | jq -r '.[0].filename // empty')
  [[ -z "$tarball" ]] && tarball=$(npm pack | tail -n 1)

  if [[ -z "$tarball" || ! -f "$tarball" ]]; then
    echo "::error::npm pack failed for ${repo}"
    exit 1
  fi

  dest="${STACK_DIR}/tarballs/${repo}.tgz"
  cp "$tarball" "$dest"
  BUILT_TARBALLS+=("$dest")

  local npm_pkg MANIFEST_TMP
  npm_pkg="@processmaker/${NPM_NAMES[$repo]:-$repo}"
  MANIFEST_TMP=$(mktemp)
  jq --arg pkg "$npm_pkg" --arg repo "$repo" --arg path "tarballs/${repo}.tgz" --arg ref "$ref" \
    '. + {($pkg): {repo: $repo, ref: $ref, tarball: $path}}' "$MANIFEST" > "$MANIFEST_TMP"
  mv "$MANIFEST_TMP" "$MANIFEST"

  echo "Packed ${pkg_name} -> ${dest}"
  cd - >/dev/null
  rm -rf "$workdir"
}

for repo in "${FINAL_ORDER[@]}"; do
  [[ "$repo" == "processmaker" ]] && continue
  build_package "$repo"
done

echo "=== JS stack manifest ==="
cat "$MANIFEST"
