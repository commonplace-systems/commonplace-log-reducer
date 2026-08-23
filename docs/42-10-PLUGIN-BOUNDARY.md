# §42.10 — the plugin boundary, demonstrated

**Status: DEMONSTRATED, 2026-08-23.** Previously recorded as *not demonstrated*.

> §42.10: "commonplace-merkle-crdt can implement the same plugin behavior without
> changing the core reducer API."

This was the one acceptance criterion this repository could not satisfy on its own.
Every plugin written here shares an author and a week with the engine — the arrangement
that *hides* accidental coupling rather than exposing it. A green suite proved the
engine agreed with itself.

## What was actually run

`commonplace-merkle-crdt` (merkle-wrapped Yjs edits) was written in a separate
repository by a separate author who, unprompted and repeatedly on the record, **never
opened this library's `lib/`** — working only from the specification, `PLUGIN_AUTHORS.md`,
and `behaviour_info(:callbacks)` at runtime.

It takes this engine as a **real git dependency** from the published branch and
implements `@behaviour Commonplace.LogReducer.Plugin` against the actual behaviour
module, not a restated copy. A hand-copied behaviour would have concealed precisely what
this criterion asks.

The script is `docs/42-10-integration-proof.exs`, run from that repository against its
resolved dependency. Reproduce with:

```
cd ~/commonplace-merkle-crdt && MIX_ENV=test mix run <path>/42-10-integration-proof.exs
```

It drives a four-entry log — an epoch, an **unrelated** application entry the engine must
skip, and two operations — then a fifth entry the plugin must refuse.

## Measured output

```
registry built (identity check passed): OK
view          : %{"text" => "helloworld"}
head          : %{writer_seq: 4, entry_id: "e4"}
epoch         : 0198d83a-0a1f-7ba0-aa24-21f9130f883d
restore view  : %{"text" => "helloworld"}  identical: true
cp+suffix     : %{"text" => "helloworld"}  == full replay: true
cp bytes eq   : true
snapshot ref  : code=invalid_operation seq=5 reason={:snapshot_unsupported, "deadbeef"}
prefix head   : 4 (unchanged: true)
```

## What each line establishes

| Line | Establishes |
| --- | --- |
| registry built | §12.1 identity agreement holds for a foreign plugin |
| view / head / epoch | §16 routing, §18 shared head, unrelated entry skipped but head advanced |
| restore view identical | §19 checkpoint round-trip across the plugin boundary |
| cp+suffix == full replay | **§42.7** equivalence, with a foreign plugin's state |
| cp bytes eq | §20 determinism — byte-identical checkpoints |
| snapshot ref | §12.2 classification of a *plugin-defined* refusal, reason carried verbatim |
| prefix head unchanged | §15.1 — the failing entry advanced nothing |

**No change to the engine was required, and none was made.**

## What this does NOT establish

Stated plainly, because a demonstrated criterion invites over-reading:

- **One foreign plugin, not plugin-generality.** A third implementer could still find the
  API bent toward the two plugin shapes now built against it.
- The plugin is not shipped, and its own repository records outstanding design work.
- It exercises one epoch, one projection, and a short log. The corpus in `conformance/`
  covers breadth; this covers the *boundary*.
- It shares a machine, a week, and a conversation with this engine. The author was
  independent of the code, not of the context.

## What the boundary cost, and what it caught

Recorded because the criterion's value is in what it surfaced, not in the green line:

1. **A normative gap only an outsider could see.** The plugin-error → §21 mapping was not
   derivable from the specification; §13 required a "missing-resource error" without ever
   giving it a shape. Fixed as **§12.2**, in the spec itself, because a normative rule
   living outside the normative document was the gap. That author predicted, *in advance
   and pushed before seeing the fix*, that it would have returned a bare atom or a
   3-tuple — **and that all of its own tests would still have passed**, failing only on
   contact with this engine, on the least-exercised path it has.
2. **An error in this library's own documentation.** `PLUGIN_AUTHORS.md` justified
   operation atomicity with a mutable-language failure mode that does not exist on the
   BEAM. An author following it would have written a test that passes against the wrong
   implementation.
3. **An error in this library's advice.** A byte-equality conformance corpus was
   recommended where no canonical form is specified. The corrected rule: byte-equality is
   a *conformance assertion* only where a canonical form is specified, and a *tripwire*
   otherwise.

None of the three was reachable from inside this repository.

---

## Two claims about §42.10 that look contradictory and are not

`conformance/README.md` states that **that corpus cannot validate §42.10**, because every
plugin it exercises shares an author with the engine. This document states §42.10 **is**
demonstrated. Both are correct; they rest on different evidence.

| Evidence | What it can show |
| --- | --- |
| `conformance/` corpus | Breadth — that the engine and its own plugin obey the spec across 33 cases |
| This integration run | The **boundary** — that a foreign plugin drops into an unchanged engine |

A corpus written here can never establish the boundary, however large it grows. That is
the point of keeping both statements.

## Provenance note on commit `6d2725b`

That commit's message describes only this §42.10 work, but it also contains the whole of
the Task 10 conformance corpus — 79 files. Two agents were working in one worktree and a
`git add -A` from this side swept in the other's untracked work.

Nothing is missing or wrong at that commit, and the history is **not** rewritten: an
outside repository already depends on this branch, and force-pushing to improve a commit
message is a bad trade against a downstream consumer. This note is the repair.

**Process fix:** never `git add -A` in a worktree another agent may be using — stage
explicit paths — and do not run two implementers in one worktree at all.
