# Writing a reducer plugin

**Audience:** you are implementing a reducer plugin in your own repository, against
`commonplace-log-reducer`.

**Read this instead of our source.** If you can only build your plugin by reading our
internals, the boundary this library claims to have does not exist. Everything you need
is below or in the specification; if you find yourself opening `lib/`, that is a defect
in this document — please say so.

**The normative source is**
[`docs/proposals/2026-08-22-commonplace-log-reducer-and-attribute-map-spec.md`](proposals/2026-08-22-commonplace-log-reducer-and-attribute-map-spec.md)
(sha256 `248cf8f44eff61ea37ff0e05e660ddc2b95d86d363f24d249bcad5dfbe24a038`). Section
references below (`§12`) are to it. **Where this document and the spec disagree, the
spec wins and this document is wrong.**

---

## What a plugin is

The engine owns log ordering, epochs, heads, and failure coordinates. It never knows
what your data *means*. A plugin is the only place projection-specific meaning lives:
it interprets an epoch base, applies operations in log order, and produces a view.

A projection is a named interpretation of one append-only log. One log may carry many
projections (`attributes`, `content`, your own) with different plugins, evolving
independently over a shared head.

---

## The contract, in one table

| You provide | The engine provides |
| --- | --- |
| Seven callbacks (§12) | Ordering, gap/fork detection, single-writer enforcement |
| Validation of every base, operation, and checkpoint | Epoch lifecycle, parent chains, duplicate-epoch rejection |
| A deterministic pure function | The failing coordinate, the §21 error code, head tracking |
| JSON-compatible views and JSON-object checkpoints | Serialization of the enclosing checkpoint |

---

## 1. The seven callbacks (§12)

```elixir
defmodule MyReducer.V1 do
  @behaviour Commonplace.LogReducer.Plugin

  # apply/3 collides with Kernel.apply/3. Without this line the definition
  # below is a compile error. Every plugin hits this.
  import Kernel, except: [apply: 3]

  @impl true
  def reducer_id, do: "example.my-reducer"

  @impl true
  def reducer_version, do: 1

  @impl true
  def init(base, context), do: {:ok, state}

  @impl true
  def apply(operation, context, state), do: {:ok, state}

  @impl true
  def view(state), do: {:ok, json}

  @impl true
  def checkpoint(state), do: {:ok, map}

  @impl true
  def restore(checkpoint, context), do: {:ok, state}
end
```

Exact signatures:

| Callback | Returns |
| --- | --- |
| `reducer_id()` | `String.t()` |
| `reducer_version()` | `pos_integer()` |
| `init(base :: map(), context)` | `{:ok, state} \| {:error, term}` |
| `apply(operation :: map(), context, state)` | `{:ok, state} \| {:error, term}` |
| `view(state)` | `{:ok, json} \| {:error, term}` |
| `checkpoint(state)` | `{:ok, map} \| {:error, term}` |
| `restore(checkpoint :: map(), context)` | `{:ok, state} \| {:error, term}` |

`state` is **any immutable Elixir term** — it never leaves the BEAM. Only `view/1` and
`checkpoint/1` cross the boundary as user-facing or durable representations.

### What the engine has already checked before calling you

The engine validates the *envelope* before your callback runs, so by the time you are
invoked: the body is a JSON object, its `projection` name is valid, its `epoch_id` is a
lowercase canonical UUID, the field set is exactly right, **and `base` (§9) and
`operation` (§10) are each already confirmed to be JSON objects.**

⚠️ **Validate them anyway.** §12.1 requires you to validate every base and every
operation, and a plugin is directly callable — by your own tests, by a future host, by a
tool. It means a reason like `base_not_object` is unreachable *through the engine* and
reachable only by a direct call; keep it, and know that a conformance vector driven
through the engine cannot exercise it.

What the engine does **not** check is anything semantic: the shape of your operation
beyond "is an object", your key rules, your value rules, your field sets. All yours.

`base`, `operation`, and `checkpoint` arrive as **string-keyed maps** decoded from JSON.
Keep them string-keyed. Never convert a key or value from durable content into an atom
(§11, §22) — that is how untrusted log content reaches your module namespace.

---

## 2. The context (§13)

```elixir
%Commonplace.LogReducer.Context{
  log_id:          ...,
  writer_id:       ...,
  writer_seq:      ...,
  entry_id:        ...,
  projection:      ...,
  epoch_id:        ...,
  reducer_id:      ...,
  reducer_version: ...,
  resources:       %{}   # defaults to empty
}
```

**It is plain data and contains no ambient authority** — no pids, ports, references, or
functions. You cannot call anything through it, by design.

`resources` is a caller-supplied map of immutable resource identifiers to already-resolved
bytes or JSON. **If you need a resource you do not have, return
`{:error, {:missing_resource, key}}`.** Do not fetch it. Resource acquisition happens
outside deterministic reduction; a plugin that reaches out is not replayable.

---

## 3. Registration (§11)

The host — not the log — chooses which code runs:

```elixir
%{
  {"example.my-reducer", 1} => MyReducer.V1
}
```

Keys are `{id_binary, version_integer}`. **`reducer_id/0` and `reducer_version/0` must
return exactly the id and version you are registered under.** This is checked at
registry construction, not at reduce time, so a mismatch is a startup error rather than
a run that silently produces checkpoints labelled with the wrong reducer.

Concretely, `Commonplace.LogReducer.Registry.build(%{{id, version} => module})` returns
`{:ok, registry} | {:error, {:invalid_registry, reason}}` and is where the identity check
happens, and `Registry.resolve(registry, id, version)` returns
`{:ok, module} | {:error, %Error{code: :unknown_reducer}}`. Those two are all you need to
write your own identity test.

Durable log entries name your reducer only by that `{id, version}` string pair. They
never name an Elixir module, and the engine will not fall back to a different version:
an unregistered version halts reduction at that entry with `unknown_reducer`.

**Reducer protocol version is not your package version.** It identifies durable
semantics and wire shapes. Bump it when the meaning of your bases, operations, or
checkpoints changes — not when you release.

---

## 4. How your errors become engine errors

**This mapping is not in the spec.** It is this library's contract, and it is the one
thing here you could not derive yourself:

| Your callback returns `{:error, reason}` | Engine reports §21 code |
| --- | --- |
| `init/2` | `invalid_epoch_base` |
| `apply/3` | `invalid_operation` |
| `restore/2` | `invalid_checkpoint` |
| `checkpoint/1` | `invalid_checkpoint` |
| **any of the above**, when `reason` is `{:missing_resource, key}` | `missing_resource` |

The last row overrides the others.

`{:missing_resource, key}` is the **only** reason shape the engine inspects. Every other
`reason` is opaque: it is carried verbatim into the error's `details.reason` and the
engine never branches on it. So return whatever is most useful to a human — an atom, a
tuple, a map — and pin **stable atoms or slugs** in your own tests rather than message
strings. Messages are not protocol identifiers.

An error from `view/1` is **not** a §21 code. It surfaces to the caller directly,
because producing a view neither reduces an entry nor moves the head.

---

## 5. What you must guarantee (§12.1)

- **Return the exact registered id and version.**
- **Validate every base you initialize**, every operation addressed to you, and every
  checkpoint before restoring it.
- **Never silently ignore an operation addressed to you.** If you do not understand it,
  fail. The engine stops at that entry; silence would let history diverge invisibly.
- **Be a pure function of `(state, operation, context, resources)`.** No wall-clock, no
  randomness, no process identity, no global mutable state, no network. Two runs over
  the same log prefix must produce identical views and checkpoints (§20).
- **Views must be JSON-compatible. Checkpoints must be JSON objects.**

⚠️ **Do not read `created_at` for anything** — not ordering, not conflict resolution,
not overwrite semantics (§6). Order is writer sequence, full stop. A plugin that uses
timestamps will pass its own tests and diverge in replay.

---

## 6. Epoch bases are replacements, not patches

An epoch is one incarnation of a projection's state history. When a new epoch begins,
your `init/2` receives the new base and **the previous in-memory state is discarded**.
The base must be self-contained: you are never handed an opaque state value belonging to
a previous reducer module.

The old history stays in the log. It is simply no longer the current interpretation.

---

## 7. Checkpoints are derived, disposable, and yours alone

Your `checkpoint/1` returns only *your* state. It must **not** include log id, writer id,
head, projection name, epoch id, or reducer identity — those belong to the enclosing
engine checkpoint, and duplicating them creates two sources of truth that can disagree.

`restore/2` must validate its input with the same rigor as `init/2`. A checkpoint is
derived data that may be stale, truncated, or corrupt; it establishes no authority and
never permits entries to be skipped.

A useful property to hold yourself to: **`checkpoint` then `restore` must produce a
state whose view is identical**, and a checkpoint plus the remaining log suffix must
equal a full replay.

### Path-dependent internal state is allowed — but read the boundary carefully

Your internal representation may legitimately depend on the *order* in which operations
arrived, even when the resulting view does not. A CRDT is the standard case: converging
views, but an item store whose block boundaries differ depending on which edit landed
first.

⭐ **That is fine here, and the reason is worth understanding rather than trusting.**
Inside this engine the order is *fixed by the log*. Full replay and checkpoint-plus-suffix
traverse the same operations in the same sequence, so they reach the same internal state
and the same bytes. The equivalence this library requires is not "order-independent", it
is "same order, same result".

⚠️ **Where it bites is outside that boundary**: comparing state built from a different
linearization of the same history, or across replicas that received operations in
different orders. If your checkpoint encodes a path-dependent structure directly, two
histories that are semantically identical can produce different checkpoint bytes.

⇒ **A safe pattern, if your encoding turns out to be path-dependent: checkpoint the
ordered list of applied operations rather than the derived structure.** Replay from it is
identical by construction, and canonicalization is sidestepped entirely. It costs size
and buys byte-identity. Verify which case you are in — do not assume a sorted encode path
is sufficient, because sorting the output does not remove path-dependence that lives in
the structure being encoded.

---

## 8. A conformance checklist for your plugin

Derived from §38/§39. If your plugin passes these, it is very likely correct:

**Cases**
- [ ] initialization from an empty base
- [ ] initialization from a non-empty base
- [ ] a base with a missing field is rejected
- [ ] a base with an *additional* field is rejected
- [ ] each operation type applies correctly
- [ ] an unknown operation type is rejected
- [ ] an operation with an additional field is rejected
- [ ] a rejected operation leaves state **completely** unchanged
- [ ] a multi-part operation is atomic — validate everything, then apply everything
- [ ] epoch replacement uses a complete base and discards prior state
- [ ] checkpoint round-trips through restore
- [ ] a malformed checkpoint is rejected
- [ ] no field of the context changes the result — the plugin-level form of the
      `created_at` rule (see below)

**Properties**
- [ ] full replay == checkpoint restore + suffix replay
- [ ] arbitrary batch splits produce the same state
- [ ] every rejected operation leaves state unchanged
- [ ] replay produces byte-identical canonical views and checkpoints

⭐ **The atomicity case — and a correction, because the obvious rationale is wrong on
the BEAM.**

An earlier version of this document said: "the natural implementation validates and
applies in a single fold, so a five-part operation whose last part is invalid has
already applied the first four." **That is a mutable-language failure mode and it does
not exist here.** Plugin state is an immutable term. A partially-built map that is never
returned cannot be observed by anyone, so a fold that ends in `{:error, reason}` *is*
atomic. Measured, not argued: rewriting the first plugin's patch path as a
validate-and-apply fold left its atomicity test green, correctly.

⇒ **The reachable bug in Elixir is different: returning `{:ok, partial}` instead of
`{:error, reason}`.** A fold that halts on an invalid part and returns the accumulator
applies everything before the failure and reports success — which is also a §12.1
violation ("MUST NOT silently ignore an operation addressed to it"), because the engine
advances the head over an operation that was never fully applied.

So write the test to assert **both**: that an invalid multi-part operation returns an
error, *and* that the returned state is unchanged. Asserting only "state unchanged" will
pass against the wrong implementation.

The advice is still validate-everything-then-apply-everything — it is clearer and it
generalizes to plugins holding mutable resources. Only the stated failure mode was
wrong.

⭐ **The `created_at` case is the one nobody writes — but you cannot write it alone.**
A plugin never sees `created_at`; the engine strips it and never passes it on. So the
engine owns the end-to-end version (re-run a history with timestamps shuffled; assert
view, checkpoint, *and* failure coordinate are unchanged).

Your plugin-level equivalent is stronger and is worth writing: **vary every field of the
`%Context{}` and assert the result does not change.** The context is the only channel
through which ambient information could reach you, so if nothing in it moves your
output, nothing outside your state and operation can.

---

## 9. Depending on this package

Not yet published to Hex. Use a git dependency:

```elixir
{:commonplace_log_reducer,
 git: "git@github.com:commonplace-systems/commonplace-log-reducer.git",
 sparse: "commonplace_log_reducer"}
```

The repo holds two mix projects; `sparse:` selects the engine. Do **not** depend on
the attribute-map plugin — plugins are siblings, not layers.

---

## 10. Please report these

This library claims a plugin boundary it cannot yet prove. Every plugin in this repo
shares an author with the engine, which is the arrangement that *hides* accidental
coupling rather than exposing it (§42.10 is explicitly recorded as **not demonstrated**).
Your plugin is the first real test of it.

So we want to hear about:

- anything you needed that is **not** in this document or the spec;
- anywhere you had to read our source to proceed;
- any engine change your plugin required — **that would mean the core API is not
  plugin-general**, which is exactly what §42.10 is meant to catch;
- any place the spec is ambiguous enough that two implementers would diverge.

A plugin that drops in without changing the engine is what turns §42.10 from an
unproven claim into a demonstrated one.
