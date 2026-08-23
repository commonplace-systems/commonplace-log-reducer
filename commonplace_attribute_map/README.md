# commonplace_attribute_map

The reducer plugin: a **deterministic JSON attribute map** over one ordered log, where the
last operation in **log order** wins. It is the smallest useful proof that the plugin
boundary carries real meaning.

| | |
| --- | --- |
| Reducer ID | `commonplace.attribute-map` |
| Reducer protocol version | `1` |
| Default projection name | `attributes` (a default, not a constraint) |
| View | a JSON object — the map itself, no wrapper |
| External resources | none |

```elixir
{:ok, registry} =
  Commonplace.LogReducer.Registry.build(Commonplace.AttributeMap.registry_entries())
```

Operations are `put`, `delete`, and `patch` (spec §§27–29). A `patch` succeeds or fails
**atomically**: every key, every value, and both cross-checks pass before any change is
constructed.

## There is no conditional write, and that is deliberate

The three operations — `put`, `delete`, `patch` — are **all unconditional**. There is no
compare-and-swap: you cannot express *"set `k` to Y only if it is currently X."*

This was asked for (a CAS operation, to guard `commonplace.content.head` against a
concurrent rollback) and **ruled closed on 2026-08-23 — closed, not deferred.** The
reasoning, which is better than the instruction:

> The LWW reducer answers a **projection** question. Expected-head answers an
> **admission** question. They are different questions at different layers.

⭐ **A conditional guard belongs above the log, at admission — before append.** By the
time an operation is durable it is already ordered, and it *will* be applied.

⚠️ **And a validation rule added to a reducer is a rule applied to the PAST.** This code
runs at fold time, replaying permanent history. Add a rule here and every already-appended
log that violates it stops replaying — the reduction halts and the projection becomes
unreadable from that entry on. For an engine whose whole job is deterministic replay, that
converts a policy change into data loss.

⇒ So if you are composing this plugin with a merging projection (a CRDT, say), note the
asymmetry: **content merges, an attribute pointing at it overwrites.** Two parties
advancing a head attribute from the same base yield a converged document whose head
reflects only one of them, with no error — the second `put` is perfectly valid. That is not
a defect in either plugin; it is a property of the composition, visible only to the layer
that sees both, and the guard for it lives there.

## Reserved keys are convention, not semantics

This plugin enforces **no** key namespace, prefix rule, or reserved-key list. Measured, not
recalled: the complete key validator is five rules — non-empty, valid UTF-8, no null code
point, at most 1024 UTF-8 **bytes**, otherwise accepted. `commonplace.*` reaches storage
unimpeded, and an ordinary `put` will overwrite `commonplace.content.head`.

Anything relying on a reserved-key rule must enforce it at admission and must not assume a
naming convention is enforced below it.

## Two distinctions this package exists to keep

- **Overwrite order is log sequence, not wall time (§40).** The later entry in the writer
  sequence wins, whatever `created_at` says. Nothing here reads timestamps, entry UUIDs, a
  clock, or any context field. A caller that sorts by `created_at` before feeding entries
  in has changed the answer, and this plugin cannot detect that. Feed entries in log order.
- **Null is present; deletion is absent (§§24, 42.9).** `put` with a `null` value leaves the
  key present holding null. Only `delete` makes a key absent, and the view carries no
  tombstones. The two never collapse — every absence assertion in the property suite is
  `Map.has_key?/2`, never a comparison against `nil`.

## What it does **not** own

- **Ordering, epochs, heads, and error classification.** Those are the engine's. This
  plugin sees an operation, a context, and its own state, and returns new state or an
  error term; the engine decides which §21 code that becomes.
- **Its own projection name.** The name is chosen by whoever writes the epoch entry (§7).
  This reducer never inspects it.
- **Persistence.** `checkpoint/1` returns a value. Storing it is somebody else's job.
- **Any process, supervisor, or state.** There is none here; it is pure functions.

## Running the tests

```
mix test                                  # 99 tests, 13 properties
mix test test/conformance_test.exs        # the attribute-map corpus alone
mix test test/properties_test.exs         # the seven §39 properties, plus the created_at one
mix format --check-formatted
```

From the repository root, `../conformance/check.sh` runs this suite together with the
engine's and the byte rules over the corpora.

## Further reading

- `docs/ACCEPTANCE.md` — §42.9 (null vs deletion) and §42.4 (overwrite order) are mapped to
  the exact artifacts that demonstrate them.
- `docs/PLUGIN_AUTHORS.md` — the contract this package implements.
