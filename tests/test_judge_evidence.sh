#!/usr/bin/env bash
# Regression tests for immutable round bases and judge evidence packaging.
#
# Run: bash tests/test_judge_evidence.sh

set -uo pipefail
WTCOP="$(cd "$(dirname "$0")/.." && pwd)/wtcp"
PASS=0; FAIL=0
fail(){ echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
pass(){ echo "  PASS: $*"; PASS=$((PASS+1)); }
has(){ # $1=label $2=needle $3=haystack
  case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (missing '$2')" ;; esac
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

extract_fn(){ # $1 = function name -> print its definition (header line ... closing brace)
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\)" { print; in_fn=1; next }
    in_fn && /^}$/ { print; exit }
    in_fn { print }
  ' "$WTCOP"
}

{
  echo 'COCKPIT_JUDGE_DIFF_CHARS=3200'
  echo 'COCKPIT_JUDGE_OUTPUT_CHARS=3200'
  echo '_workmux_main_branch(){ printf master; }'
  for f in _round_base_commit _diff_base _wt_file_patch _wt_evidence _wt_diff \
           _judge_output_budget _terminal_evidence _judge_rubric _rubric_response_normalize \
           _rubric_response_valid \
           _rubric_error_summary _judge_error_excerpt _judge_rejection_detail \
           _judge_single_max_tokens _judge_compare_max_tokens _judge_repair_request \
           _judge_invalid_file _judge_invalid_prev_file _rotate_invalid_judgments \
           _record_invalid_judgment; do
    extract_fn "$f"
  done
} > "$TMP/functions.sh"
# shellcheck disable=SC1090
. "$TMP/functions.sh" || { echo "could not extract functions from wtcp"; exit 2; }

REPO="$TMP/repo"; WT="$TMP/candidate"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
mkdir -p "$REPO/src"
printf '{"name":"fixture-agentdeck"}\n' > "$REPO/package.json"
printf 'export const price = (n: number) => n * 2;\n' > "$REPO/src/product.ts"
printf 'seed\n' > "$REPO/aaa-large.md"
git -C "$REPO" add .
git -C "$REPO" commit -qm base
git -C "$REPO" branch -M master

# Capture the same immutable value _run_round stores, then advance master.
BASE_SHA=$(cd "$REPO" && _round_base_commit master)
git -C "$REPO" worktree add -q -b candidate "$WT" "$BASE_SHA"
printf 'main moved after round launch\n' > "$REPO/master-only.txt"
git -C "$REPO" add master-only.txt
git -C "$REPO" commit -qm 'advance master'

echo "T1: immutable round base"
case "$BASE_SHA" in
  [0-9a-f][0-9a-f]*) pass "base resolves to a commit SHA" ;;
  *) fail "base resolves to a commit SHA (got '$BASE_SHA')" ;;
esac
if [ "$BASE_SHA" != "$(git -C "$REPO" rev-parse master)" ]; then
  pass "saved base does not move with master"
else
  fail "saved base does not move with master"
fi
has "workmux launch receives immutable base" 'addargs+=(--base "$round_base_commit")' "$(<"$WTCOP")"
has "tmux stores immutable base" '@cockpit_base "$round_base_commit"' "$(<"$WTCOP")"

# One large tracked edit used to consume the entire leading head -c budget.
awk 'BEGIN { for (i=0; i<700; i++) print "large tracked change line " i }' > "$WT/aaa-large.md"
mkdir -p "$WT/tests"
{
  printf "import { price } from '../src/product';\n"
  printf "test('uses product module', () => expect(price(21)).toBe(42));\n"
  printf "// COMMITTED_TEST_MARKER\n"
} > "$WT/tests/product.test.ts"
git -C "$WT" add tests/product.test.ts
git -C "$WT" commit -qm 'add committed product test'
{
  printf "import { price } from '../src/product';\n"
  printf "test('untracked product behavior', () => expect(price(3)).toBe(6));\n"
  printf "// UNTRACKED_TEST_MARKER\n"
} > "$WT/tests/pricing.test.ts"

EVIDENCE=$(_wt_evidence "$WT" "$BASE_SHA" 3200)

echo "T2: manifest precedes balanced patches"
has "manifest is present" "=== EVIDENCE MANIFEST (before patch excerpts) ===" "$EVIDENCE"
has "canonical repository identity is present" "Canonical repository: repo" "$EVIDENCE"
has "package identity is present" "Package name: fixture-agentdeck" "$EVIDENCE"
has "tracked/test counts are present" "Tracked files:" "$EVIDENCE"
has "complete top-level entries are present" "package.json" "$EVIDENCE"
has "status includes untracked test" "?? tests/pricing.test.ts" "$EVIDENCE"
has "complete list includes large tracked file" $'tracked\taaa-large.md' "$EVIDENCE"
has "complete list includes committed new test" $'tracked\ttests/product.test.ts' "$EVIDENCE"
has "complete list includes untracked new test" $'untracked\ttests/pricing.test.ts' "$EVIDENCE"
has "numstat marks untracked file" "tests/pricing.test.ts [untracked]" "$EVIDENCE"
has "base SHA is reported" "Base commit: $BASE_SHA" "$EVIDENCE"
case "$EVIDENCE" in
  *master-only.txt*) fail "moving master does not pollute candidate evidence" ;;
  *) pass "moving master does not pollute candidate evidence" ;;
esac

echo "T3: test evidence survives a small budget"
has "committed new test patch is included" "FILE PATCH: tests/product.test.ts" "$EVIDENCE"
has "untracked new test patch is included" "FILE PATCH: tests/pricing.test.ts" "$EVIDENCE"
has "test's production import is visible" "import { price } from '../src/product'" "$EVIDENCE"
has "committed test body is visible" "COMMITTED_TEST_MARKER" "$EVIDENCE"
has "large tracked file also receives a slice" "FILE PATCH: aaa-large.md" "$EVIDENCE"

echo "T4: truncation is explicit"
has "truncation flag" "TRUNCATED: yes" "$EVIDENCE"
has "total and delivered counts" "Diff content characters: total " "$EVIDENCE"
has "partially omitted filename is named" "aaa-large.md (sent " "$EVIDENCE"

echo "T5: judge policy and comparative call"
has "single judge treats pass count as a gate" "a green pass count is a gate" "$(<"$WTCOP")"
has "judge checks real product modules" "exercise real product modules" "$(<"$WTCOP")"
if grep -Fq '_wt_diff "$path" "$base" | head -c "$per"' "$WTCOP"; then
  fail "comparative path no longer applies leading head -c"
else
  pass "comparative path no longer applies leading head -c"
fi
has "comparative path uses combined per-agent pool" 'COCKPIT_JUDGE_COMPARE_CHARS / nag' "$(<"$WTCOP")"
has "unused change budget flows to terminal" '_judge_output_budget "$combined_per" "$diff_chars"' "$(<"$WTCOP")"
if grep -Fq 'capture-pane -p -S - -t "${panes[i]}" 2>/dev/null | tail -c' "$WTCOP"; then
  fail "comparative path no longer tail-caps raw terminal"
else
  pass "comparative path no longer tail-caps raw terminal"
fi
has "analysis task forbids empty-diff deduction" "Never deduct points or add an Improve bullet merely because such a response has no Diff" "$(<"$WTCOP")"
has "subagent provenance is not penalized" "Using subagents is not a weakness" "$(<"$WTCOP")"
has "conflicting facts create uncertainty" "conflicting factual or numeric claims" "$(<"$WTCOP")"
has "fresh score option exists" 'if [ "${1:-}" = "--fresh" ]' "$(<"$WTCOP")"
has "fresh score removes previous labels" 'prev_labels+=(""); prev_reasons+=("")' "$(<"$WTCOP")"
has "review menu exposes fresh score" 'Run fresh judge (ignore prior)' "$(<"$WTCOP")"

echo "T6: dynamic terminal budget"
is_budget=$(_judge_output_budget 16000 500 800)
[ "$is_budget" = 15500 ] && pass "unused diff budget is returned" || fail "unused diff budget is returned (got $is_budget)"
is_budget=$(_judge_output_budget 16000 9000 800)
[ "$is_budget" = 7000 ] && pass "substantive diff keeps remaining output budget" || fail "substantive diff keeps remaining output budget (got $is_budget)"
is_budget=$(_judge_output_budget 16000 17000 800)
[ "$is_budget" = 800 ] && pass "terminal retains a minimum budget" || fail "terminal retains a minimum budget (got $is_budget)"

TERM_FIXTURE="$TMP/terminal.txt"
{
  printf 'HEAD_MARKER first findings\n'
  awk 'BEGIN { for (i=1; i<=120; i++) print "terminal evidence line " i " xxxxxxxxxxxxxxxxxxxx" }'
  printf 'MIDDLE_MARKER should be omitted\n'
  awk 'BEGIN { for (i=121; i<=240; i++) print "terminal evidence line " i " yyyyyyyyyyyyyyyyyyyy" }'
  printf 'TAIL_MARKER final conclusion\n'
} > "$TERM_FIXTURE"
tmux(){ [ "$1" = capture-pane ] && cat "$TERM_FIXTURE"; }
TERM_EVIDENCE=$(_terminal_evidence "%1" 1800)
has "terminal truncation is explicit" "TRUNCATED: yes" "$TERM_EVIDENCE"
has "terminal head survives" "HEAD_MARKER" "$TERM_EVIDENCE"
has "terminal tail survives" "TAIL_MARKER" "$TERM_EVIDENCE"
case "$TERM_EVIDENCE" in
  *MIDDLE_MARKER*) fail "terminal middle is actually omitted" ;;
  *) pass "terminal middle is actually omitted" ;;
esac

printf 'SHORT_HEAD\nSHORT_TAIL\n\n\n' > "$TERM_FIXTURE"
TERM_EVIDENCE=$(_terminal_evidence "%1" 1800)
has "short terminal is complete" "TRUNCATED: no" "$TERM_EVIDENCE"
has "short terminal tail survives" "SHORT_TAIL" "$TERM_EVIDENCE"

echo "T7: canonical rubric and response validation"
RUBRIC=$(_judge_rubric)
has "rubric defines 4-point task dimension" "Task fulfillment and correctness — 0..4" "$RUBRIC"
has "rubric defines 3-point grounding dimension" "Evidence grounding and repository identity — 0..3" "$RUBRIC"
has "rubric defines 2-point verification dimension" "Verification and reasoning quality — 0..2" "$RUBRIC"
has "rubric defines 1-point actionability dimension" "Actionability, scope, and clarity — 0..1" "$RUBRIC"
has "wrong repository hard gate is explicit" "wrong_repository:" "$RUBRIC"
has "wrong repository score cap is explicit" "final score <= 2" "$RUBRIC"
has "absolute scores precede comparison" "absolute score first; comparison second" "$RUBRIC"
has "rubric requires auditable cap IDs" "output caps array" "$RUBRIC"
has "rubric keeps dimensions orthogonal" "Do not deduct the same underlying weakness in two dimensions" "$RUBRIC"
has "rubric rejects comparative-only deductions" '"less detailed than the winner" is not an absolute-rubric deduction' "$RUBRIC"
has "rubric defines direct evidence narrowly" "agent-authored conclusion" "$RUBRIC"
has "rubric makes ten exceptional" "Score 10 is exceptional" "$RUBRIC"
has "unverified facts do not reduce task" "affects Grounding and/or Verification, not Task" "$RUBRIC"
has "optional implementation offer is not penalized" "brief optional offer to implement next steps" "$RUBRIC"
has "timeline alone defines user requirements" "Instruction timeline is the only authoritative user specification" "$RUBRIC"

with_audit(){
  jq -c '
    def audited:
      . + {
        evidence_level: "direct",
        dimension_reasons: {
          task: "task rationale",
          grounding: "grounding rationale",
          verification: "verification rationale",
          actionability: "actionability rationale"
        },
        dimension_issue_ids: {
          task: (if .breakdown.task < 4 then "task_gap" else "none" end),
          grounding: (if .breakdown.grounding < 3 then "grounding_gap" else "none" end),
          verification: (if .breakdown.verification < 2 then "verification_gap" else "none" end),
          actionability: (if .breakdown.actionability < 1 then "actionability_gap" else "none" end)
        },
        strength: "specific strength",
        deduction: (
          if (.breakdown.task == 4 and .breakdown.grounding == 3
              and .breakdown.verification == 2 and .breakdown.actionability == 1)
          then "None"
          else "specific deduction"
          end
        ),
        improve_dimension: (
          if .breakdown.task < 4 then "task"
          elif .breakdown.grounding < 3 then "grounding"
          elif .breakdown.verification < 2 then "verification"
          elif .breakdown.actionability < 1 then "actionability"
          else "none"
          end
        ),
        improve: (
          if (.breakdown.task == 4 and .breakdown.grounding == 3
              and .breakdown.verification == 2 and .breakdown.actionability == 1)
          then "None"
          else "specific improvement"
          end
        )
      };
    if has("rankings") then
      .rankings |= map(audited)
      | . + {
          winner_reason: "winner has the strongest top-score evidence",
          tie_break: "winner has a more useful distinguishing strength",
          summary: "concise comparison without generalized weaknesses"
        }
    else audited
    end
  '
}
GOOD_SINGLE=$(printf '%s' '{"score":9,"breakdown":{"task":4,"grounding":3,"verification":1,"actionability":1},"caps":[],"reason":"ok"}' | with_audit)
BAD_SUM=$(printf '%s' '{"score":9,"breakdown":{"task":4,"grounding":2,"verification":1,"actionability":1},"caps":[],"reason":"bad"}' | with_audit)
BAD_CAP=$(printf '%s' '{"score":9,"breakdown":{"task":4,"grounding":3,"verification":1,"actionability":1},"caps":["made_up_cap"],"reason":"bad"}' | with_audit)
BAD_CAP_LIMIT=$(printf '%s' '{"score":8,"breakdown":{"task":4,"grounding":2,"verification":1,"actionability":1},"caps":["fabricated_evidence"],"reason":"bad"}' \
  | with_audit | jq -c '.dimension_issue_ids.task = "fabricated_evidence_task"')
BAD_WRONG_REPO_GROUNDING=$(printf '%s' '{"score":2,"breakdown":{"task":1,"grounding":1,"verification":0,"actionability":0},"caps":["wrong_repository"],"reason":"bad"}' | with_audit)
NO_SCORE=$(printf '%s' '{"breakdown":{"task":3,"grounding":2,"verification":1,"actionability":1},"caps":[],"reason":"computed"}' | with_audit)
MISSING_AUDIT='{"breakdown":{"task":3,"grounding":2,"verification":1,"actionability":1},"caps":[],"reason":"missing"}'
printf '%s' "$GOOD_SINGLE" | _rubric_response_valid 0 \
  && pass "valid single breakdown accepted" || fail "valid single breakdown accepted"
printf '%s' "$BAD_CAP" | _rubric_response_valid 0 \
  && fail "unknown cap ID rejected" || pass "unknown cap ID rejected"
printf '%s' "$NO_SCORE" | _rubric_response_valid 0 \
  && pass "model score field is not required" || fail "model score field is not required"
printf '%s' "$MISSING_AUDIT" | _rubric_response_valid 0 \
  && fail "evidence level and dimension reasons are required" || pass "evidence level and dimension reasons are required"
FULL_DIM_IMPROVE=$(printf '%s' '{"breakdown":{"task":4,"grounding":3,"verification":2,"actionability":1},"caps":[]}' \
  | with_audit \
  | jq -c '.improve_dimension = "actionability" | .improve = "raise an already maxed dimension"')
printf '%s' "$FULL_DIM_IMPROVE" | _rubric_response_valid 0 \
  && fail "improvement cannot target a full-credit dimension" || pass "improvement cannot target a full-credit dimension"
STRAY_FULL_ID=$(printf '%s' '{"breakdown":{"task":4,"grounding":3,"verification":2,"actionability":1},"caps":[]}' \
  | with_audit | jq -c '.dimension_issue_ids.verification = "stale_verification_issue"')
NORMALIZED=$(printf '%s' "$STRAY_FULL_ID" | _rubric_response_normalize 0)
[ "$(printf '%s' "$NORMALIZED" | jq -r '.dimension_issue_ids.verification')" = none ] \
  && pass "full-credit dimension issue ID is cleared" || fail "full-credit dimension issue ID is cleared"
NONE_DEDUCTION=$(printf '%s' "$GOOD_SINGLE" | jq -c '.deduction = "None"')
printf '%s' "$NONE_DEDUCTION" | _rubric_response_valid 0 \
  && fail "sub-ten score cannot claim no deduction" || pass "sub-ten score cannot claim no deduction"
DUPLICATE_ISSUE=$(printf '%s' '{"breakdown":{"task":3,"grounding":3,"verification":1,"actionability":1},"caps":[]}' \
  | with_audit \
  | jq -c '.dimension_issue_ids.task = "same_issue" | .dimension_issue_ids.verification = "same_issue"')
# Rejecting a double-charge costs the round: told exactly which IDs collide, the
# judge resends the identical record and the fallback scores far worse. Record it
# instead — namespaced per dimension, with the shared root cause called out.
DEDUPED=$(printf '%s' "$DUPLICATE_ISSUE" | _rubric_response_normalize 0)
[ -n "$DEDUPED" ] \
  && pass "a double-charged issue no longer kills the round" || fail "a double-charged issue no longer kills the round"
[ "$(printf '%s' "$DEDUPED" | jq -r '.dimension_issue_ids.task')" = "same_issue_task" ] \
  && pass "double-charged issue IDs are namespaced per dimension" || fail "double-charged issue IDs are namespaced per dimension"
[ "$(printf '%s' "$DEDUPED" | jq -r '.dimension_issue_ids.verification')" = "same_issue_verification" ] \
  && pass "every colliding dimension gets its own namespaced id" || fail "every colliding dimension gets its own namespaced id"
has "the shared root cause stays visible in the report" "charged in several dimensions" \
  "$(printf '%s' "$DEDUPED" | jq -r '.normalization_notes | join(" ")')"
MISPLACED_TASK=$(printf '%s' "$NO_SCORE" \
  | jq -c '.dimension_issue_ids.task = "unverified_documentation_claim"
    | .improve_dimension = "grounding" | .improve = "show direct evidence"')
NORMALIZED_TASK=$(printf '%s' "$MISPLACED_TASK" | _rubric_response_normalize 0)
[ "$(printf '%s' "$NORMALIZED_TASK" | jq -r '.breakdown.task')" = 4 ] \
  && pass "evidence-only concern cannot lower Task" || fail "evidence-only concern cannot lower Task"
has "Task reallocation is auditable" "Removed evidence/comparison-only Task deduction" "$NORMALIZED_TASK"
REAL_TASK_GAP=$(printf '%s' "$NO_SCORE" \
  | jq -c '.dimension_issue_ids.task = "missing_ci_analysis"')
printf '%s' "$REAL_TASK_GAP" | _rubric_response_valid 0 \
  && pass "concrete missing requirement can lower Task" || fail "concrete missing requirement can lower Task"
MIXED_WITHOUT_ID=$(printf '%s' '{"breakdown":{"task":4,"grounding":3,"verification":2,"actionability":1},"caps":[]}' \
  | with_audit | jq -c '.evidence_level = "mixed"
    | .deduction = "some central evidence is indirect"
    | .improve_dimension = "grounding"
    | .improve = "show direct primary evidence"')
NORMALIZED_MIXED_ID=$(printf '%s' "$MIXED_WITHOUT_ID" | _rubric_response_normalize 0)
has "evidence cap creates an auditable Grounding issue" "mixed_primary_evidence_grounding" "$NORMALIZED_MIXED_ID"
NORMALIZED=$(printf '%s' "$BAD_SUM" | _rubric_response_normalize 0)
[ "$(printf '%s' "$NORMALIZED" | jq -r '.score')" = 8 ] \
  && pass "wtcp computes score from breakdown" || fail "wtcp computes score from breakdown"
NORMALIZED=$(printf '%s' "$BAD_CAP_LIMIT" | _rubric_response_normalize 0)
[ "$(printf '%s' "$NORMALIZED" | jq -r '.score')" = 4 ] \
  && pass "declared cap maximum is enforced deterministically" || fail "declared cap maximum is enforced deterministically"
[ "$(printf '%s' "$NORMALIZED" | jq -r '[.breakdown[]] | add')" = 4 ] \
  && pass "cap-adjusted breakdown still sums to score" || fail "cap-adjusted breakdown still sums to score"
NORMALIZED=$(printf '%s' "$BAD_WRONG_REPO_GROUNDING" | _rubric_response_normalize 0)
[ "$(printf '%s' "$NORMALIZED" | jq -r '.breakdown.grounding')" = 0 ] \
  && pass "wrong-repository cap forces grounding zero" || fail "wrong-repository cap forces grounding zero"

GOOD_COMPARE=$(printf '%s' '{"rankings":[{"name":"a","score":10,"breakdown":{"task":4,"grounding":3,"verification":2,"actionability":1},"caps":[]},{"name":"b","score":2,"breakdown":{"task":1,"grounding":0,"verification":0,"actionability":1},"caps":["wrong_repository"]}],"winner":"a"}' | with_audit)
BAD_WINNER=$(printf '%s' '{"rankings":[{"name":"a","score":10,"breakdown":{"task":4,"grounding":3,"verification":2,"actionability":1},"caps":[]},{"name":"b","score":2,"breakdown":{"task":1,"grounding":0,"verification":0,"actionability":1},"caps":["wrong_repository"]}],"winner":"missing"}' | with_audit)
LOW_WINNER=$(printf '%s' '{"rankings":[{"name":"a","breakdown":{"task":4,"grounding":3,"verification":2,"actionability":1},"caps":[]},{"name":"b","breakdown":{"task":1,"grounding":0,"verification":0,"actionability":1},"caps":["wrong_repository"]}],"winner":"b"}' | with_audit)
printf '%s' "$GOOD_COMPARE" | _rubric_response_valid 2 \
  && pass "valid comparative breakdowns accepted" || fail "valid comparative breakdowns accepted"
printf '%s' "$GOOD_COMPARE" | _rubric_response_valid 2 '["a","b"]' \
  && pass "exact candidate names accepted" || fail "exact candidate names accepted"
printf '%s' "$GOOD_COMPARE" | _rubric_response_valid 2 '["a","invented"]' \
  && fail "invented or omitted candidate names rejected" || pass "invented or omitted candidate names rejected"
printf '%s' "$BAD_WINNER" | _rubric_response_valid 2 \
  && fail "winner outside rankings rejected" || pass "winner outside rankings rejected"
printf '%s' "$LOW_WINNER" | _rubric_response_valid 2 \
  && fail "winner below the top absolute score rejected" || pass "winner below the top absolute score rejected"
TIED_NO_REASON=$(printf '%s' '{"rankings":[{"name":"a","breakdown":{"task":4,"grounding":3,"verification":1,"actionability":1},"caps":[]},{"name":"b","breakdown":{"task":4,"grounding":3,"verification":1,"actionability":1},"caps":[]}],"winner":"a"}' \
  | with_audit | jq -c '.tie_break = "not_needed"')
NORMALIZED_TIE=$(printf '%s' "$TIED_NO_REASON" | _rubric_response_normalize 2)
has "post-normalization tie gets explicit judge-preference note" "Top absolute scores are tied" "$NORMALIZED_TIE"
COPIED_SUMMARY=$(printf '%s' "$GOOD_COMPARE" | jq -c '.summary = .winner_reason')
printf '%s' "$COPIED_SUMMARY" | _rubric_response_valid 2 \
  && pass "duplicate summary remains structurally valid" || fail "duplicate summary remains structurally valid"
has "duplicate summary is omitted from report" '.summary != .winner_reason' "$(<"$WTCOP")"

CAP_SHARED_IDS=$(printf '%s' '{"breakdown":{"task":0,"grounding":0,"verification":0,"actionability":0},"evidence_level":"narrative_only","dimension_reasons":{"task":"wrong repo","grounding":"wrong repo","verification":"wrong repo","actionability":"wrong repo"},"dimension_issue_ids":{"task":"wrong_repository_analyzed","grounding":"wrong_repository_analyzed","verification":"wrong_repository_analyzed","actionability":"wrong_repository_analyzed"},"caps":["wrong_repository"],"strength":"acknowledged error","deduction":"wrong repository invalidates the work","improve_dimension":"task","improve":"analyze the correct repository"}')
NORMALIZED_CAP=$(printf '%s' "$CAP_SHARED_IDS" | _rubric_response_normalize 0)
[ "$(printf '%s' "$NORMALIZED_CAP" | jq -r '[.dimension_issue_ids[]] | unique | length')" = 4 ] \
  && pass "shared hard-cap ID is namespaced per dimension" || fail "shared hard-cap ID is namespaced per dimension"

# Fixture matching the real Qwen failure: every explicit score disagreed with
# its otherwise-valid breakdown. This must normalize without a retry/fallback.
MODEL_MATH_COMPARE=$(printf '%s' '{"rankings":[{"name":"opencode","score":9,"breakdown":{"task":4,"grounding":3,"verification":2,"actionability":1},"caps":[]},{"name":"claude","score":8,"breakdown":{"task":4,"grounding":3,"verification":1,"actionability":1},"caps":[]},{"name":"agy","score":1,"breakdown":{"task":0,"grounding":0,"verification":0,"actionability":0},"caps":["wrong_repository"]}],"winner":"opencode"}' \
  | with_audit \
  | jq -c '.rankings[0].evidence_level = "mixed"
    | .rankings[0].dimension_issue_ids.grounding = "mixed_evidence"
    | .rankings[0].deduction = "some claims lack direct evidence"
    | .rankings[0].improve_dimension = "grounding"
    | .rankings[0].improve = "show direct evidence for the unverified claims"
    | .rankings[1].evidence_level = "mixed"
    | .rankings[1].dimension_issue_ids.grounding = "mixed_evidence"')
NORMALIZED_COMPARE=$(printf '%s' "$MODEL_MATH_COMPARE" | _rubric_response_normalize 3 '["opencode","claude","agy"]')
[ "$(printf '%s' "$NORMALIZED_COMPARE" | jq -r '[.rankings[].score] | join(",")')" = "9,8,0" ] \
  && pass "real Qwen score mismatches and mixed evidence normalize" || fail "real Qwen score mismatches and mixed evidence normalize"
has "mixed evidence cap is auditable" "mixed_primary_evidence" "$NORMALIZED_COMPARE"
[ "$(printf '%s' "$NORMALIZED_COMPARE" | jq -r '.rankings[] | select(.name=="opencode") | .breakdown.grounding')" = 2 ] \
  && pass "mixed evidence cannot retain grounding three" || fail "mixed evidence cannot retain grounding three"
NARRATIVE=$(printf '%s' '{"breakdown":{"task":4,"grounding":3,"verification":2,"actionability":1},"caps":[],"reason":"narrative"}' \
  | with_audit | jq -c '.evidence_level = "narrative_only"
    | .dimension_issue_ids.grounding = "narrative_evidence"
    | .deduction = "central claims lack primary evidence"
    | .improve_dimension = "grounding"
    | .improve = "show primary evidence"')
NORMALIZED=$(printf '%s' "$NARRATIVE" | _rubric_response_normalize 0)
[ "$(printf '%s' "$NORMALIZED" | jq -r '.breakdown.grounding')" = 1 ] \
  && pass "narrative-only evidence caps grounding at one" || fail "narrative-only evidence caps grounding at one"
[ "$(printf '%s' "$NORMALIZED" | jq -r '.score')" = 8 ] \
  && pass "narrative-only evidence caps total at eight" || fail "narrative-only evidence caps total at eight"
has "judge report renders rubric breakdown" 'Rubric: Task \(.breakdown.task)/4' "$(<"$WTCOP")"
has "judge report renders applied caps" 'def caps: "  Caps: "' "$(<"$WTCOP")"
has "judge report renders deterministic adjustments" 'def adjustments: "  Adjustments: "' "$(<"$WTCOP")"
has "judge report renders evidence level" 'def evidence: "  Evidence: \(.evidence_level)"' "$(<"$WTCOP")"
has "judge report renders dimension reasons" "Dimension reasons:" "$(<"$WTCOP")"
has "judge report renders dimension issue IDs" 'Task [\(.dimension_issue_ids.task)]' "$(<"$WTCOP")"
has "judge report renders winner rationale" "Winner rationale:" "$(<"$WTCOP")"
has "judge report renders explicit tie-break" "Tie-break:" "$(<"$WTCOP")"
has "judge report maps improve to a dimension" 'Improve [\(.improve_dimension)]' "$(<"$WTCOP")"

echo "T8: bounded output and one-shot JSON repair"
[ "$(_judge_single_max_tokens)" = 1000 ] \
  && pass "single response budget accommodates rubric JSON" || fail "single response budget accommodates rubric JSON"
[ "$(_judge_compare_max_tokens 3)" = 2000 ] \
  && pass "three-agent response budget scales per candidate" || fail "three-agent response budget scales per candidate"
[ "$(_judge_compare_max_tokens 6)" = 3500 ] \
  && pass "six-agent response budget scales per candidate" || fail "six-agent response budget scales per candidate"

ORIGINAL_REQ='{"messages":[{"role":"user","content":"original evidence and schema"}],"max_tokens":10,"temperature":0.2}'
REPAIRED_REQ=$(printf '%s' "$ORIGINAL_REQ" | _judge_repair_request "$BAD_SUM" 800)
[ "$(printf '%s' "$REPAIRED_REQ" | jq -r '.messages | length')" = 3 ] \
  && pass "repair preserves request and adds correction turn" || fail "repair preserves request and adds correction turn"
[ "$(printf '%s' "$REPAIRED_REQ" | jq -r '.messages[1].content')" = "$BAD_SUM" ] \
  && pass "repair shows the model its invalid response" || fail "repair shows the model its invalid response"
[ "$(printf '%s' "$REPAIRED_REQ" | jq -r '.max_tokens')" = 800 ] \
  && pass "repair retains adequate output budget" || fail "repair retains adequate output budget"
[ "$(printf '%s' "$REPAIRED_REQ" | jq -r '.temperature')" = 0 ] \
  && pass "repair is deterministic" || fail "repair is deterministic"
has "repair delegates score calculation to wtcp" "Do NOT include score; wtcp derives it" "$REPAIRED_REQ"
[ "$(grep -Fc '_judge_repair_request "$resp"' "$WTCOP")" = 2 ] \
  && pass "comparative and independent paths each retry once" || fail "comparative and independent paths each retry once"

OLD_HOME="$HOME"
HOME="$TMP/home"; export HOME
_record_invalid_judgment "fixture context" "fixture-model" "FIRST RESPONSE:
bad one
REPAIR RESPONSE:
bad two"
INVALID_LOG=$(<"$(_judge_invalid_file)")
HOME="$OLD_HOME"; export HOME
has "invalid response log records context" "fixture context" "$INVALID_LOG"
has "invalid response log records model" "fixture-model" "$INVALID_LOG"
has "invalid response log preserves first response" "bad one" "$INVALID_LOG"
has "invalid response log preserves repair response" "bad two" "$INVALID_LOG"
has "fallback report exposes diagnostic path" "Mode: independent fallback" "$(<"$WTCOP")"
has "fallback respects noninteractive menu setting" '[ "$COCKPIT_NO_INTERACTIVE_MENUS" = "1" ] || _winner_menu "$cwin"' "$(<"$WTCOP")"

echo "T9: actionable rejections and cap-aware normalization"
# A rejection the model cannot locate is a rejection it cannot fix: Qwen answered
# a bare "schema validation failed" by resending the identical broken response.
STRUCT_ERR=$(printf '%s' '{"breakdown":{"task":9,"grounding":3,"verification":2,"actionability":1}}' \
  | _rubric_response_normalize 0 2>&1 >/dev/null)
has "structural rejection names the offending field" "breakdown.task must be an integer 0-4" "$STRUCT_ERR"
has "structural rejection names every missing block" "dimension_reasons must be an object" "$STRUCT_ERR"
[ "$(printf 'jq: error (at <stdin>:3): improve_dimension is wrong\n' | _rubric_error_summary)" = "improve_dimension is wrong" ] \
  && pass "error summary strips jq framing" || fail "error summary strips jq framing"
# A coordinate alone is not actionable: the judge answered "line 30, column 1"
# by resending the identical broken JSON. Quote its own bytes back at it.
BROKEN_LINES=$(printf 'a\nb\nc\nd\ne\nf\ng\nh\n')
EXCERPT=$(_judge_error_excerpt "$BROKEN_LINES" "parse error: something at line 5, column 1")
has "excerpt includes the reported line" "5: e" "$EXCERPT"
has "excerpt includes preceding context" "2: b" "$EXCERPT"
has "excerpt includes trailing context" "7: g" "$EXCERPT"
[ -z "$(_judge_error_excerpt "$BROKEN_LINES" "no coordinate here")" ] \
  && pass "a rejection without a line number adds no excerpt" || fail "a rejection without a line number adds no excerpt"
has "rejection detail carries the excerpt" "These are the offending lines" \
  "$(_judge_rejection_detail "$BROKEN_LINES" "parse error: something at line 5, column 1")"
REPAIRED_WHY=$(printf '%s' "$ORIGINAL_REQ" | _judge_repair_request "$BAD_SUM" 800 "breakdown.task must be an integer 0-4")
has "repair turn states the concrete reason" "breakdown.task must be an integer 0-4" "$REPAIRED_WHY"
has "repair turn warns against resending the same text" "rather than resending the same text" "$REPAIRED_WHY"

# wtcp caps the score AFTER the model wrote its feedback, so improve/deduction
# describe a score that no longer exists. The model is never told the cap fired
# and cannot repair this; re-target deterministically instead of rejecting.
CAP_IMPROVE=$(printf '%s' "$GOOD_SINGLE" \
  | jq -c '.breakdown = {task:4,grounding:3,verification:2,actionability:1}
      | .evidence_level = "mixed"
      | .dimension_issue_ids = {task:"none",grounding:"none",verification:"none",actionability:"none"}
      | .deduction = "quantitative validation is missing"
      | .improve_dimension = "verification" | .improve = "add quantitative validation"')
CAP_NORM=$(printf '%s' "$CAP_IMPROVE" | _rubric_response_normalize 0)
[ "$(printf '%s' "$CAP_NORM" | jq -r '.score')" = 9 ] \
  && pass "evidence cap lowers the computed score" || fail "evidence cap lowers the computed score"
[ "$(printf '%s' "$CAP_NORM" | jq -r '.improve_dimension')" = grounding ] \
  && pass "cap-induced improve mismatch is re-targeted, not rejected" || fail "cap-induced improve mismatch is re-targeted, not rejected"
has "report exposes the cap-driven lowering" "wtcp adjusted grounding 3->2" "$(printf '%s' "$CAP_NORM" | jq -r '.normalization_notes | join(" ")')"
CAP_NONE=$(printf '%s' "$CAP_IMPROVE" \
  | jq -c '.deduction = "None" | .improve = "None" | .improve_dimension = "none"')
CAP_NONE_NORM=$(printf '%s' "$CAP_NONE" | _rubric_response_normalize 0)
# Never synthesize prose: the report language is inferred by the model from the
# instruction timeline, so an invented English sentence lands inside a Korean
# report. Reuse the judge's own sentence about the capped dimension instead.
[ "$(printf '%s' "$CAP_NONE_NORM" | jq -r '.deduction')" \
  = "$(printf '%s' "$CAP_NONE_NORM" | jq -r '.dimension_reasons.grounding')" ] \
  && pass "cap-induced empty deduction reuses the judge's own wording" || fail "cap-induced empty deduction reuses the judge's own wording"
case "$(printf '%s' "$CAP_NONE_NORM" | jq -r '.deduction')" in
  "Capped by"*|"wtcp"*) fail "wtcp never writes report prose itself" ;;
  *) pass "wtcp never writes report prose itself" ;;
esac
# A record wtcp did NOT adjust keeps its retry: only self-inflicted mismatches heal.
UNTOUCHED_MISMATCH=$(printf '%s' "$GOOD_SINGLE" | jq -c '.improve_dimension = "task"')
printf '%s' "$UNTOUCHED_MISMATCH" | _rubric_response_valid 0 \
  && fail "untouched improve mismatch still triggers the retry" || pass "untouched improve mismatch still triggers the retry"

# "did not find what a rival found" is a comparative verdict. The old guard
# matched on ID wording, so a concretely-named rival finding walked straight
# through and cost two candidates a Task point for an unrequested gap.
COMPARATIVE_TASK=$(printf '%s' "$NO_SCORE" \
  | jq -c '.dimension_issue_ids.task = "missed_orphan_references"
      | .dimension_reasons.task = "did not identify the structural defect the winner found"')
COMPARATIVE_NORM=$(printf '%s' "$COMPARATIVE_TASK" | _rubric_response_normalize 0)
[ "$(printf '%s' "$COMPARATIVE_NORM" | jq -r '.breakdown.task')" = 4 ] \
  && pass "concretely-named comparative Task deduction is removed" || fail "concretely-named comparative Task deduction is removed"
has "comparative removal is explained in the report" "Removed comparative-only Task deduction" \
  "$(printf '%s' "$COMPARATIVE_NORM" | jq -r '.normalization_notes | join(" ")')"
REQUESTED_OMISSION=$(printf '%s' "$NO_SCORE" | jq -c '.dimension_issue_ids.task = "missed_requested_benchmark"')
[ "$(printf '%s' "$REQUESTED_OMISSION" | _rubric_response_normalize 0 | jq -r '.breakdown.task')" = 3 ] \
  && pass "omission of a requested item stays a real Task deduction" || fail "omission of a requested item stays a real Task deduction"

BAD_CANDIDATE=$(printf '%s' "$GOOD_COMPARE" | jq -c '.rankings[1].breakdown.grounding = 7')
CMP_ERR=$(printf '%s' "$BAD_CANDIDATE" | _rubric_response_normalize 2 '["a","b"]' 2>&1 >/dev/null)
has "comparative rejection names the candidate" "b: breakdown.grounding must be an integer 0-3" "$CMP_ERR"
CMP_COUNT_ERR=$(printf '%s' "$GOOD_COMPARE" | _rubric_response_normalize 3 '["a","b","c"]' 2>&1 >/dev/null)
has "comparative rejection names the count mismatch" "exactly 3 records" "$CMP_COUNT_ERR"

OLD_HOME="$HOME"
HOME="$TMP/home-rotate"; export HOME
mkdir -p "$HOME/.config/wtcp"
printf 'round one diagnostic\n' > "$(_judge_invalid_file)"
_rotate_invalid_judgments
ROTATED_PREV=$(<"$(_judge_invalid_prev_file)")
ROTATED_CUR=$(<"$(_judge_invalid_file)")
HOME="$OLD_HOME"; export HOME
has "rotation preserves the previous round's diagnostic" "round one diagnostic" "$ROTATED_PREV"
[ -z "$ROTATED_CUR" ] \
  && pass "rotation starts the new round empty" || fail "rotation starts the new round empty"
has "score rotates instead of truncating" "_rotate_invalid_judgments" "$(<"$WTCOP")"

echo
echo "results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
