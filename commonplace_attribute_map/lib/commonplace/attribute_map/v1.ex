defmodule Commonplace.AttributeMap.V1 do
  @moduledoc """
  commonplace-attribute-map, reducer protocol version 1 (spec sections 23-34).

  A deterministic JSON map over one ordered log: the value of a key at the log
  head is set by the last applicable operation at or before that head in
  **writer sequence order** (section 30). Nothing here reads `created_at`,
  entry UUIDs, the clock, or any field of the context -- the context is a
  coordinate for error reporting, never an input to the result.

  | Property | Value |
  | --- | --- |
  | Reducer ID | `commonplace.attribute-map` |
  | Reducer protocol version | 1 |
  | Default projection name | `attributes` |
  | View | JSON object |
  | External resources | none |

  Because version 1 requires no external resources, this module never returns
  `{:missing_resource, key}` and never reads `context.resources`.

  ## Overwrite order is log sequence, not wall time (section 40)

  When two operations write the same key, the winner is the one that comes
  **later in the log's writer sequence**. It is not the one with the later
  `created_at`, not the one that arrived at this replica later, and not the one
  whose clock says it happened last. `created_at` is a record of when a writer
  claims to have written; it is unverified, it can go backwards, and it plays
  no part in reduction here.

  The practical consequence for a caller: an operation appended later always
  wins, whatever any timestamp says, and two replicas reducing the same log
  prefix agree without needing their clocks to. A caller that sorts or filters
  by `created_at` before feeding entries in has changed the answer, and this
  plugin cannot detect that. Feed entries in log order.

  ## State

  The plugin state is the attribute map itself: a plain `%{String.t() => json}`.
  There is no wrapper, no tombstone set, and no provenance. `view/1` therefore
  returns the state unchanged (section 31) and `checkpoint/1` wraps it in the
  single-field object that is byte-identical in shape to an epoch base
  (section 32), so `init/2` accepts a checkpoint verbatim and `restore/2` is
  exactly `init/2`. One validation path, not two that can drift.

  ## Validate everything, then apply

  Every callback here validates completely before it constructs any new state.
  This matters most for `patch` (section 29), which MUST succeed or fail
  atomically: the natural implementation folds validation and mutation
  together, so a patch whose last key is invalid has already applied the
  earlier ones. `apply_patch/2` builds the full list of changes only after
  every key, every value, and both cross-checks (duplicate delete keys,
  put/delete overlap) have passed.

  ## Null is present

  `put` with a `null` value leaves the key **present** with the value null;
  only `delete` makes a key absent (sections 24 and 42.9). Nothing in this
  module collapses the two.
  """

  @behaviour Commonplace.LogReducer.Plugin

  # `apply/3` collides with `Kernel.apply/3`; without this the definition
  # below does not compile.
  import Kernel, except: [apply: 3]

  alias Commonplace.AttributeMap.Validation

  @reducer_id "commonplace.attribute-map"
  @reducer_version 1

  @base_fields ["values"]
  @put_fields ["type", "key", "value"]
  @delete_fields ["type", "key"]
  @patch_fields ["type", "put", "delete"]

  @type state :: %{optional(String.t()) => term()}

  @impl true
  def reducer_id, do: @reducer_id

  @impl true
  def reducer_version, do: @reducer_version

  @doc """
  Initializes an epoch from its base (section 26).

  The base has exactly one field, `values`, a JSON object whose keys and values
  satisfy sections 24 and 25. A later epoch base is a **complete replacement
  snapshot**: the state produced is exactly `base["values"]`, with no carry-over
  from any previous epoch. That falls out of this function taking no prior
  state as an argument.
  """
  @impl true
  def init(base, _context) when is_map(base) and not is_struct(base) do
    with :ok <- exact_fields(base, @base_fields, :base_fields),
         values = Map.fetch!(base, "values"),
         :ok <- Validation.validate_values(values) do
      {:ok, values}
    end
  end

  def init(base, _context), do: {:error, {:base_not_object, %{base: inspect(base)}}}

  @doc """
  Applies one addressed operation (sections 27, 28, 29).

  Dispatches on `type` and then checks the operation's field set exactly: no
  missing field and no additional field is permitted. An operation this version
  does not understand is rejected with `:unknown_operation` rather than
  ignored -- section 12.1 forbids silently skipping an operation addressed to
  this reducer, because silence lets history diverge invisibly.
  """
  @impl true
  def apply(operation, context, state)

  def apply(%{"type" => "put"} = operation, _context, state) do
    with :ok <- exact_fields(operation, @put_fields, :operation_fields),
         key = Map.fetch!(operation, "key"),
         value = Map.fetch!(operation, "value"),
         :ok <- Validation.validate_key(key),
         :ok <- Validation.validate_value(value) do
      {:ok, Map.put(state, key, value)}
    end
  end

  def apply(%{"type" => "delete"} = operation, _context, state) do
    with :ok <- exact_fields(operation, @delete_fields, :operation_fields),
         key = Map.fetch!(operation, "key"),
         :ok <- Validation.validate_key(key) do
      # Deleting an absent key is a success that changes nothing (section 28).
      {:ok, Map.delete(state, key)}
    end
  end

  def apply(%{"type" => "patch"} = operation, _context, state) do
    with :ok <- exact_fields(operation, @patch_fields, :operation_fields) do
      apply_patch(operation, state)
    end
  end

  def apply(operation, _context, _state) when is_map(operation) and not is_struct(operation) do
    case Map.fetch(operation, "type") do
      {:ok, type} ->
        {:error, {:unknown_operation, %{type: type}}}

      :error ->
        {:error, {:operation_fields, %{missing: ["type"], present: Map.keys(operation)}}}
    end
  end

  def apply(operation, _context, _state) do
    {:error, {:operation_fields, %{operation: inspect(operation)}}}
  end

  @doc "The view is exactly the current attribute map (section 31)."
  @impl true
  def view(state), do: {:ok, state}

  @doc """
  The plugin checkpoint (section 32): the same single-field object as an epoch
  base.

  It deliberately carries no log ID, writer ID, log head, projection name,
  epoch ID, or reducer identity. Those belong to the enclosing engine
  checkpoint; duplicating them here would create two sources of truth that can
  disagree.
  """
  @impl true
  def checkpoint(state), do: {:ok, %{"values" => state}}

  @doc """
  Restores from a checkpoint, validating it with exactly the rules `init/2`
  uses (section 32).

  A checkpoint is derived data that may be stale, truncated, or corrupt. It
  establishes no authority.
  """
  @impl true
  def restore(checkpoint, context), do: init(checkpoint, context)

  # -- patch ------------------------------------------------------------------

  # Validation is complete before the first change is made. Every early return
  # below leaves `state` untouched, which is what section 29's atomicity
  # requirement amounts to in an immutable language: never build the partial
  # map at all.
  defp apply_patch(operation, state) do
    put = Map.fetch!(operation, "put")
    delete = Map.fetch!(operation, "delete")

    with :ok <- Validation.validate_values(put),
         :ok <- validate_delete_list(delete),
         :ok <- no_overlap(put, delete) do
      {:ok,
       state
       |> Map.merge(put)
       |> Map.drop(delete)}
    end
  end

  defp validate_delete_list(delete) when is_list(delete) do
    Enum.reduce_while(delete, {:ok, MapSet.new()}, fn key, {:ok, seen} ->
      cond do
        match?({:error, _}, Validation.validate_key(key)) ->
          {:halt, Validation.validate_key(key)}

        MapSet.member?(seen, key) ->
          {:halt, {:error, {:duplicate_delete_key, %{key: key}}}}

        true ->
          {:cont, {:ok, MapSet.put(seen, key)}}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, _} = error -> error
    end
  end

  defp validate_delete_list(delete),
    do: {:error, {:delete_not_array, %{delete: inspect(delete)}}}

  defp no_overlap(put, delete) do
    case Enum.filter(delete, &Map.has_key?(put, &1)) do
      [] -> :ok
      [key | _] -> {:error, {:overlapping_patch_key, %{key: key}}}
    end
  end

  # -- shape ------------------------------------------------------------------

  # Exact field sets: no additional fields, no missing fields (sections 26-29).
  defp exact_fields(map, expected, reason) do
    present = Map.keys(map)

    case {expected -- present, present -- expected} do
      {[], []} ->
        :ok

      {missing, extra} ->
        {:error, {reason, %{missing: missing, unexpected: extra}}}
    end
  end
end
