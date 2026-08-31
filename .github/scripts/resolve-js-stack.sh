#!/usr/bin/env bash
# Plan which JS repos to rebuild and which branch each should use.
#
# Env:
#   PR_BODY            Pull request body (ci:repo:branch tags)
#   TRIGGER_REPO       GitHub repo name of the PR (e.g. screen-builder, processmaker)
#   TRIGGER_HEAD_REF   PR head branch or SHA
#   BASE_BRANCH        PR base branch (develop / release-*)
#   GRAPH_FILE         Optional path to js-stack-graph.json
#   GITHUB_OUTPUT      Optional Actions output file
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_FILE="${GRAPH_FILE:-$SCRIPT_DIR/../js-stack-graph.json}"
PARSE_CI_TAGS="${PARSE_CI_TAGS:-$SCRIPT_DIR/parse-ci-tags.sh}"

PR_BODY="${PR_BODY:-}"
TRIGGER_REPO="${TRIGGER_REPO:-}"
TRIGGER_HEAD_REF="${TRIGGER_HEAD_REF:-}"
BASE_BRANCH="${BASE_BRANCH:-develop}"

if [ ! -f "$GRAPH_FILE" ]; then
  echo "::error::JS stack graph not found: $GRAPH_FILE" >&2
  exit 1
fi

graph=$(jq -c '.' "$GRAPH_FILE")
nodes=$(jq -c 'keys' <<<"$graph")
ci_tags=$(PR_BODY="$PR_BODY" bash "$PARSE_CI_TAGS")

js_ci_tags=$(jq -c --argjson nodes "$nodes" '
  to_entries
  | map(select(.key as $k | $nodes | index($k) != null))
  | from_entries
' <<<"$ci_tags")

ignored=$(jq -r --argjson nodes "$nodes" '
  to_entries
  | map(select(.key as $k | $nodes | index($k) == null) | .key)
  | .[]
' <<<"$ci_tags")
if [ -n "$ignored" ]; then
  while IFS= read -r key; do
    echo "Ignoring non-JS ci tag: ci:${key}:..." >&2
  done <<<"$ignored"
fi

# rebuild_set: trigger (if JS) + tagged JS repos + transitive downstream
rebuild=$(jq -nc --argjson graph "$graph" --argjson js_ci "$js_ci_tags" --arg trigger "$TRIGGER_REPO" '
  def descendants($n):
    ($graph[$n] // []) as $kids
    | $kids + ($kids | map(descendants(.)) | add // []);
  ([
      (if $graph | has($trigger) then $trigger else empty end),
      ($js_ci | keys[])
    ] | unique) as $seeds
  | ($seeds + ($seeds | map(descendants(.)) | add // []) | unique)
')

# If both a screen-builder-path node and bpmn-moddle are present, include modeler.
rebuild=$(jq -c --argjson graph "$graph" '
  def ancestors_of_screen_builder:
    ["vue-multiselect", "vue-form-elements", "screen-builder"];
  . as $set
  | if ($set | index("processmaker-bpmn-moddle") != null)
      and (ancestors_of_screen_builder | map(. as $a | $set | index($a) != null) | any)
      and ($set | index("modeler") == null)
    then $set + ["modeler"]
    else $set
    end
' <<<"$rebuild")

has_js_stack=$(jq -r 'length > 0' <<<"$rebuild")

canonical_order='["vue-multiselect","vue-form-elements","processmaker-bpmn-moddle","screen-builder","modeler"]'

# Roots: rebuild nodes with no parent also in rebuild_set
roots=$(jq -nc --argjson graph "$graph" --argjson set "$rebuild" --argjson order "$canonical_order" '
  ($graph | to_entries
    | map(.key as $parent | .value[] | {parent: $parent, child: .})
  ) as $edges
  | $set
  | map(. as $n
      | select(
          [$edges[] | select(. as $e | $e.child == $n and ($set | index($e.parent) != null))] | length == 0
        )
    )
  | sort_by($order | index(.) // 99)
')

entry_repo=$(jq -r '.[0] // empty' <<<"$roots")

# Topological order of rebuild_set using canonical order
cascade_repos=$(jq -nc --argjson set "$rebuild" --argjson order "$canonical_order" '
  $order | map(select(. as $n | $set | index($n) != null))
')

branch_map=$(jq -nc \
  --argjson set "$rebuild" \
  --argjson js_ci "$js_ci_tags" \
  --arg trigger "$TRIGGER_REPO" \
  --arg head "$TRIGGER_HEAD_REF" \
  --arg base "$BASE_BRANCH" '
  $set | map({
    key: .,
    value: (
      if . == $trigger and $head != "" then $head
      elif $js_ci[.] != null then $js_ci[.]
      else $base
      end
    )
  }) | from_entries
')

stop_before=""
if [ "$has_js_stack" = "true" ] \
  && jq -ne --arg t "$TRIGGER_REPO" --argjson nodes "$nodes" '$nodes | index($t) != null' >/dev/null \
  && [ -n "$entry_repo" ] && [ "$entry_repo" != "$TRIGGER_REPO" ]; then
  stop_before="$TRIGGER_REPO"
fi

echo "has_js_stack=$has_js_stack"
echo "entry_repo=$entry_repo"
echo "stop_before=$stop_before"
echo "cascade_repos=$cascade_repos"
echo "branch_map=$branch_map"
echo "roots=$roots" >&2

write_output() {
  local key="$1"
  local value="$2"
  if [ -z "${GITHUB_OUTPUT:-}" ]; then
    return 0
  fi
  if [[ "$value" == *$'\n'* ]]; then
    {
      echo "${key}<<EOF"
      echo "$value"
      echo "EOF"
    } >> "$GITHUB_OUTPUT"
  else
    echo "${key}=${value}" >> "$GITHUB_OUTPUT"
  fi
}

write_output has_js_stack "$has_js_stack"
write_output entry_repo "$entry_repo"
write_output stop_before "$stop_before"
write_output cascade_repos "$cascade_repos"
write_output branch_map "$branch_map"
write_output trigger_repo "$TRIGGER_REPO"
write_output trigger_head_ref "$TRIGGER_HEAD_REF"
