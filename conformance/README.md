# Conformance corpora

Language-neutral JSON fixtures for the commonplace-log-reducer specification.
Three corpora live here:

| Directory | What it pins | Harness |
| --- | --- | --- |
| `canonical-json/` | RFC 8785 canonicalization (§20) | `commonplace_log_reducer/test/jcs_test.exs` |
| `reducer-engine/` | the 16 §38 reducer-engine cases | `commonplace_log_reducer/test/conformance_test.exs` |
| `attribute-map/` | the 17 §38 attribute-map cases | `commonplace_attribute_map/test/conformance_test.exs` |

`conformance/check.sh` runs the two Elixir suites and reports.

⭐ **Which of its gates have been seen red, and which green, is recorded in
[`../docs/GATE-ARMS.md`](../docs/GATE-ARMS.md)** — with the object each arm was proven
against and the sha the last full run was measured at. A green run here means the gates
did not fire; that file is where you find out whether they *can*.

`canonical-json/` is inherited byte-for-byte from an upstream source and has a
different vector format (`input.json` + `expected.hex`). **Do not edit it.**
Everything below describes `reducer-engine/` and `attribute-map/`.

---

## SELECTOR: what a green run does and does not mean

**A green run means:** for each stated input, *this* implementation produced the
stated head, active projection metadata, canonical views, canonical checkpoint,
or the stated §21 error code and failing coordinate — compared as RFC 8785
canonical JSON bytes (§20), not as Elixir terms.

**A green run does NOT mean:**

- **§42.10 is not validated by this corpus.** Every plugin exercised here —
  `FixturePlugin.*` and `Commonplace.AttributeMap.V1` — shares an author with
  the engine. A corpus written by the same hand that wrote both sides can only
  show that the two agree; it cannot show that the plugin boundary is
  discoverable, sufficient, or usable by an independent implementer, and no
  corpus written in this repository ever can.

  §42.10 **is** demonstrated — elsewhere, and once, by an independently
  authored plugin running against an unchanged engine. See
  [`../docs/42-10-PLUGIN-BOUNDARY.md`](../docs/42-10-PLUGIN-BOUNDARY.md). That
  is a boundary demonstration, not plugin *generality*; a third independent
  implementer would be a strictly stronger test. The two statements rest on
  different evidence and are both correct — the corpus shows breadth, the
  integration run shows the boundary.
- **The corpus is not the specification.** Where a vector and the spec text
  disagree, the spec wins and the vector is a bug.
- **The corpus is not exhaustive.** It states the cases §38 requires. Codes,
  shapes, and edge conditions outside those cases are covered — if at all — by
  each project's own unit tests, not here.
- **Passing does not prove the corpus was read.** That is what the count floor
  and the `9xx` control in each harness are for; see "Two doors" below.

---

## Vector format

One directory per case, containing exactly `input.json` and `expected.json`.
Directory names are `NNN-kebab-case-description`.

### `input.json`

```json
{
  "log_id": "0198d83c-eaf8-7c5d-b1e3-4387f1d8d9b8",
  "registry": [
    {"id": "fixture.counter", "version": 1, "plugin": "counter"}
  ],
  "entries": [ ... complete §6 entries ... ],
  "split_at": 4
}
```

- `log_id` — the log the engine is built for.
- `registry` — the §11 trusted registry, as a list. `id` and `version` are the
  durable wire identifiers; **`plugin` is a fixture KEY, never a module name**
  (see below).
- `entries` — complete §6 entries in input-log order: `log_id`, `entry_id`,
  `writer_id`, `writer_seq`, `prev_entry_id`, `created_at`, `body`.
- `split_at` — **optional**. When present, the harness additionally reduces the
  first `split_at` entries, checkpoints, restores, and reduces the rest, and
  requires the same result as a full replay (§42.7).

### `expected.json`

Exactly one top-level key, `ok` or `error`.

```json
{"ok": {
  "head":        {"writer_seq": 7, "entry_id": "..."},
  "projections": {"content": {"epoch_id": "...", "epoch_head": {...}, "reducer": {...}}},
  "views":       {"content": {"head": {...}, "epoch_id": "...", "epoch_head": {...},
                              "reducer": {...}, "value": 51}},
  "checkpoint":  { ... the complete §19 checkpoint ... }
}}
```

All four `ok` fields are required. `projections` is the active projection
metadata of §38; it is deliberately redundant with the same fields inside
`views`, so a runtime that exposes metadata separately from views can be
checked against it directly.

```json
{"error": {
  "code":        "stale_epoch",
  "writer_seq":  3,
  "entry_id":    "...",
  "projection":  "content",
  "head":        {"writer_seq": 2, "entry_id": "..."},
  "reason":      "overlapping_patch_key",
  "views":       { ... }
}}
```

- `code` — the §21 code. Codes are a closed set; a vector may not invent one.
- `writer_seq` / `entry_id` — the **failing** coordinate.
- `projection` — the projection when the engine knows one, otherwise `null`.
- `head` — the head of the **returned prefix state** (§15.1), i.e. the entry
  *before* the failure; `null` when the failure was the first entry.
- `reason` — **optional**. A normalized rendering of the implementation's
  `details.reason`: its leading atom/tag as a string. §21 says human-readable
  messages are not protocol identifiers and a plugin's reason term is opaque,
  so only the stable tag is compared, and only where a vector states it.
- `views` — **optional**. The views of the returned prefix state. Present on
  the cases that assert a rejected operation left state untouched.

A harness compares only the fields a vector states, so `reason` and `views` may
be omitted. A stated field the implementation does not produce still
mismatches: the restriction can weaken a vector, never a run.

---

## The fixture-key indirection

`registry[].plugin` is a corpus-level **fixture key** — `"counter"`,
`"passthrough"`, `"attribute-map-v1"` — and never an Elixir module name. Two
reasons, and both matter:

1. The corpus must stay language-neutral. A Go or Rust harness cannot resolve
   `Elixir.FixturePlugin.Counter`.
2. §11 forbids the engine from interpreting a stored Elixir module name at all,
   and §22 puts reducer selection in trusted code configuration. A corpus that
   named modules would be modelling the thing the spec prohibits.

Each harness owns its own key → module table. The keys currently in use:

| Corpus | Key | Reducer ID / version |
| --- | --- | --- |
| `reducer-engine` | `counter` | `fixture.counter` / 1 |
| `reducer-engine` | `passthrough` | `fixture.passthrough` / 1 |
| `reducer-engine` | `rejector` | `fixture.rejector` / 1 |
| `reducer-engine` | `base-rejector` | `fixture.base_rejector` / 1 |
| `reducer-engine` | `needs-resource` | `fixture.needs_resource` / 1 |
| `attribute-map` | `attribute-map-v1` | `commonplace.attribute-map` / 1 |

The engine corpus deliberately uses **only** fixture plugins. An engine corpus
that presumed commonplace-attribute-map would make the §37.1 package boundary
untestable and would conflate two independently versioned things.

---

## Byte rules

Every file in every corpus here:

- UTF-8, **no BOM**;
- **LF** line endings only, never CRLF;
- exactly **one** trailing LF;
- JSON indented with two spaces.

`check.sh` enforces these. They exist so that "the corpus changed" is always a
semantic change, never an editor artifact, and so a diff against another
repository's copy is meaningful.

---

## Numbering, and the `9xx` policy

Cases are numbered sequentially from `001`.

**`9xx` is reserved for deliberately-wrong vectors.** A `9xx` case states an
expectation that a *correct* implementation must NOT match, and every harness
asserts the mismatch. It is the corpus's own positive control: an instrument
that reports every case as matching is blind, and the `9xx` case is what proves
it is not. A `9xx` case that starts passing means the comparison broke, not that
the implementation improved.

A §38 case that needs two inputs (the two "same log, different `created_at`"
pairs) occupies two consecutive numbers with `-a` and `-b` suffixes. That is why
the engine corpus's 16 required cases run to `017` and the attribute-map
corpus's 17 run to `018`.

The engine corpus carries one pair beyond §38: `018`/`019`, "operation_id alone
changes nothing". commonplace-log entry version 2 (its Amendment 2, 2026-08-25)
persists a durable `operation_id` as a top-level **entry** field, **required**
in version 2 (jes, 2026-08-25T19:48Z; commonplace-log `4e94986`, whose invalid
case `037-v2-missing-operation-id` is the shape this pair must not contain). The engine reads only its six §6
required keys, so a version-2 entry reduces byte-identically to case `016`
whatever the field's value. Side `a` is all version 2; side `b` is a **mixed
lane** — version-2 entries beside one version-1 entry with no `operation_id` —
which is the honest "absent" case, since absent-in-v2 is malformed at the
log's gate and not a shape this corpus may call valid. The pair is the tripwire
a second implementer meets: it must accept entry versions 1 and 2 in one lane
and must not let `operation_id` reach a plugin or a checkpoint.

---

## Two doors

Each harness is built so that two different failures redden **disjoint** sets of
tests:

| Sabotage | What goes red | What it means |
| --- | --- | --- |
| rename or delete a case directory | the **count floor** only | the corpus shrank — restore the case; do not investigate the implementation |
| corrupt a byte of an `expected.json` | that case's **comparison** only | the implementation regressed, or the vector is wrong |

The per-case tests are generated from the corpus at compile time, so a deleted
case generates no test rather than failing one. Without the floor, an empty
corpus would be a green suite over nothing — and a floor derived by counting
what the walk found is not a floor at all. The counts are therefore written down
as literals in each harness, and the floor lives in its own test so that a
"corpus shrank" failure never presents as "implementation regressed".

---

## Adding a case

1. Add the directory with `input.json` and `expected.json`, obeying the byte
   rules.
2. Bump `@discovered` and `@must_match` (or `@must_mismatch`) in the harness.
   The floor is *supposed* to fail until you do; that is the point.
3. Write the expectation from the specification, not from a program run. An
   expectation captured from the implementation it checks is a mirror.
4. Run `conformance/check.sh`.
