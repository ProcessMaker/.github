#!/usr/bin/env bash
# Assert resolve-js-stack.sh output for the CI-tag plan scenarios.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="$SCRIPT_DIR/resolve-js-stack.sh"
failed=0

assert_kv() {
  local output="$1" key="$2" expected="$3"
  local actual
  actual=$(grep "^${key}=" <<<"$output" | head -n1 | cut -d= -f2-)
  if [ "$actual" != "$expected" ]; then
    echo "FAIL $key: expected ${expected} got ${actual}"
    failed=1
  else
    echo "OK   $key=$actual"
  fi
}

run_case() {
  local name="$1"
  echo ""
  echo "== $name =="
}

output_of() {
  PR_BODY="$1" TRIGGER_REPO="$2" TRIGGER_HEAD_REF="$3" BASE_BRANCH="$4" bash "$RESOLVE" 2>/dev/null
}

run_case "1 screen-builder PR, no ci tags"
out=$(output_of '' screen-builder my-pr develop)
assert_kv "$out" has_js_stack true
assert_kv "$out" entry_repo screen-builder
assert_kv "$out" stop_before ''
assert_kv "$out" cascade_repos '["screen-builder","modeler"]'
assert_kv "$out" branch_map '{"modeler":"develop","screen-builder":"my-pr"}'

run_case "2 screen-builder PR + ci:modeler:feat-x"
out=$(output_of 'ci:modeler:feat-x' screen-builder my-pr develop)
assert_kv "$out" has_js_stack true
assert_kv "$out" entry_repo screen-builder
assert_kv "$out" stop_before ''
assert_kv "$out" branch_map '{"modeler":"feat-x","screen-builder":"my-pr"}'

run_case "3 screen-builder PR + ci:vue-form-elements:feat-x"
out=$(output_of 'ci:vue-form-elements:feat-x' screen-builder my-pr develop)
assert_kv "$out" has_js_stack true
assert_kv "$out" entry_repo vue-form-elements
assert_kv "$out" stop_before screen-builder
assert_kv "$out" cascade_repos '["vue-form-elements","screen-builder","modeler"]'
assert_kv "$out" branch_map '{"modeler":"develop","screen-builder":"my-pr","vue-form-elements":"feat-x"}'

run_case "4 processmaker PR + ci:vue-form-elements:feat-x"
out=$(output_of 'ci:vue-form-elements:feat-x' processmaker pm-pr develop)
assert_kv "$out" has_js_stack true
assert_kv "$out" entry_repo vue-form-elements
assert_kv "$out" stop_before ''
assert_kv "$out" cascade_repos '["vue-form-elements","screen-builder","modeler"]'
assert_kv "$out" branch_map '{"modeler":"develop","screen-builder":"develop","vue-form-elements":"feat-x"}'

run_case "5 processmaker PR + three JS tags"
out=$(output_of 'ci:vue-form-elements:a ci:screen-builder:b ci:modeler:c' processmaker pm-pr develop)
assert_kv "$out" has_js_stack true
assert_kv "$out" entry_repo vue-form-elements
assert_kv "$out" stop_before ''
assert_kv "$out" branch_map '{"modeler":"c","screen-builder":"b","vue-form-elements":"a"}'

run_case "6 processmaker PR, no JS ci tags"
out=$(output_of 'ci:deploy please' processmaker pm-pr develop)
assert_kv "$out" has_js_stack false
assert_kv "$out" entry_repo ''
assert_kv "$out" cascade_repos '[]'
assert_kv "$out" branch_map '{}'

run_case "7 processmaker PR + ci:processmaker-bpmn-moddle:x"
out=$(output_of 'ci:processmaker-bpmn-moddle:x' processmaker pm-pr develop)
assert_kv "$out" has_js_stack true
assert_kv "$out" entry_repo processmaker-bpmn-moddle
assert_kv "$out" stop_before ''
assert_kv "$out" cascade_repos '["processmaker-bpmn-moddle","modeler"]'
assert_kv "$out" branch_map '{"modeler":"develop","processmaker-bpmn-moddle":"x"}'

echo ""
if [ "$failed" -ne 0 ]; then
  echo "Some assertions failed"
  exit 1
fi
echo "All resolve-js-stack scenarios passed"
