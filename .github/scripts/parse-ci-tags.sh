#!/usr/bin/env bash
# Parse ci:repo:branch tags from a PR body.
# Usage: parse-ci-tags.sh [body]
#        PR_BODY=... parse-ci-tags.sh
#        echo "$body" | parse-ci-tags.sh
# Prints a JSON object {"repo":"branch", ...}. Duplicate tags: last wins.
set -euo pipefail

body="${1:-}"
if [ -z "$body" ]; then
  if [ -n "${PR_BODY:-}" ]; then
    body="$PR_BODY"
  elif [ ! -t 0 ]; then
    body=$(cat)
  fi
fi

json='{}'
remaining="$body"
while [[ "$remaining" =~ ci:([^[:space:]:]+):([^[:space:]]+) ]]; do
  repo="${BASH_REMATCH[1]}"
  branch="${BASH_REMATCH[2]}"
  json=$(jq -c --arg k "$repo" --arg v "$branch" '. + {($k): $v}' <<<"$json")
  remaining="${remaining#*"ci:${repo}:${branch}"}"
done

echo "$json"
