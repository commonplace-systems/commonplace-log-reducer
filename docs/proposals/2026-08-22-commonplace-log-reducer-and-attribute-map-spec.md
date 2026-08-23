# Commonplace Log Reducer and Attribute Map

**Version:** 0.1-draft  
**Status:** Proposed implementation specification  
**Date:** 2026-08-22  
**Libraries:** commonplace-log-reducer, commonplace-attribute-map

## 1. Decision

Commonplace Documents interpret one append-only log through one or more named projections. Each projection has:

- a stable projection name;
- an active epoch;
- a reducer identifier and reducer protocol version;
- reducer-owned state; and
- a view calculated at an exact log head.

The **commonplace-log-reducer** library supplies the generic projection engine, epoch protocol, reducer behavior, registry, deterministic replay, and checkpoint format.

The **commonplace-attribute-map** library supplies the first reducer plugin. It interprets put, delete, and patch operations as a JSON attribute map. Because ordinary Document logs have one ordered append lane, the last operation in log sequence order wins.

Neither library owns log persistence, BEAM process lifecycle, Document messaging, Cell authority, capabilities, Realm placement, or physical replica synchronization.

## 2. Architectural position

The intended dependency direction is:

~~~mermaid
flowchart TD
    L["commonplace-log"] --> R["commonplace-log-reducer"]
    R --> A["commonplace-attribute-map"]
    R --> M["commonplace-merkle-crdt"]
    A --> D["commonplace-document"]
    M --> D
~~~

The arrows mean “is depended on by”:

- commonplace-log-reducer consumes validated entries supplied by commonplace-log.
- Reducer plugins depend on the behavior and data types defined by commonplace-log-reducer.
- A later commonplace-document library selects plugins and runs projections.
- commonplace-log-reducer never depends on a particular plugin.

## 3. Normative language

The terms MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are normative.

## 4. Scope

This specification defines:

- a standard reducer event envelope inside a log entry body;
- named projections;
- projection-scoped epochs;
- reducer identity and versioning;
- reducer registration;
- deterministic ordered replay;
- exact-head views;
- derived checkpoints;
- the Elixir reducer behavior;
- error and suspension behavior; and
- the commonplace-attribute-map version 1 reducer.

This specification does not define:

- append-only log storage or replication;
- multi-writer Document reduction;
- branching or lineage synchronization;
- Yjs, Yepochs, or Merkle commits;
- external blob retrieval;
- execution of mounted verbs;
- authorization or capability tokens;
- cross-log transactions; or
- persistence of projection checkpoints.

## Part I: commonplace-log-reducer

## 5. Vocabulary

### 5.1 Input log

The **input log** is the ordered sequence of validated Commonplace log entries supplied to the reducer.

Version 0.1 operates under the Cell-Owned Document Profile: one Document log has one writer ID for its lifetime. The reducer therefore observes one gapless sequence ordered by writer sequence.

### 5.2 Projection

A **projection** is a named materialized interpretation of selected log entries.

Examples include:

- attributes;
- content;
- directory entries;
- mounted behavior;
- search facts; and
- application-specific indexes.

Projection names are scoped to one log. Different projections over the same log may use different reducer plugins and may cross epoch boundaries independently.

### 5.3 Reducer

A **reducer** is a deterministic plugin that:

1. initializes state from an epoch base;
2. applies projection operations in log order;
3. produces an application-facing view;
4. serializes a derived checkpoint; and
5. restores state from a compatible checkpoint.

A reducer defines semantic behavior, not merely an encoding format.

### 5.4 Epoch

An **epoch** is one incarnation of one projection’s state history.

An epoch:

- has a UUID;
- names one reducer ID and reducer protocol version;
- begins at one exact log entry;
- has a self-contained reducer-owned base object; and
- remains active until a later epoch entry replaces it.

Epoch identity is scoped by projection. Changing the content epoch does not change the attributes epoch.

### 5.5 Reducer protocol version

A **reducer protocol version** identifies the durable semantics and wire shapes understood by a reducer.

It is independent of:

- the Elixir package version;
- the application release version;
- the epoch ID; and
- the Commonplace log entry version.

The same reducer protocol version may be used by any number of epochs.

### 5.6 Head

A **head** is the exact input-log coordinate through which a reducer state has been calculated:

~~~elixir
%{
  writer_seq: pos_integer(),
  entry_id: String.t()
}
~~~

The log ID and writer ID are stored alongside the head in reducer state and checkpoints.

### 5.7 View

A **view** is the application-facing JSON value produced by a projection at an exact head.

Views are derived data. They may be cached but are never the source of log truth.

### 5.8 Checkpoint

A **checkpoint** is a derived, disposable serialization of reducer state at an exact log head.

A checkpoint accelerates reconstruction. It does not:

- create a new epoch;
- alter canonical Document history;
- replace a lineage snapshot;
- establish authority; or
- permit entries to be skipped without head verification.

## 6. Input entry contract

commonplace-log-reducer consumes validated, parsed entries having at least:

~~~elixir
%{
  "log_id" => log_id,
  "entry_id" => entry_id,
  "writer_id" => writer_id,
  "writer_seq" => writer_seq,
  "prev_entry_id" => previous_entry_id_or_nil,
  "created_at" => timestamp,
  "body" => body
}
~~~

The caller is responsible for canonical entry validation. The reducer MUST still verify:

- every entry has the expected log ID;
- all entries use the pinned writer ID;
- writer sequences are contiguous from the current head;
- predecessor entry IDs form a continuous chain; and
- body is a JSON object.

The reducer MUST NOT use created_at for event ordering, conflict resolution, epoch selection, or overwrite semantics.

## 7. Projection names

A projection name MUST:

- be a non-empty UTF-8 string;
- contain at most 128 UTF-8 bytes;
- begin with an ASCII lowercase letter; and
- contain only ASCII lowercase letters, digits, period, underscore, slash, or hyphen.

The following regular expression is normative:

~~~text
^[a-z][a-z0-9._/-]{0,127}$
~~~

The conventional projection names are:

- attributes for explicit Document attributes;
- content for the primary application-facing value; and
- behavior for mounted handlers and verbs, if represented as a projection.

This specification reserves no projection name exclusively.

## 8. Reducer event namespace

Reducer control and operation entries are identified by the type field inside the Commonplace log entry body.

Version 1 defines exactly two reducer body types:

- commonplace.reducer.epoch
- commonplace.reducer.operation

A body whose type is absent or does not begin with commonplace.reducer. is unrelated application history. The reducer engine MUST ignore its body while still advancing the processed log head.

A body whose type begins with commonplace.reducer. but is unknown or malformed MUST stop reduction with an error. It MUST NOT be silently ignored.

## 9. Epoch-entry format

An epoch begins with this body:

~~~json
{
  "type": "commonplace.reducer.epoch",
  "version": 1,
  "projection": "attributes",
  "epoch_id": "0198d83a-0a1f-7ba0-aa24-21f9130f883d",
  "parent_epoch_id": null,
  "reducer": {
    "id": "commonplace.attribute-map",
    "version": 1
  },
  "base": {
    "values": {}
  }
}
~~~

The epoch body has exactly these fields:

| Field | Requirement |
| --- | --- |
| type | The string commonplace.reducer.epoch. |
| version | Integer 1. |
| projection | A valid projection name. |
| epoch_id | A lowercase canonical UUID. |
| parent_epoch_id | Null for the first epoch of a projection; otherwise the active epoch UUID. |
| reducer | An object containing exactly id and version. |
| reducer.id | A registered stable reducer identifier. |
| reducer.version | A positive safe integer. |
| base | A JSON object interpreted and validated by the selected reducer. |

No additional fields are permitted in an epoch body in version 1.

### 9.1 Epoch rules

The reducer engine MUST enforce:

1. The first epoch for a projection has parent_epoch_id equal to null.
2. A later epoch has parent_epoch_id equal to that projection’s currently active epoch.
3. An epoch ID has not previously appeared for that projection.
4. The requested reducer ID and version exist in the trusted registry.
5. The new reducer successfully initializes from base before the epoch becomes active.
6. The epoch begins at the entry containing the epoch body.
7. Replacing one projection epoch does not alter any other projection.

The base object MUST be self-contained from the reducer’s perspective. A new reducer is never handed an opaque in-memory state value belonging to a previous reducer module.

Applications may calculate a new base from previous state before appending the epoch entry. Once appended, replay depends only on durable entries, registered reducer code, and explicitly supplied immutable resources.

## 10. Operation-entry format

A projection operation has this body:

~~~json
{
  "type": "commonplace.reducer.operation",
  "version": 1,
  "projection": "attributes",
  "epoch_id": "0198d83a-0a1f-7ba0-aa24-21f9130f883d",
  "operation": {
    "type": "put",
    "key": "title",
    "value": "Hello"
  }
}
~~~

The operation body has exactly these fields:

| Field | Requirement |
| --- | --- |
| type | The string commonplace.reducer.operation. |
| version | Integer 1. |
| projection | A valid projection name. |
| epoch_id | The active epoch UUID for the named projection. |
| operation | A JSON object interpreted and validated by the active reducer. |

No additional fields are permitted in an operation body in version 1.

### 10.1 Operation rules

The reducer engine MUST:

1. require an active epoch for the named projection;
2. require epoch_id to equal the active epoch ID;
3. route the operation only to the active reducer instance;
4. apply the operation exactly once in input-log order;
5. advance the head only after successful application; and
6. stop at the failing entry if the plugin refuses the operation.

An operation for an earlier or unknown epoch is invalid durable history under this profile. Offline admission code must remap or reject stale-epoch operations before appending them to the authoritative log.

## 11. Reducer registry

The host supplies a trusted registry:

~~~elixir
%{
  {"commonplace.attribute-map", 1} =>
    Commonplace.AttributeMap.V1,

  {"commonplace.merkle-crdt", 1} =>
    Commonplace.MerkleCRDT.V1
}
~~~

Registry keys are durable wire identifiers. Registry values are Elixir modules implementing Commonplace.LogReducer.Plugin.

The engine MUST NOT:

- convert an untrusted reducer string into an atom;
- interpret a stored Elixir module name;
- dynamically install code while replaying;
- fall back to a different reducer version; or
- silently skip an unknown reducer.

An unavailable reducer suspends activation at its epoch entry until compatible code is installed or the history is otherwise handled explicitly.

## 12. Reducer plugin behavior

Version 1 defines this conceptual Elixir behavior:

~~~elixir
defmodule Commonplace.LogReducer.Plugin do
  @type json ::
          nil
          | boolean()
          | number()
          | String.t()
          | [json()]
          | %{optional(String.t()) => json()}

  @type state :: term()
  @type context :: Commonplace.LogReducer.Context.t()

  @callback reducer_id() :: String.t()
  @callback reducer_version() :: pos_integer()

  @callback init(base :: map(), context()) ::
              {:ok, state()} | {:error, term()}

  @callback apply(operation :: map(), context(), state()) ::
              {:ok, state()} | {:error, term()}

  @callback view(state()) ::
              {:ok, json()} | {:error, term()}

  @callback checkpoint(state()) ::
              {:ok, map()} | {:error, term()}

  @callback restore(checkpoint :: map(), context()) ::
              {:ok, state()} | {:error, term()}
end
~~~

### 12.1 Callback requirements

A conforming plugin:

- MUST return the exact reducer ID and version under which it is registered;
- MUST validate every epoch base it initializes;
- MUST validate every addressed operation;
- MUST produce the same result for the same state, operation, context, and resources;
- MUST NOT use wall-clock time, randomness, process identity, global mutable state, or network results as implicit reducer input;
- MUST NOT silently ignore an operation addressed to it;
- MUST return JSON-compatible views;
- MUST return JSON-object checkpoints; and
- MUST validate checkpoints before restoring them.

Plugin state may be any immutable Elixir term. Only views and checkpoints cross the plugin boundary as durable or user-facing representations.

## 13. Reducer context

The engine supplies a context equivalent to:

~~~elixir
%Commonplace.LogReducer.Context{
  log_id: log_id,
  writer_id: writer_id,
  writer_seq: writer_seq,
  entry_id: entry_id,
  projection: projection,
  epoch_id: epoch_id,
  reducer_id: reducer_id,
  reducer_version: reducer_version,
  resources: resources
}
~~~

The context contains no ambient authority.

resources is a caller-supplied map of immutable resource identifiers to resolved bytes or JSON values. Resource acquisition occurs outside deterministic reduction. A reducer MUST return an explicit missing-resource error rather than fetch a resource itself.

commonplace-attribute-map version 1 requires no external resources.

## 14. Engine state

The reducer engine state is conceptually:

~~~elixir
%Commonplace.LogReducer.State{
  version: 1,
  log_id: log_id,
  writer_id: writer_id_or_nil,
  head_seq: non_negative_integer,
  head_entry_id: entry_id_or_nil,
  projections: %{
    projection_name => %Commonplace.LogReducer.Projection{
      epoch_id: epoch_id,
      seen_epoch_ids: MapSet.t(),
      reducer_id: reducer_id,
      reducer_version: reducer_version,
      module: reducer_module,
      state: reducer_state,
      epoch_entry_id: entry_id,
      epoch_writer_seq: writer_seq
    }
  }
}
~~~

The exact struct layout is implementation-specific. The semantic fields above are required.

## 15. Public Elixir API

The initial public API SHOULD resemble:

~~~elixir
@spec new(log_id(), registry(), keyword()) ::
        {:ok, State.t()} | {:error, term()}

@spec reduce(State.t(), Enumerable.t(), keyword()) ::
        {:ok, State.t()}
        | {:error, error(), State.t()}

@spec view(State.t(), projection_name()) ::
        {:ok, %{head: head(), epoch_id: uuid(), value: json()}}
        | {:error, term()}

@spec views(State.t()) ::
        {:ok, %{optional(projection_name()) => map()}}
        | {:error, term()}

@spec checkpoint(State.t()) ::
        {:ok, map()} | {:error, term()}

@spec restore(checkpoint :: map(), registry(), keyword()) ::
        {:ok, State.t()} | {:error, term()}
~~~

### 15.1 Reduction failure

reduce returns the last successfully reduced prefix state with an error:

~~~elixir
{:error,
 %Commonplace.LogReducer.Error{
   code: :stale_epoch,
   log_id: log_id,
   writer_seq: 47,
   entry_id: entry_id,
   projection: "content",
   details: %{expected: active_epoch, actual: stale_epoch}
 },
 state_through_seq_46}
~~~

The failing entry does not alter any projection or advance the returned head.

Because Elixir state is immutable, the caller also retains its original state if it requires all-or-nothing batch behavior.

## 16. Processing algorithm

For each input entry, in order, the engine:

1. validates log identity;
2. pins or validates the one permitted writer ID;
3. validates the next writer sequence and predecessor entry ID;
4. classifies the body as unrelated, epoch, operation, or malformed reducer data;
5. for an epoch, validates the envelope, resolves the plugin, initializes its state, and atomically replaces that projection;
6. for an operation, validates the envelope and applies it to the active projection;
7. if processing succeeds, advances the engine head to the entry coordinate; and
8. if processing fails, returns the state through the preceding entry.

An unrelated entry changes no projection but still advances the engine head.

Processing an epoch or operation is atomic across the engine state. A plugin failure cannot partially install an epoch or partially update its projection.

## 17. Single-writer requirement

Version 1 rejects a second writer ID with multiwriter_document_unsupported.

The reducer MUST NOT:

- sort entries by created_at;
- use replica-local arrival order;
- interleave several writer sequences;
- choose a total order over a writer frontier; or
- assume plugin operations commute.

A future multi-writer profile must define its own deterministic or order-independent semantics.

## 18. Views

view returns:

- the projection’s current epoch ID;
- the exact shared log head through which all projections have been processed; and
- the plugin-produced JSON value.

All projections in one engine state are coherent at the same log head, even when an entry affected only one projection.

The engine MAY additionally expose:

- the epoch-start coordinate;
- reducer ID and version;
- per-projection diagnostic information; and
- the most recent operation coordinate.

These additions MUST NOT change the plugin’s canonical view value.

## 19. Checkpoint format

A version 1 checkpoint is a JSON object equivalent to:

~~~json
{
  "version": 1,
  "log_id": "0198d83c-eaf8-7c5d-b1e3-4387f1d8d9b8",
  "writer_id": "0198d83d-54de-7c06-b574-ea1fb40d3a86",
  "head": {
    "writer_seq": 93,
    "entry_id": "0198d83e-2094-7026-a492-d81ea8fc6d7e"
  },
  "projections": {
    "attributes": {
      "epoch_id": "0198d83a-0a1f-7ba0-aa24-21f9130f883d",
      "seen_epoch_ids": [
        "0198d83a-0a1f-7ba0-aa24-21f9130f883d"
      ],
      "epoch_head": {
        "writer_seq": 1,
        "entry_id": "0198d83b-41fb-749d-94e6-f346c11337d1"
      },
      "reducer": {
        "id": "commonplace.attribute-map",
        "version": 1
      },
      "state": {
        "values": {
          "title": "Hello"
        }
      }
    }
  }
}
~~~

The engine MUST:

- sort seen_epoch_ids lexically when encoding;
- validate every identifier and coordinate when restoring;
- resolve the exact reducer ID and version from the registry;
- call each plugin’s restore callback;
- reject duplicate or malformed projection names; and
- reject a checkpoint using several writer IDs.

Before trusting a restored checkpoint, the caller MUST verify that:

- the named log still exists;
- the checkpoint head entry exists at the claimed writer sequence;
- its entry ID is identical; and
- subsequent input begins at head.writer_seq plus one with the correct predecessor.

If verification fails, the checkpoint MUST be discarded and rebuilt from a known valid prefix.

## 20. Determinism

For a fixed:

- validated input-log prefix;
- reducer registry;
- reducer implementations;
- immutable resource map; and
- checkpoint-free initial state,

all conforming implementations MUST produce equivalent:

- active projection epochs;
- projection views;
- reducer checkpoints; and
- failure coordinates and classifications.

created_at is advisory and MUST NOT affect those results.

The conformance suite SHOULD serialize checkpoints and views using RFC 8785 canonical JSON when comparing runtimes or runs.

## 21. Error classifications

Version 1 defines at least:

| Code | Meaning |
| --- | --- |
| log_mismatch | An entry names another log. |
| writer_gap | The next sequence or predecessor is missing. |
| writer_fork | A coordinate conflicts with the expected predecessor or head. |
| multiwriter_document_unsupported | A second writer ID appeared. |
| invalid_reducer_envelope | A body in the reducer namespace is malformed. |
| invalid_projection_name | A projection name violates section 7. |
| unknown_reducer | No module is registered for the reducer ID and version. |
| duplicate_epoch | An epoch ID was already used for this projection. |
| epoch_parent_mismatch | A new epoch does not name the active parent epoch. |
| projection_not_initialized | An operation arrived before the first epoch. |
| stale_epoch | An operation does not name the active epoch. |
| invalid_epoch_base | The plugin rejected the epoch base. |
| invalid_operation | The plugin rejected an addressed operation. |
| missing_resource | A reducer-required immutable resource was not supplied. |
| invalid_checkpoint | Core or plugin checkpoint validation failed. |

Errors SHOULD be structs containing the stable code, failing coordinate, projection when known, and structured details. Human-readable messages are not protocol identifiers.

## 22. Security and authority boundary

Reducer selection is trusted code configuration. Durable entries select only among already registered reducer IDs and versions.

The reducer engine:

- does not authenticate callers;
- does not authorize writes;
- does not issue capabilities;
- does not load arbitrary code;
- does not perform network I/O;
- does not mutate the input log; and
- does not execute Document verbs.

The Cell/Document layer authorizes and validates proposed effects before append. Reducer replay remains defensive because stored history is permanent.

## Part II: commonplace-attribute-map

## 23. Reducer identity

commonplace-attribute-map version 1 has:

| Property | Value |
| --- | --- |
| Reducer ID | commonplace.attribute-map |
| Reducer protocol version | 1 |
| Default projection name | attributes |
| View type | JSON object |
| External resources | None |
| Ordering | Input log sequence |

The package version may change without changing reducer protocol version 1, provided durable semantics remain identical.

## 24. Attribute model

The attribute state is a finite map from UTF-8 string keys to I-JSON values.

Values may be:

- null;
- Boolean;
- finite number;
- string;
- array; or
- object with string keys.

Null is an ordinary present value. Deletion is a separate operation.

Attribute keys are compared exactly as decoded UTF-8 strings. The reducer performs no Unicode normalization or case folding.

## 25. Attribute key constraints

An attribute key MUST:

- be a non-empty string;
- contain valid Unicode;
- contain at most 1,024 UTF-8 bytes; and
- contain no null code point.

The reducer reserves no prefix in version 1. Applications SHOULD use namespaced keys for system attributes, for example:

- commonplace.type
- commonplace.title
- commonplace.schema
- commonplace.behavior
- notion.icon

Namespacing is convention, not reducer semantics.

## 26. Epoch base

The version 1 epoch base has exactly one field:

~~~json
{
  "values": {
    "commonplace.type": "page",
    "commonplace.title": "Hello"
  }
}
~~~

Rules:

- values MUST be a JSON object.
- Every key and value MUST satisfy sections 24 and 25.
- No additional base fields are permitted.
- The first epoch normally uses an empty values object.
- A later epoch base is a complete replacement snapshot, not a patch over the previous epoch.

Initializing an epoch discards the previous in-memory attribute-map state and begins with exactly base.values. The previous history remains in the input log.

## 27. Put operation

A put operation has exactly:

~~~json
{
  "type": "put",
  "key": "commonplace.title",
  "value": "A New Title"
}
~~~

Semantics:

1. Validate key and value.
2. Associate key with value.
3. Replace any previous value for that key.
4. Leave all other keys unchanged.

No additional fields are permitted.

## 28. Delete operation

A delete operation has exactly:

~~~json
{
  "type": "delete",
  "key": "commonplace.icon"
}
~~~

Semantics:

1. Validate key.
2. Remove key if present.
3. If key is absent, succeed without changing the state.
4. Leave all other keys unchanged.

Deleting an absent key is idempotent. No additional fields are permitted.

## 29. Patch operation

A patch atomically changes several attributes:

~~~json
{
  "type": "patch",
  "put": {
    "commonplace.title": "Renamed",
    "commonplace.archived": false
  },
  "delete": [
    "commonplace.icon",
    "legacy.slug"
  ]
}
~~~

The patch has exactly type, put, and delete.

Rules:

- put MUST be a JSON object.
- delete MUST be an array of unique valid keys.
- A key MUST NOT appear in both put and delete.
- Every key and value MUST validate before state changes.
- Empty put and delete collections are permitted and are a successful no-op.
- The entire patch succeeds or fails atomically.

Application order within put or delete has no semantic meaning because duplicate and overlapping keys are prohibited.

## 30. Sequential overwrite semantics

For one key, the value at log head H is determined by the last applicable operation at or before H in writer sequence order:

- put makes the key present with its supplied value;
- patch.put does the same;
- delete makes the key absent; and
- patch.delete does the same.

Neither entry UUID ordering nor created_at participates.

Although this is colloquially “last writer wins,” version 1 is not a distributed LWW register. It relies on the one-writer, totally sequenced Document profile.

## 31. View

The plugin view is exactly the current attribute map:

~~~json
{
  "commonplace.archived": false,
  "commonplace.title": "Renamed"
}
~~~

The view does not wrap values in metadata and does not expose deletion tombstones.

The commonplace-log-reducer host supplies the projection epoch and exact log head alongside this value.

Implementations MAY expose non-canonical debugging functions for per-entry provenance, but such data is not part of the version 1 view.

## 32. Plugin checkpoint

The attribute-map checkpoint is identical in shape to its epoch base:

~~~json
{
  "values": {
    "commonplace.archived": false,
    "commonplace.title": "Renamed"
  }
}
~~~

checkpoint returns this object. restore validates it using the same rules as epoch initialization.

The plugin checkpoint does not include:

- log ID;
- writer ID;
- log head;
- projection name;
- epoch ID; or
- reducer identity.

Those belong to the enclosing commonplace-log-reducer checkpoint.

## 33. Attribute-map errors

The plugin returns structured reasons which the engine wraps as invalid_epoch_base, invalid_operation, or invalid_checkpoint.

Recommended plugin reasons include:

| Reason | Meaning |
| --- | --- |
| base_not_object | Epoch base is not an object. |
| base_fields | Epoch base has missing or additional fields. |
| values_not_object | Base or checkpoint values is not an object. |
| operation_fields | An operation has missing or additional fields. |
| unknown_operation | The operation type is unsupported. |
| key_not_string | A key is not a string. |
| key_empty | A key is empty. |
| key_too_large | A key exceeds 1,024 UTF-8 bytes. |
| key_contains_null | A key contains the null code point. |
| invalid_json_value | A value violates I-JSON requirements. |
| delete_not_array | patch.delete is not an array. |
| duplicate_delete_key | patch.delete contains the same key twice. |
| overlapping_patch_key | A key occurs in both patch.put and patch.delete. |

Reason strings and messages may be richer, but tests should pin stable reason atoms or slugs.

## 34. Elixir plugin shape

An implementation should resemble:

~~~elixir
defmodule Commonplace.AttributeMap.V1 do
  @behaviour Commonplace.LogReducer.Plugin

  @impl true
  def reducer_id, do: "commonplace.attribute-map"

  @impl true
  def reducer_version, do: 1

  @impl true
  def init(%{"values" => values} = base, _context) do
    # Validate exact base shape, keys, and I-JSON values.
    {:ok, values}
  end

  @impl true
  def apply(%{"type" => "put"} = operation, _context, state) do
    # Validate exact operation shape before mutation.
    {:ok, Map.put(state, operation["key"], operation["value"])}
  end

  @impl true
  def apply(%{"type" => "delete"} = operation, _context, state) do
    {:ok, Map.delete(state, operation["key"])}
  end

  @impl true
  def apply(%{"type" => "patch"} = operation, _context, state) do
    # Validate all keys and values first, then apply atomically.
    {:ok, apply_patch(state, operation)}
  end

  @impl true
  def view(state), do: {:ok, state}

  @impl true
  def checkpoint(state), do: {:ok, %{"values" => state}}

  @impl true
  def restore(checkpoint, context), do: init(checkpoint, context)
end
~~~

This example omits required validation code and is not itself normative.

## 35. Example history

Given one attributes epoch followed by:

~~~json
[
  {
    "type": "put",
    "key": "title",
    "value": "First"
  },
  {
    "type": "put",
    "key": "draft",
    "value": true
  },
  {
    "type": "put",
    "key": "title",
    "value": "Second"
  },
  {
    "type": "delete",
    "key": "draft"
  },
  {
    "type": "put",
    "key": "nullable",
    "value": null
  }
]
~~~

the view is:

~~~json
{
  "nullable": null,
  "title": "Second"
}
~~~

nullable is present. draft is absent.

## 36. Epoch replacement example

Suppose epoch A currently views:

~~~json
{
  "title": "Old",
  "obsolete": true
}
~~~

A new epoch B names A as parent and has:

~~~json
{
  "values": {
    "title": "Migrated",
    "schema": 2
  }
}
~~~

Immediately after the epoch-B entry, the attributes view is:

~~~json
{
  "schema": 2,
  "title": "Migrated"
}
~~~

obsolete is absent because the base is a complete replacement. Later operations must name epoch B.

## Part III: Implementation and conformance

## 37. Package boundaries

### 37.1 commonplace-log-reducer

Recommended modules:

~~~text
Commonplace.LogReducer
Commonplace.LogReducer.State
Commonplace.LogReducer.Projection
Commonplace.LogReducer.Context
Commonplace.LogReducer.Error
Commonplace.LogReducer.Envelope
Commonplace.LogReducer.Plugin
Commonplace.LogReducer.Checkpoint
Commonplace.LogReducer.Registry
~~~

The package SHOULD depend on commonplace-log for shared entry validation/types when doing so does not create a dependency cycle. It MUST NOT depend on commonplace-document or any reducer plugin.

### 37.2 commonplace-attribute-map

Recommended modules:

~~~text
Commonplace.AttributeMap
Commonplace.AttributeMap.V1
Commonplace.AttributeMap.Validation
~~~

The package depends on commonplace-log-reducer and has no persistence, process, or web-framework dependency.

## 38. Conformance vectors

The libraries SHOULD share language-neutral JSON fixtures containing:

- an ordered list of complete Commonplace entries;
- the expected head;
- expected active projection metadata;
- expected canonical view;
- expected canonical checkpoint; or
- expected error code, reason, and failing coordinate.

Required reducer-engine cases include:

1. unrelated entries advance the head without changing projections;
2. a first epoch initializes a projection;
3. operations apply in sequence order;
4. two projections evolve independently at one shared head;
5. one projection changes epoch without resetting another;
6. a stale-epoch operation fails;
7. an operation before initialization fails;
8. a parent-epoch mismatch fails;
9. duplicate epoch ID fails;
10. unknown reducer version suspends/fails at the epoch entry;
11. malformed reducer namespace entry fails rather than being ignored;
12. a writer gap fails;
13. a second writer fails;
14. checkpoint round-trip preserves views and metadata;
15. checkpoint plus suffix equals full replay; and
16. changing created_at alone does not change reducer semantics.

Required attribute-map cases include:

1. empty initialization;
2. initialization from non-empty values;
3. put of a new key;
4. put overwrites an existing key;
5. delete removes an existing key;
6. delete of an absent key succeeds;
7. null remains present;
8. nested JSON values survive unchanged;
9. patch applies all changes;
10. patch rejects overlap atomically;
11. patch rejects duplicate delete keys;
12. malformed keys fail;
13. additional operation fields fail;
14. unknown operation type fails;
15. epoch replacement uses a complete base;
16. plugin checkpoint round-trip succeeds; and
17. identical entry order with different timestamps yields the same view.

## 39. Property tests

commonplace-log-reducer SHOULD property-test:

- full replay equals checkpoint restoration plus suffix replay;
- splitting input into arbitrary batches does not change the result;
- unrelated entries do not change any projection view;
- projection A operations do not change projection B;
- deterministic replay produces byte-equivalent canonical views and checkpoints; and
- reduction never advances past a failing entry.

commonplace-attribute-map SHOULD property-test:

- put followed by put yields the second value;
- put followed by delete yields absence;
- delete followed by put yields the put value;
- operations on distinct keys commute while preserving overall sequence semantics;
- a valid patch is equivalent to its puts and deletes applied in any order allowed by non-overlap;
- checkpoint and restore preserve the exact map; and
- all rejected operations leave state unchanged.

## 40. Documentation requirements

The package documentation MUST make these distinctions explicit:

- a projection epoch is not a log branch;
- a checkpoint is not canonical history;
- reducer version is not package version;
- attribute overwrite order is log sequence, not wall time;
- raw replica synchronization is not semantic Document synchronization;
- plugins are trusted installed code, not code named directly by untrusted input; and
- multi-writer reduction is unsupported in version 1.

## 41. Adoption sequence

The recommended implementation order is:

1. Define envelope validation and stable error structs.
2. Implement registry resolution without dynamic atom creation.
3. Implement ordered single-writer reduction and head tracking.
4. Implement epoch initialization and operation routing.
5. Implement commonplace-attribute-map version 1.
6. Add views and plugin checkpoints.
7. Add core checkpoint restoration and suffix verification.
8. Add shared conformance vectors.
9. Add property tests.
10. Integrate the attributes projection into a Document process.
11. Use commonplace-merkle-crdt as the second independent plugin proving the boundary.

## 42. Acceptance criteria

The two libraries are ready for first adoption when:

1. A log containing attributes and unrelated application events reconstructs the same attribute map after any restart.
2. The returned view names the exact processed log head and active attributes epoch.
3. Content and attributes may use independent epochs over the same log.
4. No caller or plugin uses created_at or replica arrival order as overwrite order.
5. Unknown reducer code halts at a precise entry rather than losing data silently.
6. A checkpoint can be discarded and rebuilt entirely from the log.
7. A checkpoint plus the remaining suffix is equivalent to full replay.
8. A second writer lane is rejected.
9. Attribute null and attribute deletion remain observably different.
10. commonplace-merkle-crdt can implement the same plugin behavior without changing the core reducer API.

## 43. Summary rule

> commonplace-log-reducer turns one ordered log into named, epoch-scoped views. commonplace-attribute-map is the smallest useful proof: a deterministic JSON map where the last operation in log order wins.
