# Acceptance record — the ten §42 criteria

The specification's §42 lists ten conditions under which "the two libraries are ready for
first adoption". This file maps each one to **the exact test, property, or conformance
vector that demonstrates it**, with a command a reader can run.

The rule this file is written under: *a criterion is demonstrated by an artifact you can
execute, or it is not demonstrated.* Where the evidence is a composition of artifacts
rather than one end-to-end run, that is said. Where there is a gap, the gap is stated
under the criterion rather than smoothed over. An honest gap beats a prose claim.

Run everything at once:

```
./conformance/check.sh          # both suites + both corpora + the byte rules
```

Measured 2026-08-23 on branch `sol/impl`:

| | |
| --- | --- |
| `commonplace_log_reducer` | 214 tests, 11 properties, 0 failures |
| `commonplace_attribute_map` | 99 tests, 13 properties, 0 failures |
| conformance corpora | 19 canonical-JSON + 18 engine + 19 attribute-map case directories |
| §21 error codes proven reachable | 15 of 15 |

## How to read a pointer

A pointer names a file and a test (or `describe`) name. Run the file:

```
cd commonplace_log_reducer && mix test test/engine_test.exs
```

Test names are quoted here rather than line numbers, because line numbers rot and names
appear verbatim in ExUnit's output. To run exactly one, `mix test path/to/file.exs:LINE`.

A conformance case directory (`conformance/reducer-engine/013-second-writer-fails/`) is
data, not a runnable file. It is executed by the corpus test in its project:

```
cd commonplace_log_reducer && mix test test/conformance_test.exs
cd commonplace_attribute_map && mix test test/conformance_test.exs
```

Each case is one generated ExUnit test named after its directory, so the case name appears
verbatim in the failure output.

---

## 1. A log containing attributes and unrelated application events reconstructs the same attribute map after any restart

**Demonstrated, by composition — not by one end-to-end vector.** See the gap below.

| Evidence | Where |
| --- | --- |
| Unrelated application entries change no projection view, and advance the head | `conformance/reducer-engine/001-unrelated-entries-advance-head/` |
| Same claim over generated logs | `commonplace_log_reducer/test/properties_test.exs` — property *"unrelated entries do not change any projection view"* |
| "Restart" as replay-from-log ≡ restore-from-checkpoint + suffix | `commonplace_log_reducer/test/properties_test.exs` — property *"full replay equals checkpoint restoration plus suffix replay"* |
| "Restart" as resume mid-stream: any batching of the same entries gives the same state | `commonplace_log_reducer/test/properties_test.exs` — property *"splitting input into arbitrary batches does not change the result"* |
| The attribute map specifically survives checkpoint/restore through the engine | `commonplace_attribute_map/test/properties_test.exs` — property *"checkpoint then restore preserves the map through the engine too"* |
| An attribute-map checkpoint round-trip as a fixed vector | `conformance/attribute-map/016-plugin-checkpoint-round-trip/` |

```
cd commonplace_log_reducer && mix test test/properties_test.exs
cd commonplace_attribute_map && mix test test/properties_test.exs
```

⚠️ **Gap.** No single artifact runs *attribute-map operations interleaved with unrelated
application entries* through a restart. The two halves are each demonstrated — the engine
skips unrelated entries (engine corpus and properties), and the attribute map survives
restart (attribute-map properties and vector 016) — but their composition is inferred, not
run. The one place an unrelated entry and a real plugin appear in the same log is the
foreign-plugin integration run (§42.10 below), which uses a different plugin and does not
restart.

## 2. The returned view names the exact processed log head and active attributes epoch

**Demonstrated.**

| Evidence | Where |
| --- | --- |
| A view names the epoch, the shared head, and the plugin value | `commonplace_log_reducer/test/checkpoint_test.exs` — describe *"section 18 view/2"*, test *"names the projection epoch, the shared head, and the plugin value"* |
| **The trap**: the head is the *shared* engine head, not a per-projection one | same file — *"all projections report the same head even when an entry touched one"* |
| An unrelated entry moves the head every view reports | same file — *"an unrelated entry advances the head every view reports"* |
| Every vector's `expected.json` states `views.<name>.head` and `views.<name>.epoch_id` as data | `conformance/reducer-engine/004-two-projections-at-one-shared-head/expected.json` and every other `ok` case |

```
cd commonplace_log_reducer && mix test test/checkpoint_test.exs
```

## 3. Content and attributes may use independent epochs over the same log

**Demonstrated with two projections; see the note on plugin identity.**

| Evidence | Where |
| --- | --- |
| Two projections, two epochs, one shared head, as a fixed vector | `conformance/reducer-engine/004-two-projections-at-one-shared-head/` |
| Replacing one projection's epoch leaves the other untouched | `conformance/reducer-engine/005-epoch-change-does-not-reset-other-projection/` and `commonplace_log_reducer/test/engine_test.exs` — *"replacing one projection's epoch leaves another projection untouched"* |
| Operations route only to their own projection | `commonplace_log_reducer/test/engine_test.exs` — *"an operation routes only to its own projection"* |
| Over generated logs | `commonplace_log_reducer/test/properties_test.exs` — property *"projection A operations do not change projection B"* |

Note: the two projections in these artifacts are named `content` and `meta` and are backed
by **fixture plugins**, not by the attribute-map plugin beside a real content reducer. What
is demonstrated is that the *engine* keeps two projections' epochs independent — which is
where the mechanism lives. That the pairing works with two real plugins is inferred.

## 4. No caller or plugin uses `created_at` or replica arrival order as overwrite order

**Demonstrated.**

| Evidence | Where |
| --- | --- |
| Two logs differing only in `created_at` reduce to the same view — engine | `conformance/reducer-engine/016-created-at-alone-changes-nothing-a/` and `.../017-created-at-alone-changes-nothing-b/`, compared by `commonplace_log_reducer/test/conformance_test.exs` — *"changing created_at alone changes nothing (section 38 case 16)"* |
| Two logs differing only in entry-v2 `operation_id` reduce to the same view — engine | `conformance/reducer-engine/018-operation-id-alone-changes-nothing-a/` and `.../019-operation-id-alone-changes-nothing-b/`, compared by `commonplace_log_reducer/test/conformance_test.exs` — *"operation_id alone changes nothing (entry version 2)"* |
| Same pair — attribute map | `conformance/attribute-map/017-timestamps-do-not-change-the-view-a/` and `.../018-...-b/`, compared by `commonplace_attribute_map/test/conformance_test.exs` — *"identical entry order with different timestamps yields the same view"* |
| Shuffling `created_at` changes neither view nor checkpoint | `commonplace_attribute_map/test/properties_test.exs` — describe *"created_at is not load-bearing"*, both properties (the second covers failure coordinates too) |
| Same, engine level, including the checkpoint bytes | `commonplace_log_reducer/test/checkpoint_test.exs` — *"created_at does not affect the checkpoint"*; `commonplace_log_reducer/test/properties_test.exs` — describe *"created_at is not load-bearing"* |
| Arrival order cannot be substituted for log order: an out-of-order entry is refused, not reordered | `commonplace_log_reducer/test/chain_test.exs` — describe *"sequence and predecessor continuity (§6, §21)"* (`writer_gap`, `writer_fork`, backwards sequence, wrong predecessor) |
| The plugin never reads context or timestamps | `commonplace_attribute_map/test/v1_test.exs` — *"context fields do not affect the result"* |

```
cd commonplace_attribute_map && mix test test/properties_test.exs test/conformance_test.exs
```

## 5. Unknown reducer code halts at a precise entry rather than losing data silently

**Demonstrated.**

| Evidence | Where |
| --- | --- |
| An unknown reducer version fails **at the epoch entry**, naming it | `conformance/reducer-engine/010-unknown-reducer-version-fails-at-epoch/` |
| Same, with the state assertion that nothing was installed | `commonplace_log_reducer/test/engine_test.exs` — *"an unknown reducer suspends at the epoch entry"* |
| Resolution is exact: a registered id at an unregistered version is `unknown_reducer`, never a neighbouring version | `commonplace_log_reducer/test/registry_test.exs` — *"a registered id at an unregistered version yields unknown_reducer, never a fallback"* |
| "Halts precisely" as a general property: reduction never advances past a failing entry | `commonplace_log_reducer/test/properties_test.exs` — property *"reduction never advances past a failing entry"* |
| The failing entry advances no head and changes no projection | `commonplace_log_reducer/test/engine_test.exs` — *"the failing entry advances no head and changes no projection"* |
| A checkpoint naming an unknown reducer is refused too | `commonplace_log_reducer/test/checkpoint_test.exs` — *"a checkpoint naming an unknown reducer yields unknown_reducer"* |

The "not silently" half is also gated suite-wide: every §21 code, `unknown_reducer` among
them, is proven to be emitted by a real assertion — see **The §21 reachability gate** below.

## 6. A checkpoint can be discarded and rebuilt entirely from the log

**Demonstrated — with a scope note.**

| Evidence | Where |
| --- | --- |
| Restoring from a checkpoint and replaying the suffix equals replaying the whole log from nothing | `commonplace_log_reducer/test/checkpoint_test.exs` — describe *"checkpoint plus suffix"*, test *"equals full replay"* |
| Over generated logs at every split point | `commonplace_log_reducer/test/properties_test.exs` — property *"full replay equals checkpoint restoration plus suffix replay"* |
| Restoring rebuilds a state whose views equal the original's | `commonplace_log_reducer/test/checkpoint_test.exs` — *"rebuilds a state whose views equal the original's"* |
| Every `ok` conformance vector is a full replay from the log with no checkpoint input at all — 17 engine + 18 attribute-map cases (each corpus's remaining directory is its `999` deliberate mismatch) | `conformance/reducer-engine/`, `conformance/attribute-map/` |
| The plugin's own checkpoint round-trips | `commonplace_attribute_map/test/v1_test.exs` — describe *"checkpoint (spec 32)"*; `conformance/attribute-map/016-plugin-checkpoint-round-trip/` |

Scope note: this library has **no persistence**. A checkpoint here is a value, never a
file, so "discarded" cannot mean "deleted from disk" in any artifact. What the artifacts
establish is the property that makes discarding safe: the log alone reaches the same state,
byte-for-byte, that the checkpoint path reaches. Whoever stores checkpoints owns the
deletion.

## 7. A checkpoint plus the remaining suffix is equivalent to full replay

**Demonstrated.**

| Evidence | Where |
| --- | --- |
| The named vector | `conformance/reducer-engine/015-checkpoint-plus-suffix-equals-full-replay/` |
| The engine test | `commonplace_log_reducer/test/checkpoint_test.exs` — describe *"checkpoint plus suffix"* |
| The property, over generated logs and every split point | `commonplace_log_reducer/test/properties_test.exs` — property *"full replay equals checkpoint restoration plus suffix replay"* |
| The plugin-level version | `commonplace_attribute_map/test/v1_test.exs` — *"checkpoint plus suffix equals full replay"* |
| Across a **foreign** plugin's state | `docs/42-10-PLUGIN-BOUNDARY.md` — the `cp+suffix ... == full replay: true` line |
| The suffix must actually be the suffix: input after restore must begin at `head.writer_seq + 1` with the right predecessor | `commonplace_log_reducer/test/checkpoint_test.exs` — *"input after restore must begin at head.writer_seq + 1 with the right predecessor"* |

Equivalence is compared as **RFC 8785 canonical JSON bytes**, not Elixir terms — see
`commonplace_log_reducer/test/checkpoint_test.exs`, describe *"section 20 canonical JSON"*,
and the 19-case `conformance/canonical-json/` corpus behind `test/jcs_test.exs`.

## 8. A second writer lane is rejected

**Demonstrated.**

| Evidence | Where |
| --- | --- |
| The vector, naming the exact refusing coordinate | `conformance/reducer-engine/013-second-writer-fails/` (`multiwriter_document_unsupported` at `writer_seq: 2`) |
| The engine test | `commonplace_log_reducer/test/chain_test.exs` — describe *"writer identity (§17)"*, test *"a second writer id yields multiwriter_document_unsupported"* |
| The control: the **same** writer id across many entries is accepted, so the check is not simply refusing everything | same describe — *"the SAME writer id across many entries is accepted"* |
| The same rule on restore | `commonplace_log_reducer/test/checkpoint_test.exs` — *"a checkpoint with two writer ids yields invalid_checkpoint"* |

## 9. Attribute null and attribute deletion remain observably different

**Demonstrated.**

| Evidence | Where |
| --- | --- |
| The vector | `conformance/attribute-map/007-null-remains-present/` |
| `put` of null leaves the key **present** | `commonplace_attribute_map/test/v1_test.exs` — *"put of null leaves the key PRESENT"* |
| `delete` makes it absent | same file — describe *"delete (spec 28)"* |
| The view exposes no tombstones, so absence is real absence | same file — *"the view exposes no deletion tombstones"* |
| null is a valid value, not a missing one | `commonplace_attribute_map/test/validation_test.exs` — *"null is a VALID value"* |
| Every absence assertion in the property suite uses `Map.has_key?/2`, never a comparison to `nil` — comparing values would collapse the two cases and make properties 2 and 3 vacuous | `commonplace_attribute_map/test/properties_test.exs` — properties *"put then delete yields absence"*, *"delete then put yields the put value"*, and the moduledoc that records why |

The last row is the load-bearing one: this criterion is the kind that a test suite can
appear to check while checking nothing.

## 10. commonplace-merkle-crdt can implement the same plugin behaviour without changing the core reducer API

**Demonstrated, 2026-08-23.** Full record: **[`docs/42-10-PLUGIN-BOUNDARY.md`](42-10-PLUGIN-BOUNDARY.md)**.

An independently-authored second plugin — `commonplace-merkle-crdt`, a different
repository, a different author who never opened this library's `lib/` — took this engine
as a **real git dependency**, implemented `@behaviour Commonplace.LogReducer.Plugin`
against the actual behaviour module, and ran a real log through `reduce/3`. **No change to
the engine was required, and none was made.**

The run drives a four-entry log (an epoch, an unrelated application entry the engine must
skip, two operations) plus a fifth entry the plugin refuses, and checks §12.1 identity,
§16 routing, §18 shared head, §19 checkpoint round-trip, §42.7 checkpoint-plus-suffix
equivalence, §20 byte-identical checkpoints, §12.2 plugin-refusal classification, and §15.1
head non-advance.

Script: `docs/42-10-integration-proof.exs`, run from the plugin's repository against its
resolved dependency. It is only valid at a stated plugin commit (`53df66e`) — the record
explains why, and how an earlier version of it silently stopped reproducing.

Three controls were added after the first run and all three bite: changing the input
changes the view; corrupting the payload yields `invalid_operation` rather than a clean
view; registering under a wrong id trips the identity check.

### What this does NOT establish

Carried over verbatim in substance from the record, because a demonstrated criterion
invites over-reading:

- **One foreign plugin, not plugin-generality.** A third implementer could still find the
  API bent toward the two plugin shapes now built against it.
- The plugin is not shipped, and its own repository records outstanding design work.
- It exercises one epoch, one projection, and a short log. The corpus in `conformance/`
  covers breadth; this covers the *boundary*.
- It shares a machine, a week, and a conversation with this engine. The author was
  independent of the code, **not of the context**.

And separately: `conformance/README.md` states that the corpus **cannot** validate §42.10,
because every plugin it exercises shares an author with the engine. That is not a
contradiction of the line above — the corpus shows breadth, the integration run shows the
boundary, and no corpus written in this repository can ever show the boundary however large
it grows.

The boundary work also found three real defects that were not reachable from inside this
repository: a normative gap in the specification (fixed as §12.2), an incorrect
justification in `PLUGIN_AUTHORS.md`, and incorrect conformance advice. They are recorded
in the boundary document; they are the reason the criterion is worth more than its green
line.

---

## The §21 reachability gate

Not a §42 criterion, but the thing that keeps §42.5's "rather than losing data silently"
honest across all fifteen codes.

`Commonplace.LogReducer.Error` declares fifteen §21 codes. Reading that list proves only
that someone typed it. Every assertion in the engine suite that observes an error passes it
through `Emitted.record/1` (repo-root `test_support/emitted.ex`), which records the code in
an ETS table; an `ExUnit.after_suite/1` hook in
`commonplace_log_reducer/test/test_helper.exs` then asserts the set is complete and fails
the run's exit status if it is not.

```
cd commonplace_log_reducer && mix test
# => [§21 reachability] OK: all 15 §21 codes were emitted by an assertion in this run.
```

Three things about its construction, each of which was a live failure mode:

- **It is `after_suite`, not a test.** ExUnit randomizes order, so a "runs last" test does
  not run last, and would read a partly-filled table on most seeds.
- **It is gated to full runs**, by test count against a stated floor. A filtered run
  legitimately emits fewer than fifteen codes; firing there would be a false red on correct
  behaviour, and a gate that cries wolf gets ignored.
- **It stands down when the suite is red.** A missing code after failures is a symptom of
  the failures; reporting it would bury the cause.

**Both arms are demonstrated, not assumed:**

| Arm | How it was provoked | Result |
| --- | --- | --- |
| Can go red | skipped the three tests that emit `missing_resource`, ran the full suite | `[§21 reachability] FAILED: ... * missing_resource`, exit status `1` |
| Stays green on known-good input | full suite, unmodified | `OK: all 15 §21 codes` |
| Does not fire on a filtered run | `mix test test/error_test.exs` | `skipped: 4 tests ran, under the 200-test floor`, exit `0` |

---

## What a fully green run does not mean

- **Not exhaustiveness.** The corpora state the §38 cases and no more.
- **Not vector correctness.** Where a vector and the specification disagree, the
  specification wins and the vector is the bug.
- **Not plugin generality.** §42.10 is demonstrated once, by one foreign plugin, in one
  integration run. A third independent implementer remains a strictly stronger test, and
  nothing written in this repository can supply one.
- **Not production readiness of the surrounding system.** This library owns reduction. Log
  persistence, BEAM process lifecycle, Document messaging, Cell authority, capabilities,
  Realm placement, and replica synchronization are owned elsewhere and are not exercised
  here at all.
