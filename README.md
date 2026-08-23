# commonplace-log-reducer

Generic projection engine over [commonplace-log](https://github.com/commonplace-systems/commonplace-log),
plus the `commonplace-attribute-map` reducer plugin **in this same repo** (jes, 2026-08-23).

Dependency direction: `commonplace-log` → `commonplace-log-reducer` → reducer plugins.
This library consumes validated entries from commonplace-log; it does not own log
persistence, BEAM process lifecycle, Document messaging, Cell authority, capabilities,
Realm placement, or replica synchronization.

## Where the code is

⚠️ **`main` is documentation only. The implementation lives on branch `sol/impl`**
(worktree `.worktrees/impl`) and is merged back when the plan completes. Checking `main`
alone gives the false impression that nothing is built.

As of 2026-08-23 that branch has the engine through the §16 processing algorithm —
error codes, envelope validation, registry, plugin behaviour, chain validation, and
epoch/operation routing — at 133 passing tests.

## Status

**The implementation lives on the `sol/impl` branch. `main` is still docs-only — no merge
has happened.** Read this file from the branch you are on: on `main`, the packages below
describe work that is complete on `sol/impl` and not yet merged.

On `sol/impl`, as of 2026-08-23:

| | |
| --- | --- |
| `commonplace_log_reducer` | 214 tests, 11 properties, 0 failures |
| `commonplace_attribute_map` | 99 tests, 13 properties, 0 failures |
| Conformance corpora | 19 canonical-JSON + 18 reducer-engine + 19 attribute-map case directories |
| §21 error codes proven reachable by an assertion | **15 of 15** |
| §42 acceptance criteria | all ten mapped to a runnable artifact — see below |

```
./conformance/check.sh          # both suites, both corpora, the byte rules, exit 0
```

The direction document is filed byte-identical at
[`docs/proposals/2026-08-22-commonplace-log-reducer-and-attribute-map-spec.md`](docs/proposals/2026-08-22-commonplace-log-reducer-and-attribute-map-spec.md)
(sha256 `72828c72686f2ba9093bd9f2039e6630ef237a004c5f021e610a6b764f47594f`).
It is the source of truth for scope; this README summarizes and does not extend it.

## What is here

| Path | What it is |
| --- | --- |
| [`commonplace_log_reducer/`](commonplace_log_reducer/) | the engine: envelope validation, registry, ordered single-writer reduction, epochs, views, checkpoints |
| [`commonplace_attribute_map/`](commonplace_attribute_map/) | the reducer plugin: a JSON attribute map where the last operation in log order wins |
| [`conformance/`](conformance/) | language-neutral JSON vectors, plus `check.sh` |
| [`test_support/`](test_support/) | the shared test-only harness (canonical JSON, the vector runner, the §21 code recorder) |
| [`docs/`](docs/) | the specification, and the three documents below |

## The three documents worth reading

- **[`docs/PLUGIN_AUTHORS.md`](docs/PLUGIN_AUTHORS.md)** — the plugin-author contract: the
  seven callbacks, the context, registration, the plugin-error mapping, and a conformance
  checklist. Written to be sufficient on its own: if you have to read `lib/` to build a
  plugin, that is a defect in the document, and we want to hear about it.
- **[`docs/ACCEPTANCE.md`](docs/ACCEPTANCE.md)** — the §42 acceptance record. Each of the
  ten criteria mapped to the exact test, property, or vector that demonstrates it, with the
  command to run it, and the gaps stated where the evidence is a composition rather than a
  single end-to-end run.
- **[`docs/42-10-PLUGIN-BOUNDARY.md`](docs/42-10-PLUGIN-BOUNDARY.md)** — §42.10, the
  plugin boundary, and what it cost. **Demonstrated:** an independently authored plugin, in
  a different repository by an author who never opened this library's `lib/`, took this
  engine as a real git dependency and ran a real log through `reduce/3` with **no engine
  change**. That is a boundary demonstration by *one* foreign plugin — not plugin
  generality. Read its "what this does NOT establish" section before citing it.

## The seven distinctions (§40)

The specification requires the documentation to make these explicit. Each is stated where a
reader actually meets it, not only in this list; the list is an index.

| Distinction | Stated in |
| --- | --- |
| A projection epoch is **not** a log branch | `Commonplace.LogReducer.Projection` |
| A checkpoint is **not** canonical history | `Commonplace.LogReducer.Checkpoint` |
| Reducer version is **not** package version | `Commonplace.LogReducer.Plugin` |
| Attribute overwrite order is **log sequence, not wall time** | `Commonplace.AttributeMap.V1` |
| Raw replica synchronization is **not** semantic Document synchronization | `Commonplace.LogReducer` |
| Plugins are **trusted installed code**, not code named directly by untrusted input | `Commonplace.LogReducer.Registry` |
| **Multi-writer reduction is unsupported in version 1** | `Commonplace.LogReducer.State` |

## Running everything

```
./conformance/check.sh                                   # the whole thing
cd commonplace_log_reducer   && mix test                 # 214 tests, 11 properties
cd commonplace_attribute_map && mix test                 # 99 tests, 13 properties
mix format --check-formatted                             # in each project, and at the root
```

A full engine run also fires the **§21 reachability gate**: an `ExUnit.after_suite/1` hook
that fails the run unless every one of the fifteen §21 error codes was emitted by a real
assertion during it. A declared code that nothing can provoke is a documented behaviour
with no implementation. The gate is gated to full runs — a filtered run legitimately emits
fewer codes — and stands down when the suite is red, because a red suite explains itself.
Both arms are recorded in [`docs/ACCEPTANCE.md`](docs/ACCEPTANCE.md).

## What a green run does not mean

`conformance/check.sh` and the engine suite each print a SELECTOR block saying so. In
short: the corpora are not exhaustive, a vector that disagrees with the specification is
the bug, §42.10 is demonstrated *once* rather than generally, and everything outside
reduction — persistence, process lifecycle, Document messaging, authority, replication — is
owned elsewhere and is not exercised here at all.
