# Commonplace Log Reducer + Attribute Map Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the generic projection engine (`commonplace-log-reducer`) and its first reducer plugin (`commonplace-attribute-map`) in this one repo, conforming to the filed spec.

**Architecture:** Two sibling Elixir mix projects in one git repo — `commonplace_log_reducer/` (engine, zero plugin knowledge) and `commonplace_attribute_map/` (plugin, path-deps on the engine). The one-way dependency is enforced *by the build graph*, not by convention: the engine's `mix.exs` cannot name the plugin without creating a cycle. A repo-root `conformance/` directory holds language-neutral JSON vectors shared by both, following the corpus conventions already established in `commonplace-log`.

**Tech Stack:** Elixir 1.18 / OTP 27, `jason` for JSON, `stream_data` for property tests. No database, no processes, no web framework, no network. The engine is pure functions over immutable state.

**Spec:** `docs/proposals/2026-08-22-commonplace-log-reducer-and-attribute-map-spec.md`
(sha256 `248cf8f44eff61ea37ff0e05e660ddc2b95d86d363f24d249bcad5dfbe24a038`).
Section references below (`§9.1`) are to that file. **The spec is normative and wins every
disagreement with this plan.** If you find a conflict, stop and report it rather than
picking one.

---

## Decisions this plan makes (and why)

These are interpretations, not transcriptions. They are the places to push back.

**D1 — Two mix projects in one repo.** The spec (§1, §37) describes two *libraries*;
jes directed that the attributes plugin live in *this* repo. Both hold: one repo,
two packages. The alternative (one mix project, two module namespaces) would make
§37.1's "MUST NOT depend on any reducer plugin" a claim enforced only by a grep test.
Two projects make it a fact about the build. Cost: two `mix test` invocations, one
`path:` dep. Cheap to collapse later; expensive to split later.

**D2 — No dependency on `commonplace-log` yet.** §37.1 says the package *SHOULD*
depend on commonplace-log for shared entry types "when doing so does not create a
dependency cycle". §6 already defines a complete input-entry contract, and the caller
owns canonical validation. Starting decoupled keeps this test suite free of a live
sibling's churn, and an adapter module is a later, additive task. **Consequence:** we
need our own RFC 8785 canonical JSON for conformance comparison (§20) — see D3.

*Confirmed by the `commonplace-log` worker on 2026-08-23 (measured, not recalled):
its Elixir API is moving this week — `append` is losing `writer_id` from the caller's
hands, the read path changed today, and a `Commonplace.Log.DocumentProfile` façade
lands next. It recommended staying decoupled and pointing any future adapter at the
stable seam — the **canonical entry bytes**, not module names. Three facts that shape
the deferred adapter task, recorded here so they are not lost:*

1. *Its read call returns `canonical_bytes`, not a parsed map. **Decode the bytes;
   the SQL projection columns are a convenience view and have disagreed with the bytes
   in the same row before.** The bytes are the entry.*
2. *A decoded entry has **eight** keys, not §6's seven — there is also
   `version` (integer `1`). §6 says "at least", so this is compatible; the adapter
   should hard-reject an unexpected `version` rather than ignore it.*
3. *The single-writer restriction lives in the forthcoming façade, **not** in the
   storage layer — read through storage directly and a multi-lane log is still
   legitimately reachable. Our own §17 refusal is therefore load-bearing, not
   belt-and-braces. Keep it.*

**D3 — JCS lives in test support, validated against the sibling's vector corpus.**
Canonical JSON is only needed to *compare* views and checkpoints (§20, §38), never at
runtime. So it is `test/support/jcs.ex`, not a public module. Hand-rolling JCS is
exactly where subtle bugs hide (number formatting, escape selection), so we do not
trust ours until it passes the 18 already-proven vectors copied from
`~/commonplace-log/conformance/canonical-json/` — including `999-deliberate-mismatch`,
which must *fail*. Those vectors are language-neutral fixture files; copying them
couples us to no code.

**D4 — Contiguity is derived as `seq == head_seq + 1`, `prev == head_entry_id`.**
The spec never spells out the first sequence number, but §19 says "subsequent input
begins at `head.writer_seq` plus one with the correct predecessor", and the initial
state has `head_seq: 0, head_entry_id: nil` (§14). So a fresh engine requires the first
entry to have `writer_seq: 1` and `prev_entry_id: nil`. **Flag this to jes if wrong.**

**D5 — `seen_epoch_ids` is projection-scoped and survives epoch replacement.**
§9.1.3 forbids reusing an epoch ID *for that projection*, and §19 stores
`seen_epoch_ids` inside each projection. So when an epoch entry replaces a projection,
the rebuilt `Projection` struct must **carry the old set forward** and add the new ID.
Dropping it is the single easiest way to silently pass task 7 and fail conformance
case 9. There is a dedicated test for this.

---

## File structure

### `commonplace_log_reducer/` (app `:commonplace_log_reducer`)

| File | Responsibility |
| --- | --- |
| `lib/commonplace/log_reducer.ex` | Public API only: `new/3`, `reduce/3`, `view/2`, `views/1`, `checkpoint/1`, `restore/3` (§15). Delegates; holds no logic. |
| `lib/commonplace/log_reducer/error.ex` | The `Error` struct and the closed set of 15 codes (§21). |
| `lib/commonplace/log_reducer/context.ex` | The `Context` struct handed to plugins (§13). No ambient authority. |
| `lib/commonplace/log_reducer/plugin.ex` | The `@callback` behaviour (§12). Declarations only. |
| `lib/commonplace/log_reducer/registry.ex` | `{id, version} -> module` resolution (§11). Never creates atoms. |
| `lib/commonplace/log_reducer/envelope.ex` | Body classification + epoch/operation envelope validation + projection-name regex (§7, §8, §9, §10). |
| `lib/commonplace/log_reducer/projection.ex` | Per-projection struct (§14). |
| `lib/commonplace/log_reducer/state.ex` | Engine state struct + entry-chain validation + head tracking (§6, §14, §16, §17). |
| `lib/commonplace/log_reducer/engine.ex` | The §16 processing algorithm: classify, route, apply atomically, advance head. |
| `lib/commonplace/log_reducer/checkpoint.ex` | Encode/decode the §19 core checkpoint. |
| `test/support/jcs.ex` | Test-only RFC 8785 canonicalizer (D3). |
| `test/support/fixture_plugin.ex` | Trivial in-test plugins so the engine is tested with **no** dependency on attribute-map. |

### `commonplace_attribute_map/` (app `:commonplace_attribute_map`)

| File | Responsibility |
| --- | --- |
| `lib/commonplace/attribute_map.ex` | Package entry point + docs. |
| `lib/commonplace/attribute_map/v1.ex` | The plugin implementing the behaviour (§34). |
| `lib/commonplace/attribute_map/validation.ex` | Key rules (§25), I-JSON value rules (§24), exact-field checks, the §33 reason atoms. |

### Repo root

| Path | Responsibility |
| --- | --- |
| `conformance/README.md` | Corpus rules + the SELECTOR statement (what green does and does not mean). |
| `conformance/canonical-json/` | 18 vectors copied verbatim from `commonplace-log` (D3). |
| `conformance/reducer-engine/` | The 16 §38 engine cases. |
| `conformance/attribute-map/` | The 17 §38 plugin cases. |
| `conformance/check.sh` | Runs both suites; **must** exit non-zero when a `9xx-` case unexpectedly passes. |

---

## Conformance vector format

One directory per case: `conformance/<suite>/NNN-short-name/`, containing:

- `input.json` — `{"log_id":…, "registry":[{"id":…,"version":…,"plugin":…}], "entries":[…]}`.
  `plugin` names a *fixture* plugin key (e.g. `"attribute-map-v1"`, `"passthrough"`),
  never an Elixir module name — the corpus stays language-neutral (§11 forbids
  interpreting stored module names anyway).
- `expected.json` — exactly one of:
  - `{"ok": {"head": {...}, "projections": {...}, "views": {...}, "checkpoint": {...}}}`
  - `{"error": {"code": "stale_epoch", "writer_seq": 4, "entry_id": "…", "projection": "…", "head": {...}}}`
    where `head` is the head of the returned prefix state (§15.1).

Byte rules inherited from the sibling corpus: UTF-8, no BOM, LF only, exactly one
trailing LF. Numbering: next unused; **`9xx` reserved for deliberately-wrong cases**
that the harness must assert *mismatch*.

---

## Task list

Order follows §41's adoption sequence. Tasks 2–5 are independent of each other and
**may be dispatched in parallel**; task 6 onward is sequential.

---

### Task 1: Scaffold both projects and prove the boundary gate can go red

**Files:**
- Create: `commonplace_log_reducer/mix.exs`, `commonplace_attribute_map/mix.exs`
- Create: `commonplace_log_reducer/test/test_helper.exs`, `commonplace_attribute_map/test/test_helper.exs`
- Create: `commonplace_log_reducer/test/dependency_test.exs`
- Create: `.gitignore`

- [ ] **Step 1: Write `.gitignore`**

```
_build/
deps/
*.ez
erl_crash.dump
.elixir_ls/
```

- [ ] **Step 2: Write `commonplace_log_reducer/mix.exs`**

```elixir
defmodule CommonplaceLogReducer.MixProject do
  use Mix.Project

  def project do
    [
      app: :commonplace_log_reducer,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.1", only: [:test, :dev]}
    ]
  end
end
```

Note there is **no** entry for `:commonplace_attribute_map`. That absence is the
boundary (D1).

- [ ] **Step 3: Write `commonplace_attribute_map/mix.exs`**

Same shape, plus:

```elixir
  defp deps do
    [
      {:commonplace_log_reducer, path: "../commonplace_log_reducer"},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.1", only: [:test, :dev]}
    ]
  end
```

- [ ] **Step 4: Write both `test_helper.exs`**

```elixir
ExUnit.start()
```

- [ ] **Step 5: Write the boundary test with a positive control**

`commonplace_log_reducer/test/dependency_test.exs` — modelled on
`commonplace-log`'s `dependency_test.exs`:

```elixir
defmodule Commonplace.LogReducer.DependencyTest do
  use ExUnit.Case, async: true

  @lib Path.expand("../lib", __DIR__)
  @mixfile Path.expand("../mix.exs", __DIR__)

  test "the engine names no reducer plugin, with a positive control" do
    paths = Path.wildcard(Path.join(@lib, "**/*.ex"))
    assert paths != [], "positive control: found no engine sources to scan"

    source = Enum.map_join(paths, "\n", &File.read!/1)
    assert source =~ "LogReducer", "positive control: scanned sources are not the engine"

    for forbidden <- ["AttributeMap", "MerkleCRDT", "attribute-map", "merkle-crdt"] do
      refute source =~ forbidden
    end
  end

  test "mix.exs declares no plugin dependency, with a positive control" do
    source = File.read!(@mixfile)
    assert source =~ ":commonplace_log_reducer"
    refute source =~ ":commonplace_attribute_map"
  end

  test "the engine performs no I/O and loads no code dynamically" do
    paths = Path.wildcard(Path.join(@lib, "**/*.ex"))
    source = Enum.map_join(paths, "\n", &File.read!/1)

    for forbidden <- [
          "String.to_atom",
          "String.to_existing_atom",
          ":httpc",
          "File.read",
          "Code.ensure",
          ":os.timestamp",
          "DateTime.utc_now",
          ":rand."
        ] do
      refute source =~ forbidden, "engine must not contain #{forbidden} (§11, §12.1, §22)"
    end
  end
end
```

Every one of these asserts a **positive control first** — a scan that found no files,
or scanned the wrong files, returns "no forbidden strings" and looks exactly like a
pass. (See the repo's global rule on absence having more than one cause.)

- [ ] **Step 6: Prove the gate can go red**

```bash
cd commonplace_log_reducer && mix deps.get && mix test test/dependency_test.exs
```
Expected: PASS (3 tests).

Now temporarily add `# AttributeMap` as a comment in any `lib/**.ex` file (create
`lib/commonplace/log_reducer.ex` with just a module stub if none exists yet), re-run,
and **observe the failure**. Revert. Record both outcomes in the commit message. A gate
never seen to fail is not known to work.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "scaffold: two mix projects, one repo; boundary gate demonstrated red and green"
```

---

### Task 2: Error struct and the closed code set (§21)

**Files:**
- Create: `commonplace_log_reducer/lib/commonplace/log_reducer/error.ex`
- Test: `commonplace_log_reducer/test/error_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Commonplace.LogReducer.ErrorTest do
  use ExUnit.Case, async: true
  alias Commonplace.LogReducer.Error

  @codes ~w(
    log_mismatch writer_gap writer_fork multiwriter_document_unsupported
    invalid_reducer_envelope invalid_projection_name unknown_reducer
    duplicate_epoch epoch_parent_mismatch projection_not_initialized
    stale_epoch invalid_epoch_base invalid_operation missing_resource
    invalid_checkpoint
  )a

  test "every §21 code is declared" do
    assert Enum.sort(Error.codes()) == Enum.sort(@codes)
  end

  test "codes are a closed set" do
    assert length(Error.codes()) == 15
    refute :not_a_real_code in Error.codes()
  end

  test "an error carries the stable code and failing coordinate" do
    e = Error.new(:stale_epoch, log_id: "L", writer_seq: 47, entry_id: "E",
                  projection: "content", details: %{expected: "a", actual: "b"})

    assert %Error{code: :stale_epoch, writer_seq: 47, entry_id: "E",
                  projection: "content"} = e
    assert e.details == %{expected: "a", actual: "b"}
  end

  test "an unknown code is rejected rather than silently accepted" do
    assert_raise ArgumentError, fn -> Error.new(:made_up, log_id: "L") end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

`cd commonplace_log_reducer && mix test test/error_test.exs`
Expected: FAIL — `Commonplace.LogReducer.Error` is undefined.

- [ ] **Step 3: Implement `error.ex`**

Struct fields: `code, log_id, writer_seq, entry_id, projection, details`.
`codes/0` returns the 15 atoms as a module attribute list. `new/2` raises
`ArgumentError` unless `code in @codes`. Human-readable messages are **not**
protocol identifiers (§21) — do not derive behaviour from message text.

- [ ] **Step 4: Run to verify it passes.** Expected: PASS (4 tests).

- [ ] **Step 5: Commit** — `feat(engine): §21 error struct with a closed 15-code set`

---

### Task 3: Envelope validation (§7, §8, §9, §10)

**Files:**
- Create: `commonplace_log_reducer/lib/commonplace/log_reducer/envelope.ex`
- Test: `commonplace_log_reducer/test/envelope_test.exs`

This module is pure: body map in, classification out. It never touches engine state.

Public surface:
- `valid_projection_name?(binary) :: boolean` — normative regex `^[a-z][a-z0-9._/-]{0,127}$`, applied to **UTF-8 bytes**, max 128 bytes (§7).
- `classify(body) :: {:unrelated, body} | {:epoch, map} | {:operation, map} | {:error, Error.t()}`

- [ ] **Step 1: Write the failing tests**

Cover, at minimum:

```elixir
# §7 projection names
test "accepts a minimal name" — "a" => true
test "rejects an empty name" — "" => false
test "rejects a leading digit" — "1x" => false
test "rejects uppercase" — "Attributes" => false
test "rejects 129 bytes" — String.duplicate("a", 129) => false
test "accepts exactly 128 bytes" — String.duplicate("a", 128) => true
test "counts bytes not graphemes" — a name of 127 ASCII + 1 multibyte char is rejected
test "accepts the punctuation set" — "a.b_c/d-e" => true

# §8 namespace classification
test "a body with no type is unrelated"
test "a body whose type does not begin with commonplace.reducer. is unrelated"
test "an unknown commonplace.reducer.* type is an error, NOT ignored"  # the trap
test "a non-object body is an error"

# §9 epoch envelope — exactly these fields
test "a well-formed epoch body classifies as :epoch"
test "an epoch body with an extra field is invalid_reducer_envelope"
test "an epoch body missing parent_epoch_id is invalid (null is required, absent is not)"
test "version must be integer 1"
test "epoch_id must be a lowercase canonical UUID"      # reject uppercase
test "reducer must contain exactly id and version"
test "reducer.version must be a positive integer"
test "an invalid projection name yields invalid_projection_name, not invalid_reducer_envelope"

# §10 operation envelope
test "a well-formed operation body classifies as :operation"
test "an operation body with an extra field is invalid_reducer_envelope"
test "operation must be a JSON object"
```

Note the two easiest mistakes, each with a dedicated test above:
`parent_epoch_id: null` is **required and present** (absent ≠ null), and an unknown
`commonplace.reducer.*` type must **stop reduction**, never be ignored (§8).

- [ ] **Step 2: Run to verify they fail.** Expected: FAIL — module undefined.

- [ ] **Step 3: Implement `envelope.ex`.** Match exact field sets with
`Map.keys(body) |> Enum.sort()` against a literal sorted list — this rejects both
missing and additional fields with one comparison, which is what "exactly these
fields" means.

- [ ] **Step 4: Run to verify they pass.**

- [ ] **Step 5: Commit** — `feat(engine): §7-§10 envelope validation; unknown reducer types stop reduction`

---

### Task 4: Registry resolution without dynamic atoms (§11)

**Files:**
- Create: `commonplace_log_reducer/lib/commonplace/log_reducer/registry.ex`
- Test: `commonplace_log_reducer/test/registry_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
test "resolves a registered {id, version} to its module"
test "an unregistered id yields unknown_reducer"
test "a registered id at an unregistered version yields unknown_reducer" # no fallback (§11)
test "resolution never converts a string to an atom" do
  # positive control: the atom must not exist before OR after
  refute_atom_exists = fn s ->
    assert_raise ArgumentError, fn -> String.to_existing_atom(s) end
  end
  refute_atom_exists.("definitely.not.a.reducer.zzz")
  Registry.resolve(registry, "definitely.not.a.reducer.zzz", 1)
  refute_atom_exists.("definitely.not.a.reducer.zzz")
end
test "a module failing to export the behaviour is rejected at registry construction"
test "a plugin whose reducer_id/0 disagrees with its registry key is rejected"  # §12.1
```

That last one matters: §12.1 says a plugin MUST return the exact ID and version under
which it is registered. Checking it at *registration* time turns a silent data-corruption
bug into a startup error.

- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement `registry.ex`** — `build/1` validates, `resolve/3` looks up.
- [ ] **Step 4: Run to verify they pass.**
- [ ] **Step 5: Commit** — `feat(engine): §11 registry; no dynamic atoms, no version fallback`

---

### Task 5: Plugin behaviour and Context (§12, §13)

**Files:**
- Create: `commonplace_log_reducer/lib/commonplace/log_reducer/plugin.ex`
- Create: `commonplace_log_reducer/lib/commonplace/log_reducer/context.ex`
- Create: `commonplace_log_reducer/test/support/fixture_plugin.ex`
- Test: `commonplace_log_reducer/test/plugin_test.exs`

- [ ] **Step 1: Write `plugin.ex`** — transcribe the §12 behaviour exactly
(`reducer_id/0`, `reducer_version/0`, `init/2`, `apply/3`, `view/1`, `checkpoint/1`,
`restore/2`) plus the `json` typespec.

- [ ] **Step 2: Write `context.ex`** — struct with the §13 fields
(`log_id, writer_id, writer_seq, entry_id, projection, epoch_id, reducer_id,
reducer_version, resources`). `resources` defaults to `%{}`.

- [ ] **Step 3: Write fixture plugins in `test/support/fixture_plugin.ex`**

The engine must be tested **without** attribute-map (D1). Provide:
- `FixturePlugin.Counter` — state is an integer; `{"type":"inc"}` adds `n`.
- `FixturePlugin.Passthrough` — state is a list of applied operations.
- `FixturePlugin.Rejector` — `apply/3` always returns `{:error, :always_refuses}`,
  for testing §10.1.6 (stop at the failing entry).
- `FixturePlugin.BaseRejector` — `init/2` always errors, for §9.1.5.
- `FixturePlugin.NeedsResource` — returns `{:error, {:missing_resource, "r"}}` unless
  `context.resources` has `"r"`, for the `missing_resource` code.

- [ ] **Step 4: Write a test asserting each fixture satisfies the behaviour**
(`Code.ensure_loaded?` + `function_exported?` for all seven callbacks).

- [ ] **Step 5: Run tests.** Expected: PASS.
- [ ] **Step 6: Commit** — `feat(engine): §12 plugin behaviour, §13 context, fixture plugins`

---

### Task 6: Entry-chain validation and head tracking (§6, §14, §16.1-3, §17)

**Files:**
- Create: `commonplace_log_reducer/lib/commonplace/log_reducer/state.ex`
- Create: `commonplace_log_reducer/lib/commonplace/log_reducer/projection.ex`
- Test: `commonplace_log_reducer/test/chain_test.exs`

This is the layer that decides `log_mismatch`, `writer_gap`, `writer_fork`, and
`multiwriter_document_unsupported`, before any body is looked at.

- [ ] **Step 1: Write the failing tests**

```elixir
test "a fresh engine requires writer_seq 1 with prev_entry_id nil"        # D4
test "the writer id is pinned by the first entry"
test "a second writer id yields multiwriter_document_unsupported"          # §17
test "an entry naming another log yields log_mismatch"
test "a skipped sequence yields writer_gap"
test "a repeated sequence yields writer_fork"
test "a correct sequence with the wrong predecessor yields writer_fork"
test "a non-object body yields invalid_reducer_envelope"                  # §6
test "an unrelated entry advances the head"                              # §16.8
test "head advances only after successful processing"
```

The `writer_gap` / `writer_fork` split is normative and easy to blur: **gap** = the
next sequence or predecessor is *missing*; **fork** = a coordinate *conflicts* with
the expected predecessor or head (§21). Sequence `head+2` is a gap; sequence `head`
again, or `head+1` with a mismatched `prev_entry_id`, is a fork.

- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement `state.ex` and `projection.ex`** per the §14 semantic fields.
- [ ] **Step 4: Run to verify they pass.**
- [ ] **Step 5: Commit** — `feat(engine): §6/§17 single-writer chain validation and head tracking`

---

### Task 7: Epoch initialization and operation routing (§9.1, §10.1, §16)

**Files:**
- Create: `commonplace_log_reducer/lib/commonplace/log_reducer/engine.ex`
- Create: `commonplace_log_reducer/lib/commonplace/log_reducer.ex` (public API, §15)
- Test: `commonplace_log_reducer/test/engine_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# §9.1 epoch rules
test "the first epoch of a projection requires parent_epoch_id nil"
test "a first epoch naming a parent yields epoch_parent_mismatch"
test "a later epoch must name the active epoch as parent"
test "a reused epoch id yields duplicate_epoch"
test "seen_epoch_ids survives epoch replacement"                    # D5 — the trap
test "an unknown reducer suspends at the epoch entry"               # §11, §38.10
test "a plugin rejecting the base yields invalid_epoch_base and installs nothing"
test "replacing one projection's epoch leaves another projection untouched"  # §9.1.7

# §10.1 operation rules
test "an operation before any epoch yields projection_not_initialized"
test "an operation naming a stale epoch yields stale_epoch"
test "an operation routes only to its own projection"
test "a plugin refusing an operation stops at that entry"
test "the failing entry advances no head and changes no projection"  # §15.1
test "two projections evolve independently at one shared head"
test "a missing resource yields missing_resource"

# §16 atomicity
test "a plugin failure cannot partially install an epoch"
test "reduce returns the last good prefix state alongside the error"
test "splitting the same entries into two reduce/3 calls gives the same state"
```

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement `engine.ex`** following §16's eight steps literally, then
`log_reducer.ex` as thin delegation (`new/3`, `reduce/3`).

Atomicity (§16): build the candidate new state *fully* before committing it. Because
Elixir terms are immutable this is free — compute `{:ok, new_projection}` and only then
`put_in` it. Never mutate then roll back.

- [ ] **Step 4: Run to verify they pass.**
- [ ] **Step 5: Commit** — `feat(engine): §16 processing algorithm, epoch install and operation routing`

---

### Task 8: The attribute-map plugin (§23–§34)

**Files:**
- Create: `commonplace_attribute_map/lib/commonplace/attribute_map/validation.ex`
- Create: `commonplace_attribute_map/lib/commonplace/attribute_map/v1.ex`
- Create: `commonplace_attribute_map/lib/commonplace/attribute_map.ex`
- Test: `commonplace_attribute_map/test/validation_test.exs`
- Test: `commonplace_attribute_map/test/v1_test.exs`

- [ ] **Step 1: Write the failing validation tests (§24, §25, §33)**

```elixir
# keys (§25)
test "rejects an empty key"                                    # key_empty
test "rejects a non-string key"                                # key_not_string
test "accepts a 1024-byte key"
test "rejects a 1025-byte key"                                 # key_too_large
test "measures UTF-8 bytes, not graphemes"                     # 300 × 4-byte char = 1200 bytes → reject
test "rejects a key containing the null code point"            # key_contains_null

# values (§24)
test "null is a valid value"
test "booleans, finite numbers, strings, arrays, objects are valid"
test "rejects a non-string object key"
test "rejects NaN and infinity"                                # invalid_json_value — "finite number"
test "nested structures validate recursively"
```

- [ ] **Step 2: Run to verify they fail. Step 3: Implement `validation.ex`** returning
the §33 reason atoms. **Step 4: Run to verify they pass.**

- [ ] **Step 5: Write the failing plugin tests (§26–§32)**

```elixir
# §26 base
test "init from an empty values object"
test "init from a non-empty values object"
test "a base with an extra field is rejected"                  # base_fields
test "a non-object base is rejected"                           # base_not_object
test "a non-object values is rejected"                         # values_not_object

# §27 put / §28 delete
test "put adds a new key"
test "put overwrites an existing key"
test "put of null leaves the key present"                      # §24 — null ≠ absent
test "delete removes an existing key"
test "delete of an absent key succeeds unchanged"              # idempotent
test "an operation with an extra field is rejected"            # operation_fields
test "an unknown operation type is rejected"                   # unknown_operation

# §29 patch
test "patch applies all puts and deletes"
test "an empty patch is a successful no-op"
test "a key in both put and delete is rejected"                # overlapping_patch_key
test "duplicate delete keys are rejected"                      # duplicate_delete_key
test "a non-array delete is rejected"                          # delete_not_array
test "a patch rejected for its last key changes nothing"       # atomicity — the trap

# §31/§32 view and checkpoint
test "the view is exactly the attribute map, with no metadata wrapper"
test "checkpoint round-trips through restore"
test "the checkpoint contains no log id, head, projection, epoch, or reducer identity"
```

The atomicity test is the one that catches the natural implementation: validating and
applying in a single fold applies the first nine keys before rejecting the tenth.
**Validate everything, then apply everything.**

- [ ] **Step 6: Run to verify they fail. Step 7: Implement `v1.ex`.**
Note `apply/3` collides with `Kernel.apply/3` — add `import Kernel, except: [apply: 3]`.
**Step 8: Run to verify they pass.**

- [ ] **Step 9: Commit** — `feat(attribute-map): §23-§34 plugin v1 with atomic patch`

---

### Task 9: Views and checkpoints (§18, §19)

**Files:**
- Create: `commonplace_log_reducer/lib/commonplace/log_reducer/checkpoint.ex`
- Modify: `commonplace_log_reducer/lib/commonplace/log_reducer.ex` (add `view/2`, `views/1`, `checkpoint/1`, `restore/3`)
- Create: `commonplace_log_reducer/test/support/jcs.ex`
- Test: `commonplace_log_reducer/test/checkpoint_test.exs`
- Test: `commonplace_log_reducer/test/jcs_test.exs`

- [ ] **Step 1: Copy the sibling's canonical-JSON vectors (D3)**

```bash
mkdir -p conformance/canonical-json
cp -r ~/commonplace-log/conformance/canonical-json/. conformance/canonical-json/
ls conformance/canonical-json | wc -l   # expect 19 (18 real + 999-deliberate-mismatch)
```

- [ ] **Step 2: Write `jcs_test.exs`** — walk every vector directory, read `input.json`
as **bytes**, canonicalize, compare to `Base.decode16!(expected, case: :lower)`.
Assert the corpus is non-empty first (positive control). Assert `999-deliberate-mismatch`
**mismatches**; a run where it passes is a broken harness, not a green suite.

- [ ] **Step 3: Run to verify it fails. Step 4: Implement `test/support/jcs.ex`.
Step 5: Run until all 18 pass and 999 mismatches.**

- [ ] **Step 6: Write the failing view/checkpoint tests**

```elixir
# §18
test "view names the projection epoch and the shared engine head"
test "all projections report the same head even when an entry touched only one"  # the trap
test "views/1 returns every initialized projection"

# §19
test "the checkpoint matches the §19 shape"
test "seen_epoch_ids is sorted lexically when encoded"                # §19 — the trap
test "restore rebuilds a state whose views equal the original's"
test "restore resolves the exact reducer id and version from the registry"
test "restore calls each plugin's restore callback"
test "a checkpoint naming an unknown reducer yields unknown_reducer"
test "a malformed projection name in a checkpoint is rejected"
test "a checkpoint with two writer ids is rejected"
test "checkpoint plus suffix equals full replay"                      # §38.15 / §42.7
test "input after restore must begin at head.writer_seq + 1 with the right predecessor"
```

- [ ] **Step 7: Run to verify they fail. Step 8: Implement `checkpoint.ex` + API.
Step 9: Run to verify they pass.**

- [ ] **Step 10: Commit** — `feat(engine): §18 coherent views, §19 checkpoint round-trip; JCS proven on the shared corpus`

---

### Task 10: Shared conformance vectors (§38)

**Files:**
- Create: `conformance/README.md`, `conformance/check.sh`
- Create: `conformance/reducer-engine/001..016-*/`
- Create: `conformance/attribute-map/001..017-*/`
- Create: `conformance/reducer-engine/999-deliberate-mismatch/`
- Create: `conformance/attribute-map/999-deliberate-mismatch/`
- Test: `commonplace_log_reducer/test/conformance_test.exs`
- Test: `commonplace_attribute_map/test/conformance_test.exs`

- [ ] **Step 1: Write `conformance/README.md`** — the format above, the byte rules,
the 9xx policy, and a **SELECTOR statement** saying exactly what a green run does and
does not mean (copy the sibling's framing).

- [ ] **Step 2: Write the 16 engine vectors**, one per §38's numbered list, named for
the case (`001-unrelated-entries-advance-head`, `006-stale-epoch-fails`, …). Use the
fixture plugins, not attribute-map — the engine corpus must not presume a plugin.

- [ ] **Step 3: Write the 17 attribute-map vectors**, one per §38's second list.

- [ ] **Step 4: Write both `999-deliberate-mismatch` cases** — a correct `input.json`
with a deliberately wrong `expected.json`.

- [ ] **Step 5: Write both `conformance_test.exs` harnesses.** Each must:
assert the corpus directory is non-empty; run every non-`9xx` case and require a match;
run every `9xx` case and require a **mismatch**; compare views and checkpoints as
**canonical JSON bytes** (§20), not as Elixir terms.

- [ ] **Step 6: Write `conformance/check.sh`** — runs both suites, exits non-zero on
any failure *and* on an unexpectedly-passing `9xx` case.

- [ ] **Step 7: Verify it can go red.** Corrupt one `expected.json`, run `check.sh`,
observe non-zero exit; revert; observe zero. Record both in the commit message.

- [ ] **Step 8: Commit** — `test: §38 conformance corpus, 33 cases plus two mismatch controls`

---

### Task 11: Property tests (§39)

**Files:**
- Test: `commonplace_log_reducer/test/properties_test.exs`
- Test: `commonplace_attribute_map/test/properties_test.exs`

- [ ] **Step 1: Write a `StreamData` generator for valid entry sequences** — an epoch
followed by N operations over K projections, with a correctly chained
`writer_seq`/`prev_entry_id` and randomized `created_at`.

- [ ] **Step 2: Write the six engine properties (§39)**

```
full replay == checkpoint restore + suffix replay
arbitrary batch splits of the same input produce the same state
unrelated entries change no projection view
projection A operations change no projection B view
replay produces byte-equivalent canonical views and checkpoints
reduction never advances past a failing entry
```

- [ ] **Step 3: Write the seven attribute-map properties (§39)**

```
put ; put         => second value
put ; delete      => absent
delete ; put      => put value
operations on distinct keys commute
a valid patch == its puts and deletes in any non-overlapping order
checkpoint ; restore preserves the map exactly
every rejected operation leaves state unchanged
```

- [ ] **Step 4: Add the §38.16 / §42.4 timestamp property explicitly** — re-run any
generated history with `created_at` shuffled and assert the view, the checkpoint, and
the failure coordinate are all byte-identical. This is the property that proves
`created_at` is not load-bearing.

- [ ] **Step 5: Run both suites.** Expected: PASS.
- [ ] **Step 6: Commit** — `test: §39 property suites, including created_at irrelevance`

---

### Task 12: Documentation and the acceptance-criteria gate (§40, §42)

**Files:**
- Create/Modify: `README.md`, `commonplace_log_reducer/README.md`, `commonplace_attribute_map/README.md`
- Create: `docs/ACCEPTANCE.md`
- Modify: `@moduledoc` on every public module

- [ ] **Step 1: State each §40 distinction explicitly** in the docs — a projection
epoch is not a log branch; a checkpoint is not canonical history; reducer version is
not package version; overwrite order is log sequence, not wall time; raw replica sync
is not semantic Document sync; plugins are trusted installed code; multi-writer is
unsupported in version 1.

- [ ] **Step 2: Write `docs/ACCEPTANCE.md`** — the ten §42 criteria, each mapped to
the exact test or vector that demonstrates it, with the command to run it. Criterion 10
("merkle-crdt can implement the same behaviour without changing the core API") has no
plugin yet — record it as **not demonstrated**, and say so plainly rather than
claiming coverage.

- [ ] **Step 3: Update the repo README** to describe what now exists.

- [ ] **Step 4: Run everything and paste real output into the commit**

```bash
(cd commonplace_log_reducer && mix test) && \
(cd commonplace_attribute_map && mix test) && \
./conformance/check.sh
```

- [ ] **Step 5: Commit** — `docs: §40 distinctions, §42 acceptance map with honest gaps`

---

## Deferred, deliberately

Recorded so they are visible rather than forgotten:

- **The `commonplace-log` adapter** (D2). A `Commonplace.LogReducer.Adapter.CommonplaceLog`
  module translating that library's entries into the §6 contract. No longer blocked on
  information — the shape is known (D2, above) — but deliberately deferred until that
  library's façade lands, since its module names are the churn. When written, it must:
  decode `canonical_bytes` rather than read projection columns; hard-reject a
  `version` other than `1`; follow `next_after_seq` as **pagination, not a gap**; and
  treat a short read against a live appender as a valid shorter prefix. A genuine
  sequence hole or a `prev_entry_id` not naming its predecessor is corruption and must
  be refused loudly — which our §6 chain validation (task 6) already does.
- **`commonplace-merkle-crdt`** (§41.11, §42.10) — the second plugin that would actually
  prove the plugin boundary. Out of scope here.
- **Document-process integration** (§41.10) — belongs to a later `commonplace-document`.
- **Multi-writer reduction** — explicitly unsupported in version 1 (§17).
