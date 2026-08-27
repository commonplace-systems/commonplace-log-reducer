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

  summary="$(printf '%s\n' "$out" | grep -E '^[0-9]+ (properties, [0-9]+ )?tests?, [0-9]+ failures?' | tail -1)"

  # DOOR 3: a test that was EXCLUDED still counts in ExUnit's total, so a floor
  # compared against that total goes green while an arm never ran (measured
  # 2026-08-27: "25 tests, 0 failures, 1 excluded" passed a floor of 25).
  # "Excluded", "skipped", "invalid" and "ran" must not share an observable.
  # An UNPARSEABLE summary is refused for the same reason: it must not share an
  # observable with a clean one.
  [ -n "$summary" ] || fail "$project: could not parse the ExUnit summary line. " \
    "Refusing rather than assuming a clean run -- unparseable and clean must not " \
    "share an observable."

  # ⚠️ ARM NOT YET DEMONSTRATED. The identical refusal in `run_full` HAS been
  # seen red (2026-08-27: "226 tests, 0 failures, 4 excluded" -> FAIL naming
  # DOOR 3) and seen green. THIS one has not: inducing it needs an exclusion
  # that lands inside test/conformance_test.exs, and the obvious probe (@tag)
  # is caught first by DOOR 4, which runs earlier -- the first attempt refused
  # at DOOR 4 and proved the wrong gate. Same code shape is not a
  # demonstration. Induce with `exclude: [module: ConformanceTest]` and see it
  # red before relying on it.
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
  local project="$1" out status summary kind

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

  summary="$(printf '%s\n' "$out" | grep -E '^[0-9]+ (properties, [0-9]+ )?tests?, [0-9]+ failures?' | tail -1)"
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
}

# DOOR 4: the arms that do not run under a plain `mix test` at all. An excluded
# test inflates the total; an env-gated module is ABSENT from it. No count sees
# the second, so the population is pinned instead and a CHANGE is refused.
# Source-only, and both arms were demonstrated 2026-08-27 (empty set -> 0;
# synthetic env-gated module -> 65 naming it; removed -> 0 again).
"$(dirname "$0")/check-gated-arms.sh" || fail "the set of gated arms changed (DOOR 4)."

run_conformance commonplace_log_reducer "$ENGINE_CONFORMANCE_TESTS"
run_conformance commonplace_attribute_map "$ATTRIBUTE_MAP_CONFORMANCE_TESTS"

run_full commonplace_log_reducer
run_full commonplace_attribute_map

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
