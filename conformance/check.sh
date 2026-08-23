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
# After a fully green run it prints the SELECTOR line: what this corpus does
# NOT establish. A conformance suite that only ever prints good news teaches
# its readers to over-read it.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# Measured once, then written down. A floor derived by counting what the run
# reported would pass against a suite that ran nothing.
ENGINE_CONFORMANCE_TESTS=22
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
  local project="$1" expected="$2" out status count

  bold "== $project: conformance =="

  set +e
  out="$(cd "$project" && mix test test/conformance_test.exs 2>&1)"
  status=$?
  set -e

  printf '%s\n' "$out"
  [ "$status" -eq 0 ] || fail "$project: conformance suite failed"

  count="$(printf '%s\n' "$out" | sed -n 's/^\([0-9]\{1,\}\) tests\?, .*/\1/p' | tail -1)"
  [ -n "$count" ] || fail "$project: could not read the test count from the output"

  if [ "$count" -lt "$expected" ]; then
    fail "$project: ran $count conformance tests, expected at least $expected. " \
      "This is DOOR 1 (the corpus shrank), not door 2."
  fi

  green "OK: $project ran $count conformance tests"
}

run_full() {
  local project="$1"

  bold "== $project: full suite =="
  (cd "$project" && mix test) || fail "$project: full suite failed"
}

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
  §42.10 IS NOT VALIDATED BY THIS CORPUS. Every plugin exercised here --
  FixturePlugin.* and Commonplace.AttributeMap.V1 -- shares an author with the
  engine. A green run shows that the two sides agree; it cannot show that the
  plugin boundary is discoverable, sufficient, or usable by an independent
  implementer. Only a second, independently authored plugin (§41.11 names
  commonplace-merkle-crdt) can move that claim, and it will need its own
  corpus.

  Also not shown: that the corpus is exhaustive (it states the §38 cases and no
  more), and that the vectors are right (where a vector and the spec disagree,
  the spec wins and the vector is the bug).
SELECTOR
