#!/bin/bash
set -euo pipefail

# run-solve.sh — eval runner for the solve orchestrator
#
# Runs /openshift-developer:solve which internally chains:
#   implement → code-review → address-review-precommit
# all in a single Claude session.
#
# Produces output files for agent-eval-harness judges to evaluate.
# Does NOT push or create PRs.
#
# Called by the eval harness via runner.type: cli. The harness sets cwd to
# the case workspace which contains input.yaml and a pre-created output/ dir.
#
# Usage:
#   run-solve.sh <issue_key> <repo_url> <eval_branch> [model]
#
# Env vars:
#   AI_HELPERS_DIR  — path to ai-helpers checkout (default: auto-detect)
#   EVAL_REPO_DIR   — where to clone the target repo (default: ~/.cache/eval-solve.XXXXXX/repo)

ISSUE_KEY=${1:?"Usage: $0 <issue_key> <repo_url> <eval_branch> [model]"}
REPO_URL=${2:?"Usage: $0 <issue_key> <repo_url> <eval_branch> [model]"}
EVAL_BRANCH=${3:?"Usage: $0 <issue_key> <repo_url> <eval_branch> [model]"}
SKILL_MODEL=${4:-claude-opus-4-6}
AI_HELPERS_DIR=${AI_HELPERS_DIR:-$(cd "$(dirname "$0")/../../../.." && pwd)}

# The harness pre-creates output/ in the workspace (cwd)
WORKSPACE="$(pwd)"
OUTPUT_DIR="${WORKSPACE}/output"
REPO_DIR="${EVAL_REPO_DIR:-$(mktemp -d "${HOME}/.cache/eval-solve.XXXXXX")/repo}"

OPENSHIFT_DEV_PLUGIN="$AI_HELPERS_DIR/plugins/openshift-developer"
CODE_REVIEW_PLUGIN="$AI_HELPERS_DIR/plugins/code-review"

echo "=== Solve Eval: $ISSUE_KEY ==="
echo "Repo: $REPO_URL"
echo "Branch: $EVAL_BRANCH"
echo "Model: $SKILL_MODEL"
echo "Workspace: $WORKSPACE"
echo "Repo dir: $REPO_DIR"
echo "ai-helpers: $AI_HELPERS_DIR"

# Validate plugins
if [ ! -f "$OPENSHIFT_DEV_PLUGIN/skills/solve/SKILL.md" ]; then
  echo "ERROR: solve SKILL.md not found at $OPENSHIFT_DEV_PLUGIN/skills/solve/SKILL.md" >&2
  exit 1
fi
if [ ! -f "$OPENSHIFT_DEV_PLUGIN/skills/implement/SKILL.md" ]; then
  echo "ERROR: implement SKILL.md not found at $OPENSHIFT_DEV_PLUGIN/skills/implement/SKILL.md" >&2
  exit 1
fi

# Helper: extract token/cost JSON from stream-json output
extract_tokens() {
  local file=$1
  grep '"type":"result"' "$file" 2>/dev/null \
    | head -1 \
    | jq '{
        total_cost_usd: (.total_cost_usd // 0),
        duration_ms: (.duration_ms // 0),
        num_turns: (.num_turns // 0),
        input_tokens: (.usage.input_tokens // 0),
        output_tokens: (.usage.output_tokens // 0),
        cache_read_input_tokens: (.usage.cache_read_input_tokens // 0),
        cache_creation_input_tokens: (.usage.cache_creation_input_tokens // 0),
        model: ((.modelUsage // {} | keys | first) // "unknown")
      }' 2>/dev/null \
    || echo '{"total_cost_usd":0,"duration_ms":0,"num_turns":0,"input_tokens":0,"output_tokens":0,"model":"unknown"}'
}

# Helper: extract assistant text from stream-json
extract_text() {
  local file=$1
  jq -j 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' "$file" 2>/dev/null || true
}

# ── Verify tool dependencies ──
export PATH="${GOPATH:-$HOME/go}/bin:$HOME/.local/bin:$PATH"

# ── Setup: clone repo and prepare workspace ──
echo ""
echo "--- Setup ---"
rm -rf "$REPO_DIR"
git clone "$REPO_URL" "$REPO_DIR"
cd "$REPO_DIR"
git checkout "$EVAL_BRANCH"
BASE_SHA=$(git rev-parse HEAD)

git config user.name "Eval Runner"
git config user.email "eval@test.local"

NO_PUSH_CONTEXT="IMPORTANT: Do NOT create a Pull Request. Do NOT push to any remote. Just implement the changes, run tests, and commit to the local branch."

# ── Run solve orchestrator (single session) ──
echo ""
echo "=========================================="
echo "Running: /openshift-developer:solve ($ISSUE_KEY)"
echo "=========================================="

SOLVE_START=$(date +%s)

set +e
claude -p "/openshift-developer:solve ${ISSUE_KEY} origin --ci" \
  --plugin-dir "$OPENSHIFT_DEV_PLUGIN" \
  --plugin-dir "$CODE_REVIEW_PLUGIN" \
  --allowedTools "Bash Read Write Edit Grep Glob WebFetch Agent Skill Task" \
  --max-turns 500 \
  --effort max \
  --model "$SKILL_MODEL" \
  --output-format stream-json \
  --verbose \
  --append-system-prompt "$NO_PUSH_CONTEXT" \
  2>"$OUTPUT_DIR/solve-stderr.log" \
  | tee "$OUTPUT_DIR/solve-output.json"
SOLVE_EXIT=$?
set -e

SOLVE_END=$(date +%s)
echo "Solve duration: $((SOLVE_END - SOLVE_START))s (exit $SOLVE_EXIT)"

# ── Extract outputs ──
extract_tokens "$OUTPUT_DIR/solve-output.json" > "$OUTPUT_DIR/solve-tokens.json"
extract_text "$OUTPUT_DIR/solve-output.json" > "$OUTPUT_DIR/solve-text.txt"

# Capture diff (committed + uncommitted)
{ git diff "$BASE_SHA"..HEAD 2>/dev/null; git diff HEAD 2>/dev/null; } > "$OUTPUT_DIR/diff.patch"
{ git diff "$BASE_SHA"..HEAD --name-only 2>/dev/null; git diff HEAD --name-only 2>/dev/null; } | sort -u > "$OUTPUT_DIR/files-changed.txt"
git log --oneline "$BASE_SHA"..HEAD > "$OUTPUT_DIR/commit-log.txt"

echo "Final diff: $(wc -l < "$OUTPUT_DIR/diff.patch") lines"
echo "Files changed: $(wc -l < "$OUTPUT_DIR/files-changed.txt")"
echo "Commits: $(wc -l < "$OUTPUT_DIR/commit-log.txt")"

CHANGED_FILES=$(cat "$OUTPUT_DIR/files-changed.txt")

if [ -z "$CHANGED_FILES" ]; then
  echo "No code changes produced"
  touch "$OUTPUT_DIR/coverage.txt"
  echo "1" > "$OUTPUT_DIR/make-test-exit"
  echo "No code changes — make test not run" > "$OUTPUT_DIR/make-test.log"
  echo "1" > "$OUTPUT_DIR/make-verify-exit"
  echo "No code changes — make verify not run" > "$OUTPUT_DIR/make-verify.log"
  echo "=== Pipeline complete (no changes) ==="
  exit 0
fi

# Clean up skill workspace artifacts
rm -rf .work/ 2>/dev/null || true
git checkout -- .work/ 2>/dev/null || true
git clean -fd .work/ 2>/dev/null || true

# Run make test and make verify independently
echo ""
echo "Running make test..."
set +e
make test 2>&1 | tee "$OUTPUT_DIR/make-test.log"
echo $? > "$OUTPUT_DIR/make-test-exit"
echo "make test exit: $(cat "$OUTPUT_DIR/make-test-exit")"

echo "Running make verify..."
make verify 2>&1 | tee "$OUTPUT_DIR/make-verify.log"
echo $? > "$OUTPUT_DIR/make-verify-exit"
echo "make verify exit: $(cat "$OUTPUT_DIR/make-verify-exit")"
set -e

# Diff coverage
CHANGED_PKGS=$( { git diff "$BASE_SHA"..HEAD --name-only -- '*.go' 2>/dev/null; git diff HEAD --name-only -- '*.go' 2>/dev/null; } \
  | grep -v '_test.go$' \
  | xargs -I{} dirname {} 2>/dev/null \
  | sort -u \
  | sed 's|^|./|' || echo "")
if [ -n "$CHANGED_PKGS" ]; then
  echo "Running diff coverage for changed packages..."
  set +e
  go test -coverprofile="$OUTPUT_DIR/cover.out" $CHANGED_PKGS 2>&1 | tee "$OUTPUT_DIR/coverage-raw.txt"
  if command -v cov-diff >/dev/null 2>&1 && [ -f "$OUTPUT_DIR/cover.out" ]; then
    git diff "$BASE_SHA"..HEAD > "$OUTPUT_DIR/pr.diff"
    GO_MODULE=$(grep "^module " go.mod | awk '{print $2}')
    DIFF_COV=$(cov-diff -coverprofile "$OUTPUT_DIR/cover.out" -diff "$OUTPUT_DIR/pr.diff" -path . -module "$GO_MODULE" 2>/dev/null | sed -n 's/.*: \([0-9]*\)%.*/\1/p' || echo "")
    if [ -n "$DIFF_COV" ]; then
      echo "diff-coverage: ${DIFF_COV}% of changed lines covered" > "$OUTPUT_DIR/coverage.txt"
    else
      echo "diff-coverage: could not compute" > "$OUTPUT_DIR/coverage.txt"
      cat "$OUTPUT_DIR/coverage-raw.txt" >> "$OUTPUT_DIR/coverage.txt"
    fi
  else
    cp "$OUTPUT_DIR/coverage-raw.txt" "$OUTPUT_DIR/coverage.txt"
  fi
  set -e
else
  echo "no go source files changed" > "$OUTPUT_DIR/coverage.txt"
fi

# Write metrics.json for the eval harness (CLI runner contract)
jq '{
  token_usage: {input: .input_tokens, output: .output_tokens},
  cost_usd: .total_cost_usd,
  num_turns: .num_turns,
  model: .model
}' "$OUTPUT_DIR/solve-tokens.json" > "$OUTPUT_DIR/metrics.json" 2>/dev/null \
  || echo '{"cost_usd":0,"num_turns":0}' > "$OUTPUT_DIR/metrics.json"

# Fetch known-good PR diff for judge comparison
KNOWN_PR=$(grep 'known_good_pr' "${WORKSPACE}/input.yaml" 2>/dev/null | sed 's/.*: *//' | tr -d '"' || echo "")
if [ -n "$KNOWN_PR" ]; then
  echo "Fetching known-good PR diff: $KNOWN_PR"
  PR_NUM=$(echo "$KNOWN_PR" | grep -oE '[0-9]+$')
  PR_REPO=$(echo "$KNOWN_PR" | sed 's|https://github.com/||;s|/pull/.*||')
  set +e
  gh pr diff "$PR_NUM" --repo "$PR_REPO" > "$OUTPUT_DIR/known-good.patch" 2>/dev/null
  set -e
  if [ -s "$OUTPUT_DIR/known-good.patch" ]; then
    echo "Known-good PR diff: $(wc -l < "$OUTPUT_DIR/known-good.patch") lines"
  else
    echo "Could not fetch known-good PR diff"
    rm -f "$OUTPUT_DIR/known-good.patch"
  fi
fi

# Remove large files that would blow up {{ outputs }}
rm -f "$OUTPUT_DIR/solve-output.json" "$OUTPUT_DIR/solve-stderr.log"
rm -f "$OUTPUT_DIR/cover.out" "$OUTPUT_DIR/pr.diff" "$OUTPUT_DIR/coverage-raw.txt"
rm -f "$OUTPUT_DIR/make-test.log" "$OUTPUT_DIR/make-verify.log"

echo ""
echo "=== Pipeline complete ==="
echo "Cost: $(jq -r '.total_cost_usd' "$OUTPUT_DIR/solve-tokens.json") USD"
