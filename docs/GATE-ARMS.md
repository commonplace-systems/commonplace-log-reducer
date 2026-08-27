# Gate arms: which have been seen red, which have been seen green, which have not

**A gate you have never seen fail is not known to work**, and a gate that fires on
correct state is worse than no gate. This file records, per gate, what has actually been
observed — not what the code appears to do. Format borrowed from `commonplace-biscuit`'s
threshold audit (2026-08-27), which exists because a labelled gap beats a manufactured
green.

Two distinctions this table keeps, both earned the same evening:

* **Against what object?** A demonstration against an extracted copy of a function proves
  the copy. `commonplace-yepochs` measured that class; I had it here in two arms of the
  floor-ordering assertion and only noticed on being told.
* **Predicate vs wiring.** "The logic is right" and "the script calls it and survives"
  are separate claims. The second needs the real script.

Last measured 2026-08-27.

| # | Gate | Where | Red arm seen | Green arm seen | Against |
| --- | --- | --- | --- | --- | --- |
| — | byte rules (BOM, CRLF, UTF-8, trailing LF) | `conformance/check.sh` | ✅ stripped a trailing LF → `no trailing LF`, rc 1, 7 s, **0 suites** | ✅ every clean run | real script |
| — | floor ordering (DOOR 5 floor > §21 floor) | `conformance/check.sh` | ✅ floor 150 → refused, rc 1, 13 s, 0 suites · ✅ unreadable floor → refused, rc 1, 10 s, 0 suites | ⚠️ **copy only** | red: real script · green: extracted copy |
| 1 | corpus floor (a case went missing) | `test/conformance_test.exs` | ✅ removed one pair directory → 2 failures naming DOOR 1 | ✅ every clean run | real suite |
| 2 | case comparison (an expectation is wrong) | `test/conformance_test.exs` | ✅ **all 27 cases swept individually**, each mutated → that case red; pair cases named, not counted | ✅ every clean run | real suite |
| 2b | `9xx` deliberate-mismatch control | `conformance/reducer-engine/999-*` | ✅ it *is* the control — a green here means the comparison broke | ✅ every clean run | real suite |
| 3 | arms did not execute (`excluded`/`skipped`/`invalid`) | `conformance/check.sh` | ✅ `run_full`: 4 excluded → refused · ✅ `run_conformance`: 25 excluded → refused | ✅ every clean run | real script |
| 4 | gated-arms inventory changed | `conformance/check-gated-arms.sh` | ✅ tracked env-gated module → rc 65 · ✅ **planted in a subdirectory** (doc's precondition) · ✅ untracked file → rc 70, distinct code | ✅ every clean run | real script |
| 5 | the suite itself shrank | `conformance/check.sh` | ✅ floor 999 vs 226 → refused naming DOOR 5 | ✅ 226 ≥ 220, 99 ≥ 95 | real script |
| — | §21 code reachability, **FAILED** branch | `test/test_helper.exs` | ⛔ **NEVER SEEN** | ✅ prints OK on every full run | — |
| — | §21 reachability, quiet-below-floor branch | `test/test_helper.exs` | ✅ 54 excluded → `183 of 237 executed, under the 200-test floor` | ✅ every full run | real suite |

## The two open entries, stated rather than implied

**⚠️ Floor-ordering green arm — proven against an extracted copy only.** The red and
unreadable arms go through `check.sh` itself; the green one was exercised by `awk`-ing the
function out and sourcing it. That proves the copy. Closing it needs one full `check.sh`
run, which is a queue slot.

**⛔ §21 reachability FAILED branch — never seen red.** Nothing has ever demonstrated that
this gate can report a missing code. It has printed OK on every full run since it was
written, which certifies only the success path. Closing it: add a code to
`Commonplace.LogReducer.Error.codes/0` that no test emits, run the engine suite, and
confirm it names that code and sets a non-zero exit. One suite run.

Neither will be closed by manufacturing the condition and calling it evidence, and neither
is counted as working in the meantime.

## Why several arms cost nothing

The gates that refuse *before* any suite starts — byte rules, floor ordering, gated arms —
can have their red arms exercised end to end for free: the refusal happens before anything
expensive runs (measured: 7 s, 10 s, 13 s, zero suites started). Placing the cheap check
first buys a cheap configuration failure **and** free wiring evidence. It does not buy the
green arm, which still requires the whole run.
