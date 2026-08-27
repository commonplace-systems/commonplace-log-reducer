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

**Measured at `18a6e5e`, 2026-08-27 19:03Z** — and the sha matters more than the date.
A RUN IS EVIDENCE ABOUT THE SHA IT RAN AGAINST AND DOES NOT TRAVEL FORWARD
(commonplace-dir's finding, 2026-08-27: it had filed a gate run under a sha that did not
exist when the run happened). "My tree is gated" and "my tree WAS gated at the last full
run" are different sentences, and the second decays silently because nobody re-runs a
suite to clear a docs commit.

Commits after `18a6e5e` are listed here rather than left to inference. If this list ever
contains a path under `conformance/`, `lib/`, or `test/`, THIS TABLE IS STALE and the
run must be repeated:

| Since the run | Paths | Reads a gate? |
| --- | --- | --- |
| `4e9779f`, `2280a03` | `docs/GATE-ARMS.md`, `README.md` | no — docs only |

| # | Gate | Where | Red arm seen | Green arm seen | Against |
| --- | --- | --- | --- | --- | --- |
| — | byte rules (BOM, CRLF, UTF-8, trailing LF) | `conformance/check.sh` | ✅ stripped a trailing LF → `no trailing LF`, rc 1, 7 s, **0 suites** | ✅ every clean run | real script |
| — | floor ordering (DOOR 5 floor > §21 floor) | `conformance/check.sh` | ✅ floor 150 → refused, rc 1, 13 s, 0 suites · ✅ unreadable floor → refused, rc 1, 10 s, 0 suites | ✅ **closed 19:03Z**: `OK: DOOR 5 floor 220 > §21 reachability floor 200`, then the script COMPLETED, rc 0 | real script, both arms |
| 1 | corpus floor (a case went missing) | `test/conformance_test.exs` | ✅ removed one pair directory → 2 failures naming DOOR 1 | ✅ every clean run | real suite |
| 2 | case comparison (an expectation is wrong) | `test/conformance_test.exs` | ✅ **all 27 cases swept individually**, each mutated → that case red; pair cases named, not counted | ✅ every clean run | real suite |
| 2b | `9xx` deliberate-mismatch control | `conformance/reducer-engine/999-*` | ✅ it *is* the control — a green here means the comparison broke | ✅ every clean run | real suite |
| 3 | arms did not execute (`excluded`/`skipped`/`invalid`) | `conformance/check.sh` | ✅ `run_full`: 4 excluded → refused · ✅ `run_conformance`: 25 excluded → refused | ✅ every clean run | real script |
| 4 | gated-arms inventory changed | `conformance/check-gated-arms.sh` | ✅ tracked env-gated module → rc 65 · ✅ **planted in a subdirectory** (doc's precondition) · ✅ untracked file → rc 70, distinct code | ✅ every clean run | real script |
| 5 | the suite itself shrank | `conformance/check.sh` | ✅ floor 999 vs 226 → refused naming DOOR 5 | ✅ 226 ≥ 220, 99 ≥ 95 | real script |
| — | §21 code reachability, **FAILED** branch | `test/test_helper.exs` | ✅ **closed 19:03Z**: withheld one code from `Emitted.record/1` → `FAILED: 1 declared §21 code(s) were never emitted … * missing_resource`, rc 1 | ✅ prints OK on every full run | real suite |
| — | §21 reachability, quiet-below-floor branch | `test/test_helper.exs` | ✅ 54 excluded → `183 of 237 executed, under the 200-test floor` | ✅ every full run | real suite |

## Both entries closed 2026-08-27 19:03Z — and how the obvious induction would have lied

Every arm in the table above has now been seen red **and** green against the real object.

**⚠️ The obvious way to induce the §21 FAILED branch produces a red that is not the gate.**
The natural move is to add a code to `Commonplace.LogReducer.Error.codes/0` that no test
emits. But `test/error_test.exs` asserts `length(Error.codes()) == 15` and compares the
list, so a planted code reddens *that* test — and this gate **skips when the suite is
red**, by design, so it would have gone quiet while a collateral failure supplied the
non-zero exit. ⇒ "It refused" would have been true and about the wrong subject.

The induction that works withholds one code from `Emitted.record/1`, which feeds the
gate's table and which nothing else asserts on. The suite stays green — `226 tests, 0
failures` — so the failure can only be the gate:

```
[§21 reachability] FAILED: 1 declared §21 code(s) were never emitted by any assertion in this run:
  * missing_resource
```

**That distinction is the arm.** A demonstration that leaves the suite red cannot tell you
whether this branch works, because the branch's first action on a red suite is to decline
to run.

## Why several arms cost nothing

The gates that refuse *before* any suite starts — byte rules, floor ordering, gated arms —
can have their red arms exercised end to end for free: the refusal happens before anything
expensive runs (measured: 7 s, 10 s, 13 s, zero suites started). Placing the cheap check
first buys a cheap configuration failure **and** free wiring evidence. It does not buy the
green arm, which still requires the whole run.
