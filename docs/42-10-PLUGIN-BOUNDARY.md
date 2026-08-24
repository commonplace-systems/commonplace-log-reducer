# §42.10 — the plugin boundary, demonstrated

**Status: DEMONSTRATED, 2026-08-23. REOPENED AND RE-DEMONSTRATED, 2026-08-24** -- see
[the reopening](#reopened-2026-08-24-plugin_call4) below. Previously recorded as *not
demonstrated*.

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

## The controls — added after the fact, and they found something

⚠️ **The first time this ran I read the green output and believed it, without ever
controlling the instrument that carried the discriminating power.** Every gate in this
repository is held to "show it can go red"; the run that demonstrates the repo's hardest
criterion was not. Corrected:

| Control | Expected | Result |
| --- | --- | --- |
| change the input text | the view must change | `%{"text" => "GOODBYEMOON"}` ✅ |
| corrupt the update payload | must not print a clean view | `code: :invalid_operation` ✅ |
| register under a wrong id | the identity check must bite | `{:reducer_id_mismatch, %{registered: "wrong.id", reported: "commonplace.merkle-crdt"}}` ✅ |

⭐ **And running them found a real defect in this document: the committed reproduction
script no longer reproduced.** The plugin's epoch-base shape changed from
`{version, applied}` to `{version, entries}` when its author unified base and checkpoint
under one validator. The script was pinned to nothing, so "reproduce with `mix run …`"
had silently stopped being true.

⛔ **That is the same defect class as an unpinned hash**, and it is worse here because
the failure is silent to anyone who does not run it. **A reproduction script that depends
on a moving external repository is only valid at a stated commit.**

### Versions this was verified at

| | |
| --- | --- |
| engine (this repo) | `sol/impl`, unchanged across both runs |
| plugin, first run | `f7bb085` — base shape `{version, applied}` |
| plugin, re-verified | `53df66e` — base shape `{version, entries}` |

The script in this repo tracks the **later** shape. If it fails against a future plugin
commit, that is the plugin's format moving, **not** §42.10 regressing — the engine is the
invariant here, and it did not change between the two runs.

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

---

## Reopened 2026-08-24: `plugin_call/4`

commonplace-doc needed to reach the merkle plugin's `assemble/2`, which takes the
plugin's `%State{}` -- a value that lives inside `%Projection{state:}` inside the engine.
It declined to read `engine.projections["content"].state`, on the rule commonplace-log
established the same day: **an accessor that returns an internal handle grants every
operation that handle permits, not just the one the caller wanted. Move the operation
inside the boundary; never move the handle outside it.**

The engine's public surface was `view/2` and `views/1`. It is now also
`plugin_call(state, name, fun, args)`: the engine resolves the projection, and calls
`fun` on the module that owns it with the plugin state first. The state is handed only
to the module that produced it; the caller sees neither the state nor the module. The
closure shape (`with_projection(state, name, fn module, plugin_state -> ... end)`) was
rejected because `fn _, s -> s end` is a closure: it makes leaving the boundary a
deliberate act rather than an impossible one. The engine's own behaviour callbacks are
refused (`{:reserved_callback, ...}`): running `apply/3` or `checkpoint/1` against a
live state out of band is the reach-in by another route.

This changed the engine, so per this document the criterion reopened rather than being
patched around. Both runs below were made against the engine **with** `plugin_call/4`,
in a scratch copy of the plugin repository with the engine as a path dependency.

| Run | Plugin commit | Result |
| --- | --- | --- |
| `docs/42-10-integration-proof.exs` | `53df66e` (the commit this document pinned) | **byte-identical** to the measured output above |
| `docs/plugin-call-probe.exs` | `31e6dca` (plugin HEAD, `reducer_version` 3) | below |

The proof script does **not** run against plugin HEAD: the plugin now reports
`reducer_version` 3 and requires `epoch_id` on every commit, so registration fails with
`reducer_version_mismatch` -- the plugin's format moving, exactly as the "Versions"
section predicted, not the engine regressing. The probe script tracks the v3 shape.

```
view              : %{"graph" => ..., "roots" => %{epoch => %{"t" => %{"kind" => "text", "value" => "helloworld"}}}}
assemble(i2)      : {:ok, {:ok, %Yelixer.Doc{...}}}
control i1 != i2  : true
unknown commit    : {:ok, {:error, {:unknown_commit, "nope"}}}
apply/3 reserved  : {:error, {:reserved_callback, "content", :apply, 3}}
checkpoint/1 resv : {:error, {:reserved_callback, "content", :checkpoint, 1}}
no such fun       : {:error, {:undefined_plugin_function, "content", :assemble, 1}}
unknown projection: {:error, {:unknown_projection, "nope"}}
state untouched   : true
```

What each line establishes: the plugin's own function is reachable with its real state
(`assemble`); the result depends on the state, so the instrument discriminates (`i1 != i2`);
the plugin's own errors pass through unwrapped inside `{:ok, _}`; the three engine-side
refusals fire; and the engine state is unchanged afterwards.

**What this does not change:** the plugin was written without `plugin_call/4` existing and
needed no change to be reached through it -- the behaviour module is untouched. The
independence caveats above still hold, and now there is one more: the author of this door
is the engine's author, and its first consumer had not yet used it when this was written.
