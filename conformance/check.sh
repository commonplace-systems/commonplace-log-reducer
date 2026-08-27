#!/usr/bin/env bash
#
# Runs the conformance corpora against both Elixir projects.
#
# Exits non-zero on:
#   * any failing test in either suite;
#   * a deliberately-wrong 9xx vector that UNEXPECTEDLY PASSES (that is a
#     failing `refute` inside the suite, so it lands here as a test failure);
#   * a conformance suite that ran fewer tests than recorded below -- an
#     unmounted corpus is a green suite over nothing;
#   * a corpus file that breaks the byte rules of conformance/README.md.
#
# After a fully green run it prints the SELECTOR block: what this corpus does
# NOT establish. A conformance suite that only ever prints good news teaches
# its readers to over-read it. See docs/ACCEPTANCE.md for the criterion-by-
# criterion record this run is one input to.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# Measured once, then written down. A floor derived by counting what the run
# reported would pass against a suite that ran nothing.
# DOOR 5: the whole suite's own size floor.
#
# Measured 2026-08-27: engine 226 tests + 11 properties, attribute-map 99 + 13.
# These floors sit BELOW those and ABOVE the §21 reachability gate's own
# `full_suite_floor` of 200 in commonplace_log_reducer/test/test_helper.exs.
# That ordering is the point, and it is a structural relationship rather than a
# coincidence: below 200 the §21 gate GOES QUIET (it cannot distinguish a
# legitimately filtered run from a shrunken suite, because ExUnit's summary
# does not say which). A floor here, in the one place that KNOWS it just ran
# the whole suite, means a passing check.sh can never contain a quiet §21 gate.
#
# ⚠️ Deliberately NOT equal to 200. A floor written as the same number as the
# thing it protects has nothing to disagree with; two constants make a
# weakening visible in a diff (commonplace-biscuit's two-constants rule).
ENGINE_FULL_SUITE_MIN=220
ATTRIBUTE_MAP_FULL_SUITE_MIN=95

# ⭐ THE ORDERING ABOVE IS ASSERTED, NOT ANNOTATED.
#
# DOOR 5's floor and the §21 gate's `full_suite_floor` are TWO STATEMENTS OF
# ONE CRITERION living in two files, and nothing links them: raise the §21
# floor to 250 without touching this file and the ordering breaks SILENTLY,
# restoring the quiet-gate hole DOOR 5 exists to close. commonplace-log
# shipped exactly that defect tonight -- its gate moved and its reachability
# check stayed behind -- and doc-sync's rule is the fix: KEEP THE TWO
# STATEMENTS IN ONE EDIT, or link them so an edit cannot separate them.
# A comment is a remembered rule; this is the artifact that fires.
#
# The §21 floor is READ from its source of truth rather than restated here.
# ⚠️ If it cannot be read the answer is NO NUMBER, not a comfortable default:
# an unverifiable term must not resolve to the reassuring value (doc-sync).
assert_floor_ordering() {
  local helper="$root/commonplace_log_reducer/test/test_helper.exs" reach

  reach="$(sed -n 's/^full_suite_floor = \([0-9]\{1,\}\)$/\1/p' "$helper" | tail -1)"

  case "$reach" in
    '' | *[!0-9]*)
      fail "could not read full_suite_floor from $helper. Refusing rather than " \
        "assuming an ordering: an unverifiable term resolves to no number, not " \
        "to the comfortable one."
      ;;
  esac

  if [ "$ENGINE_FULL_SUITE_MIN" -le "$reach" ]; then
    fail "DOOR 5 floor ($ENGINE_FULL_SUITE_MIN) is not above the §21 " \
      "reachability floor ($reach). Below that floor the §21 gate goes QUIET " \
      "rather than red, so a passing run could contain a gate that never " \
      "fired. Raise DOOR 5's floor, or lower the §21 floor, in the SAME EDIT."
  fi

  green "OK: DOOR 5 floor $ENGINE_FULL_SUITE_MIN > §21 reachability floor $reach"
}

ENGINE_CONFORMANCE_TESTS=25
ATTRIBUTE_MAP_CONFORMANCE_TESTS=23
CORPUS_FILES=112

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

fail() {
  red "FAIL: $*"
  exit 1
}

# ---------------------------------------------------------------------------
# 1. Byte rules (conformance/README.md)
# ---------------------------------------------------------------------------

bold "== byte rules =="

files=()
while IFS= read -r -d '' f; do files+=("$f"); done < <(
  find conformance -type f \( -name '*.json' -o -name '*.hex' \) -print0 | sort -z
)

# Positive control: prove the corpus we are about to validate is non-empty.
# A byte-rule pass over zero files is indistinguishable from a byte-rule pass.
if [ "${#files[@]}" -lt "$CORPUS_FILES" ]; then
  fail "found ${#files[@]} corpus files, expected at least $CORPUS_FILES. " \
    "This is DOOR 1 (the corpus shrank), not a byte-rule violation."
fi

for f in "${files[@]}"; do
  [ -s "$f" ] || fail "$f: empty file"

  if [ "$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
    fail "$f: UTF-8 BOM"
  fi

  if LC_ALL=C grep -q $'\r' "$f"; then
    fail "$f: CRLF or stray CR"
  fi

  iconv -f UTF-8 -t UTF-8 <"$f" >/dev/null 2>&1 || fail "$f: not valid UTF-8"

  [ "$(tail -c 1 "$f" | od -An -tx1 | tr -d ' \n')" = "0a" ] ||
    fail "$f: no trailing LF"

  [ "$(tail -c 2 "$f" | head -c 1 | od -An -tx1 | tr -d ' \n')" != "0a" ] ||
    fail "$f: more than one trailing LF"
done

green "OK: ${#files[@]} corpus files, UTF-8, no BOM, LF only, exactly one trailing LF"

# ---------------------------------------------------------------------------
# 2. The suites
# ---------------------------------------------------------------------------

# Runs one project's conformance file and asserts it ran at least `expected`
# tests. `mix test` already exits non-zero on failure; the count is the
# anti-vacuity half.
run_conformance() {
  local project="$1" expected="$2" out status count summary n kind

  bold "== $project: conformance =="

  set +e
  out="$(cd "$project" && mix test test/conformance_test.exs 2>&1)"
  status=$?
  set -e

  printf '%s\n' "$out"
  [ "$status" -eq 0 ] || fail "$project: conformance suite failed"

  # ⚠️ THE PATTERN IS DELIBERATELY LOOSE, AND `tests?`/`failures?` ARE NOT
  # OPTIONAL NICETIES. `1 test, 1 failure` is the shape a MINIMAL REPRO takes,
  # so a plural-only pattern is blind exactly on the run you build when
  # something is wrong. And an anchored OPTIONAL prefix group is engine-
  # dependent: measured 2026-08-27, `^[0-9]+ (properties, [0-9]+ )?tests?...`
  # misses "1 property, 1 test, 1 failure" under GNU grep 3.11, and a
  # flat-alternation variant misses it under ugrep 7.8.4 -- which is what an
  # interactive shell here resolves `grep` to, while a SCRIPT gets GNU grep.
  # ⭐ So the source-only checks I verified this parser with were running a
  # DIFFERENT REGEX ENGINE than this gate does. This form matches under both.
  summary="$(printf '%s\n' "$out" | grep -E '[0-9]+ tests?, [0-9]+ failures?' | tail -1)"

  # DOOR 3: a test that was EXCLUDED still counts in ExUnit's total, so a floor
  # compared against that total goes green while an arm never ran (measured
  # 2026-08-27: "25 tests, 0 failures, 1 excluded" passed a floor of 25).
  # "Excluded", "skipped", "invalid" and "ran" must not share an observable.
  # An UNPARSEABLE summary is refused for the same reason: it must not share an
  # observable with a clean one.
  [ -n "$summary" ] || fail "$project: could not parse the ExUnit summary line. " \
    "Refusing rather than assuming a clean run -- unparseable and clean must not " \
    "share an observable."

  # ARM DEMONSTRATED 2026-08-27, both directions. Red: `exclude: [module:
  # ConformanceTest]` -> "25 tests, 0 failures, 25 excluded" -> FAIL naming
  # DOOR 3. Green: every clean run of this script.
  # ⚠️ Inducing it needs an exclusion INSIDE test/conformance_test.exs, and the
  # obvious probe (an added @tag) is caught first by DOOR 4, which runs
  # earlier: the first attempt refused at DOOR 4 and proved the wrong gate.
  # A red is not self-certifying -- read WHICH gate spoke.
  for kind in excluded skipped invalid; do
    if printf '%s\n' "$summary" | grep -qE "[0-9]+ $kind"; then
      n="$(printf '%s\n' "$summary" | sed -n "s/.*[^0-9]\([0-9]\{1,\}\) $kind.*/\1/p")"
      fail "$project: $n test(s) $kind -- this run did not execute the whole suite. " \
        "Summary: $summary. This is DOOR 3 (arms did not run), not door 1 or 2."
    fi
  done

  count="$(printf '%s\n' "$summary" | sed -n 's/.*[^0-9]\([0-9]\{1,\}\) tests\?,.*/\1/p')"
  [ -n "$count" ] || count="$(printf '%s\n' "$summary" | sed -n 's/^\([0-9]\{1,\}\) tests\?,.*/\1/p')"
  [ -n "$count" ] || fail "$project: could not read the test count from: $summary"

  if [ "$count" -lt "$expected" ]; then
    fail "$project: ran $count conformance tests, expected at least $expected. " \
      "This is DOOR 1 (the corpus shrank), not door 2."
  fi

  green "OK: $project ran $count conformance tests"
}

run_full() {
  local project="$1" minimum="$2" out status summary kind count

  bold "== $project: full suite =="

  # Judging a suite by its exit code alone is the weakest form of DOOR 3: an
  # excluded arm leaves rc 0 and the total unmoved. The summary is parsed and
  # the same three words refused here too.
  set +e
  out="$(cd "$project" && mix test 2>&1)"
  status=$?
  set -e

  printf '%s\n' "$out"
  [ "$status" -eq 0 ] || fail "$project: full suite failed"

  summary="$(printf '%s\n' "$out" | grep -E '[0-9]+ tests?, [0-9]+ failures?' | tail -1)"
  [ -n "$summary" ] || fail "$project: could not parse the ExUnit summary line of the full run."

  # `if`, not `grep -q ... && fail ...`: as the loop's last statement a
  # non-matching `&&` list returns 1, which becomes the function's status and
  # aborts the script under `set -e`. Measured 2026-08-27: that form reddened
  # this gate on a CLEAN tree, which is worse than no gate at all.
  for kind in excluded skipped invalid; do
    if printf '%s\n' "$summary" | grep -qE "[0-9]+ $kind"; then
      fail "$project: full run reports '$summary' -- arms did not execute (DOOR 3)."
    fi
  done

  # DOOR 5: the suite itself must not have shrunk. Nothing else here notices:
  # DOOR 3 refuses arms that were EXCLUDED, and a deleted test is not excluded,
  # it is gone. The §21 gate would go quiet rather than red.
  count="$(printf '%s\n' "$summary" | sed -n 's/.*[^0-9]\([0-9]\{1,\}\) tests\?,.*/\1/p')"
  [ -n "$count" ] || count="$(printf '%s\n' "$summary" | sed -n 's/^\([0-9]\{1,\}\) tests\?,.*/\1/p')"
  [ -n "$count" ] || fail "$project: could not read the full-run test count from: $summary"

  if [ "$count" -lt "$minimum" ]; then
    fail "$project: full suite ran $count tests, under the $minimum floor. " \
      "This is DOOR 5 (the SUITE shrank), not door 1 (the corpus shrank) or " \
      "door 3 (arms were excluded). Summary: $summary"
  fi

  green "OK: $project full suite ran $count tests (floor $minimum)"
}

# DOOR 4: the arms that do not run under a plain `mix test` at all. An excluded
# test inflates the total; an env-gated module is ABSENT from it. No count sees
# the second, so the population is pinned instead and a CHANGE is refused.
# Source-only, and both arms were demonstrated 2026-08-27 (empty set -> 0;
# synthetic env-gated module -> 65 naming it; removed -> 0 again).
# Cheapest first: a configuration error must not cost four suite runs to find.
# ARMS: green (220 > 200 -> OK) and refuse-on-unreadable demonstrated in
# isolation; the WIRING RED demonstrated here (floor 150 -> rc 1 in 13s with
# ZERO suites started). ⚠️ The WIRING GREEN -- that this script still completes
# after the assertion passes -- is NOT yet demonstrated end to end; it needs a
# full run and the box is queued. Reasoned-about and watched-working are not
# the same object, and a function whose last command returns non-zero aborts
# the script under `set -e` (measured here 2026-08-27, in this file).
assert_floor_ordering

"$(dirname "$0")/check-gated-arms.sh" || fail "the set of gated arms changed (DOOR 4)."

run_conformance commonplace_log_reducer "$ENGINE_CONFORMANCE_TESTS"
run_conformance commonplace_attribute_map "$ATTRIBUTE_MAP_CONFORMANCE_TESTS"

run_full commonplace_log_reducer "$ENGINE_FULL_SUITE_MIN"
run_full commonplace_attribute_map "$ATTRIBUTE_MAP_FULL_SUITE_MIN"

# ---------------------------------------------------------------------------
# 3. Selector
# ---------------------------------------------------------------------------

echo
green "CONFORMANCE GREEN"
echo
bold "SELECTOR -- what this green run does NOT mean:"
cat <<'SELECTOR'
  THIS CORPUS DOES NOT ARGUE §42.10. Every plugin exercised here --
  FixturePlugin.* and Commonplace.AttributeMap.V1 -- shares an author with the
  engine. A green run shows that the two sides agree; it cannot show that the
  plugin boundary is discoverable, sufficient, or usable by an independent
  implementer, and no corpus written in this repository ever can, however
  large it grows.

  §42.10 IS demonstrated -- elsewhere, and once. An independently authored
  plugin (commonplace-merkle-crdt, a different repo and a different author who
  never opened this library's lib/) took this engine as a real git dependency
  and ran a real log through reduce/3 with no engine change. The record is
  docs/42-10-PLUGIN-BOUNDARY.md; the run is docs/42-10-integration-proof.exs.

  That is a boundary DEMONSTRATION, not plugin GENERALITY. One foreign plugin
  is one data point: a third independent implementer could still find the API
  bent toward the two plugin shapes now built against it, and would be a
  strictly stronger test. Read the "what this does NOT establish" section of
  that document before citing it.

  Also not shown here: that the corpus is exhaustive (it states the §38 cases
  and no more), and that the vectors are right (where a vector and the spec
  disagree, the spec wins and the vector is the bug).
SELECTOR
