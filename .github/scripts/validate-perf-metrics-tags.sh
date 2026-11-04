#!/usr/bin/env bash
# Validate ci:performance-tests:* label tokens in PR body against // @perf-labels:
# in k6 scripts under automated-performance-metrics/scripts. Optionally write
# perf-test-scripts.txt (all scripts whose @perf-labels intersect requested labels).
# Usage: PR_BODY='...' ./validate-perf-metrics-tags.sh <metrics-dir> [perf-test-scripts-outfile]
set -euo pipefail

METRICS_DIR="${1:?metrics directory required}"
OUTFILE="${2:-}"

REQUESTED=$(mktemp)
SCRIPTS_MAP=$(mktemp)
ALL_VALID_LABELS=$(mktemp)
trap 'rm -f "$REQUESTED" "$SCRIPTS_MAP" "$ALL_VALID_LABELS"' EXIT

# --- extract @perf-labels from first matching line in file; print space-separated labels ---
perf_labels_from_file() {
  local f="$1"
  local line after p L lbls=""
  line=$(grep -m1 -E '^[[:space:]]*//[[:space:]]*@perf-labels:' "$f" 2>/dev/null || true)
  [[ -z "$line" ]] && { printf '%s\n' ""; return; }
  after="${line#*@perf-labels:}"
  after="${after#"${after%%[![:space:]]*}"}"
  after="${after%${after##*[![:space:]]}}"
  IFS=',' read -ra parts <<<"$after"
  for p in "${parts[@]}"; do
    L="${p#"${p%%[![:space:]]*}"}"
    L="${L%${L##*[![:space:]]}}"
    [[ -n "$L" ]] && lbls+="${L} "
  done
  printf '%s' "${lbls%% }"
}

: >"$SCRIPTS_MAP"
: >"$ALL_VALID_LABELS"

while IFS= read -r -d '' f; do
  lbls=$(perf_labels_from_file "$f")
  printf '%s\t%s\n' "$f" "$lbls" >>"$SCRIPTS_MAP"
  for L in $lbls; do
    printf '%s\n' "$L" >>"$ALL_VALID_LABELS"
  done
done < <(find "$METRICS_DIR/scripts" -name '*.js' -type f -print0 2>/dev/null | sort -z)

if [[ ! -s "$SCRIPTS_MAP" ]]; then
  printf '%s\t%s\n' "${METRICS_DIR}/scripts/Api/users-index.js" "core" >>"$SCRIPTS_MAP"
  printf '%s\n' "core" >>"$ALL_VALID_LABELS"
fi

sort -u "$ALL_VALID_LABELS" -o "$ALL_VALID_LABELS"

: >"$REQUESTED"
while IFS= read -r line || [[ -n "${line:-}" ]]; do
  [[ "$line" != *ci:performance-tests* ]] && continue
  rest="${line#*ci:performance-tests}"
  rest="${rest#:}"
  rest="${rest#"${rest%%[![:space:]]*}"}"
  [[ -z "${rest// /}" ]] && continue
  rest=${rest//,/ }
  for tok in $rest; do
    [[ -z "$tok" ]] && continue
    printf '%s\n' "$tok" >>"$REQUESTED"
  done
done <<<"$(printf '%s\n' "${PR_BODY:-}" | tr '\r' '\n')"

sort -u "$REQUESTED" -o "$REQUESTED"

if [[ ! -s "$REQUESTED" ]]; then
  echo "No ci:performance-tests label filters in PR body; all discovered k6 scripts will run."
  if [[ -n "$OUTFILE" ]]; then
    find "$METRICS_DIR/scripts" -name '*.js' -type f | sort >"$OUTFILE"
    if [[ ! -s "$OUTFILE" ]]; then
      cut -f1 "$SCRIPTS_MAP" | head -1 >"$OUTFILE"
    fi
    echo "Wrote ${OUTFILE}:"
    cat "$OUTFILE"
  fi
  exit 0
fi

BAD=0
while IFS= read -r want || [[ -n "${want:-}" ]]; do
  [[ -z "$want" ]] && continue
  if ! grep -qxF "$want" "$ALL_VALID_LABELS" 2>/dev/null; then
    echo "::error::Unknown ci:performance-tests label '${want}'. No k6 script declares this in // @perf-labels: ..."
    echo -n "Declared labels across scripts: "
    tr '\n' ' ' <"$ALL_VALID_LABELS" | sed 's/[[:space:]]*$//'
    echo
    BAD=1
  fi
done <"$REQUESTED"

if [[ "$BAD" -ne 0 ]]; then
  exit 1
fi

if [[ -n "$OUTFILE" ]]; then
  : >"$OUTFILE"
  while IFS=$'\t' read -r filepath lbls; do
    [[ -z "$filepath" ]] && continue
    match=0
    while IFS= read -r want || [[ -n "${want:-}" ]]; do
      [[ -z "$want" ]] && continue
      for L in $lbls; do
        if [[ "$L" == "$want" ]]; then
          match=1
          break 2
        fi
      done
    done <"$REQUESTED"
    if [[ "$match" -eq 1 ]]; then
      printf '%s\n' "$filepath" >>"$OUTFILE"
    fi
  done <"$SCRIPTS_MAP"
  sort -u "$OUTFILE" -o "$OUTFILE"
  if [[ ! -s "$OUTFILE" ]]; then
    echo "::error::No k6 scripts matched the requested // @perf-labels: filters."
    exit 1
  fi
  echo "Filtered k6 tests (${OUTFILE}) by @perf-labels:"
  cat "$OUTFILE"
fi

exit 0
