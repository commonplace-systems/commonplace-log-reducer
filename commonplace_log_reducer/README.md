# commonplace_log_reducer

The projection engine: it turns **one ordered single-writer log** into **named,
epoch-scoped views**, deterministically.

Reduction is a pure function of the durable entries, the trusted registry, and explicitly
supplied immutable resources. No clock, no randomness, no I/O, no ambient authority
(spec §§13, 20, 22).

```elixir
{:ok, registry} = Commonplace.LogReducer.Registry.build(%{{"my.reducer", 1} => MyPlugin})
{:ok, state}    = Commonplace.LogReducer.new(log_id, registry)
{:ok, state}    = Commonplace.LogReducer.reduce(state, entries)
{:ok, view}     = Commonplace.LogReducer.view(state, "attributes")
```

## What it owns

| | |
| --- | --- |
| §6, §17 | entry-chain validation: log identity, writer identity, sequence and predecessor continuity |
| §§7–11 | the reducer envelopes, projection names, and the host-supplied registry |
| §§9.1, 10.1, 14–16 | epochs, operation routing, ordered reduction, head tracking |
| §18 | views — one **shared** head across every projection in a state |
| §§19–20 | checkpoints, restoration, and RFC 8785 canonical JSON |
| §21 | the closed set of fifteen error codes |

## What it does **not** own

- **Any projection's meaning.** The engine knows epochs, ordering, and heads. What a base
  or an operation *means* lives entirely in a plugin.
- **Log persistence, and reading the log.** It is handed entries; it never fetches them.
- **Head verification on restore.** §19 makes that the caller's obligation — the engine has
  no log and, by §22, no authority to go and read one. See
  `Commonplace.LogReducer.Checkpoint`'s moduledoc for the half that *is* enforced locally.
- **Resource acquisition.** A plugin needing an external resource returns
  `missing_resource`; it never fetches. Resources arrive through `:resources`.
- **Any plugin.** The engine names no reducer plugin anywhere in `lib/`, and
  `test/dependency_test.exs` enforces that with a positive control. That boundary is what
  makes §42.10 meaningful.
- **Multi-writer logs.** A second writer id is `multiwriter_document_unsupported`. This is
  a stated limit of version 1, not an oversight (§40).
- **That a lane begins with a version epoch.** A writer lane is *expected* to begin with
  an epoch for the `"version"` projection (a once-set format stamp, ruled 2026-08-25).
  **The engine does not enforce this.** Entry 1 is reduced like any other entry; a lane
  whose first entry is something else is accepted. The convention is enforced by
  commonplace-doc's open path and nowhere in the format. **A consumer that requires it
  must check for it itself.**

## Running the tests

```
mix test                                  # 214 tests, 11 properties
mix test test/conformance_test.exs        # the reducer-engine corpus alone
mix test test/properties_test.exs         # the §39 properties alone
mix format --check-formatted
```

A **full** run also fires the §21 reachability gate in `test/test_helper.exs`: an
`ExUnit.after_suite/1` hook that fails the run's exit status unless all fifteen §21 codes
were emitted by a real assertion. It is deliberately quiet on filtered runs (which
legitimately emit fewer) and on red runs (which explain themselves). It prints a SELECTOR
block after a green run saying what green does not mean.

From the repository root, `../conformance/check.sh` runs this suite together with the
plugin's and the byte rules over the corpora.

## Further reading

- `docs/PLUGIN_AUTHORS.md` — write a plugin without reading `lib/`.
- `docs/ACCEPTANCE.md` — the §42 criteria, each mapped to a runnable artifact.
- `docs/proposals/2026-08-22-commonplace-log-reducer-and-attribute-map-spec.md` — the
  normative specification. Where this README and the spec disagree, the spec wins.
