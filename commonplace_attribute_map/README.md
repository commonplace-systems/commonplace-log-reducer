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
