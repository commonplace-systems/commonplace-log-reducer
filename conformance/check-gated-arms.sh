#!/usr/bin/env bash
#
# Pin the population of test modules that do NOT run under a plain `mix test`,
# and refuse when that set changes.
#
# ## Why this exists, and why it is not a detector
#
# An EXCLUDED test still counts in ExUnit's total (`25 tests, 0 failures, 1
# excluded`), which `conformance/check.sh` now refuses. An ABSENT one --- a
# module inside a column-0 `if System.get_env(...) do` wrapper --- contributes
# ZERO to every number when the variable is unset. It is not excluded, not
# skipped: it is invisible. No count can see it, because absence is exactly
# what has no observable.
#
# So this does not try to detect the absence. It pins the set that is SUPPOSED
# to be absent and makes a CHANGE to that set observable, which is a thing that
# can be seen. It never claims a gated arm RAN; it claims only that nobody
# added one quietly. That is a weaker claim, honestly stated.
#
# Credit: the shape is commonplace-log's (`scripts/check_gated_arms.sh`),
# relayed 2026-08-27. The empty-set pin is deliberate: this repository has zero
# gated modules today, so this gate converts "I checked once" into "it stays
# checked". Both arms are demonstrated below rather than assumed --- a gate
# that has never been seen to fire is not known to work.
#
# Exit: 0 the inventory matches the pin; $RC_DIVERGED it diverges; $RC_BLIND
# the instrument could not read its own corpus.
#
# ⚠️ THE CODES ARE NAMED, NOT RESTATED. This header used to spell them as
# literals beside the `exit` statements that used other literals -- two
# statements of one value, four lines apart, which is the defect
# commonplace-markdown measured tonight in a guard fifteen minutes old (its
# floor refused correctly and NAMED THE WRONG NUMBER). It cannot misrefuse
# here, only misdocument, which is why it was recorded as a gap before being
# fixed; commonplace-plan ruled the fix worth making since it costs nothing.

set -euo pipefail

readonly RC_DIVERGED=65
readonly RC_BLIND=70

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pin="$root/conformance/GATED_ARMS.txt"
# ⚠️ THE CORPUS IS DISCOVERED, NOT TYPED.
# A hardcoded list is a population the scanner can be silently wrong about: add
# a third package and the script keeps reporting OK about the two it was told.
# commonplace-biscuit measured that class today from the other end -- its
# scanner globbed `test/*.exs`, missed a gated module one directory down, and
# its own positive control PASSED, because the control asked "did I scan
# anything" and not "did I scan everything". A NON-EMPTINESS CONTROL CANNOT
# DETECT A SCANNER READING THE WRONG POPULATION.
# So: every `*/test` directory under the repo root, discovered from the tree,
# and the set is printed with the result so the population is visible.
mapfile -t dirs < <(find "$root" -mindepth 2 -maxdepth 2 -type d -name test -not -path '*/deps/*' -not -path '*/_build/*' | sort)

if [ "${#dirs[@]}" -eq 0 ]; then
  echo "GATED-ARMS: found no */test directory under $root; refusing to report an absence." >&2
  exit "$RC_BLIND"
fi

# ---------------------------------------------------------------------------
# Positive control, first, and it decides whether a zero means anything.
#
# A grep against a path that does not exist returns no hits and looks exactly
# like a confirmed absence. Before trusting an empty inventory, prove the
# corpus is non-empty and the instrument reads it.
#
# ⚠️ AND NON-EMPTINESS IS NECESSARY, NOT SUFFICIENT. It answers "did I scan
# anything", never "did I scan everything" -- commonplace-biscuit's scanner
# passed its own control while a gated module sat one directory below its
# glob. So the corpus is enumerated TWICE, INDEPENDENTLY (`find` and
# `git ls-files`), and a disagreement REFUSES. A single enumeration has
# nothing to disagree with; two have to agree before either is believed.
# Residual, stated: this cannot catch both enumerations being wrong the same
# way. (commonplace-log's shape, 2026-08-27.)
# ---------------------------------------------------------------------------
control=0
for d in "${dirs[@]}"; do
  [ -d "$d" ] || { echo "GATED-ARMS: $d does not exist; refusing to report an absence." >&2; exit "$RC_BLIND"; }
  control=$((control + $(grep -rl "^defmodule" --include='*.exs' --include='*.ex' "$d" | wc -l)))
done

by_find="$(for d in "${dirs[@]}"; do
  find "$d" -type f \( -name '*.exs' -o -name '*.ex' \) -printf '%P\n' | sed "s|^|${d#$root/}/|"
done | sort)"
by_git="$(cd "$root" && git ls-files "*/test/*.exs" "*/test/*.ex" 2>/dev/null | sort)"

if [ "$by_find" != "$by_git" ]; then
  echo "GATED-ARMS: the two enumerations of the corpus DISAGREE, so neither is" >&2
  echo "believed. An untracked or unlisted test file is exactly the file a scanner" >&2
  echo "would miss while reporting a clean empty inventory." >&2
  diff <(printf '%s\n' "$by_git") <(printf '%s\n' "$by_find") >&2 || true
  exit "$RC_BLIND"
fi

if [ "$control" -eq 0 ]; then
  echo "GATED-ARMS: positive control found no test module at all. The instrument is" >&2
  echo "blind or the corpus moved; either way an empty inventory proves nothing." >&2
  exit "$RC_BLIND"
fi

# ---------------------------------------------------------------------------
# The inventory. Three shapes, each of which removes a module or a test from a
# plain `mix test` without appearing in any count:
#
#   * a column-0 `if`/`case`/`unless` on an environment variable, which is how
#     an env-gated test module is written (and is INDENTED BY CONSTRUCTION
#     inside, so an indentation-anchored pattern would miss its tests);
#   * `@moduletag`, which a host `ExUnit.configure(exclude: ...)` can silence
#     wholesale; and
#   * `@tag`, the same at test granularity.
#
# `grep`, not `awk`: no quoting hazard, and nothing to truncate.
#
# ## ⚠️ THE RESIDUAL OF THE FIRST SHAPE, MEASURED 2026-08-27 — READ BEFORE "FIXING" IT
#
# commonplace-log found that `^if System.get_env` RETURNS A CLEAN ZERO on a
# genuinely gated file whose wrapper is a `case`, and published
# `^(if|case|cond|unless) System.get_env` as the corrected selector. This gate
# already had `if|case|unless`. ⛔ DO NOT ADD `cond` TO IT:
#
#   `cond` TAKES NO SUBJECT. It is `cond do` with the conditions on indented
#   clause lines, so `^cond System.get_env` CANNOT MATCH ANY VALID ELIXIR.
#   Measured against a synthetic cond-gated module: the corrected selector
#   scores 0 on it, exactly as the uncorrected one does.
#
# ⭐ An alternative that can never match is DECORATION. It widens the pattern in
# the message and covers nothing in the file, which is worse than the known gap
# because it reads as closed.
#
# ⛔ THE REAL RESIDUAL, WHICH NEITHER SELECTOR CLOSES, is the SPLIT form --- the
# env call and the wrapper on different lines:
#
#     mode = System.get_env("M")
#     if mode do
#       defmodule SplitGatedTest do
#
# Both selectors score 0 here (measured). Every anchor-line pattern does, because
# the anchor line contains no `System.` at all. ⇒ THIS GATE'S CLAIM IS BOUNDED TO
# SINGLE-LINE WRAPPERS AND SAYS SO, rather than implying a coverage it lacks.
#
# ## ⛔ AND THE STRUCTURAL FIX I TRIED AND REJECTED, RECORDED SO IT IS NOT RETRIED
#
# A conditionally-compiled module is INDENTED, so `^[[:space:]]+defmodule` looked
# like the observable that does not care what the wrapper is --- and it DOES catch
# both the `case` form and the split form (both measured, 1 each).
# ⛔ It also caught FIVE modules in `commonplace_log_reducer/test/registry_test.exs`
# (lines 7, 19, 31, 38, 50): ordinary fixture modules nested inside a test module,
# compiled unconditionally, entirely correct.
# ⇒ ⭐ A GATE THAT FIRES ON CORRECT STATE IS WORSE THAN NO GATE. Indentation is the
# observable of NESTING, and conditional compilation is only one of its causes ---
# the same one-observable-many-causes shape as reading a directory's mtime as its
# contents'. The narrower, honestly-bounded selector is kept ON PURPOSE.
# ---------------------------------------------------------------------------
inventory="$(
  for d in "${dirs[@]}"; do
    grep -rn "^\(if\|case\|unless\)[[:space:]].*System\.\(get_env\|fetch_env\)" \
      --include='*.exs' --include='*.ex' "$d" 2>/dev/null |
      sed "s|^$root/|env-gated  |" || true
    grep -rn "^[[:space:]]*@moduletag[[:space:]]" \
      --include='*.exs' --include='*.ex' "$d" 2>/dev/null |
      sed "s|^$root/|moduletag  |" || true
    grep -rn "^[[:space:]]*@tag[[:space:]]" \
      --include='*.exs' --include='*.ex' "$d" 2>/dev/null |
      sed "s|^$root/|tag        |" || true
  done | sort
)"

[ -f "$pin" ] || { echo "GATED-ARMS: no pin at $pin" >&2; exit "$RC_BLIND"; }

expected="$(grep -v "^#" "$pin" | grep -v "^[[:space:]]*$" || true)"

if [ "$inventory" == "$expected" ]; then
  n=$([ -z "$inventory" ] && echo 0 || printf '%s\n' "$inventory" | wc -l)
  echo "GATED-ARMS OK: $n gated arm(s), matching the pin."
  echo "  corpus scanned (discovered, not typed): ${#dirs[@]} dirs, $control files carrying a column-0 module"
  printf '    %s\n' "${dirs[@]#$root/}"
  exit 0
fi

echo "GATED-ARMS FAILED: the set of arms that do not run under a plain \`mix test\`" >&2
echo "has changed. This is not a claim that anything broke --- it is a claim that the" >&2
echo "population changed and nobody recorded it. Record the new set in" >&2
echo "conformance/GATED_ARMS.txt, saying for each HOW it is run, or remove the gate." >&2
echo "" >&2
echo "--- pinned" >&2
printf '%s\n' "$expected" >&2
echo "--- found" >&2
printf '%s\n' "$inventory" >&2
exit "$RC_DIVERGED"
