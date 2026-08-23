defmodule Commonplace.LogReducer.Engine do
  @moduledoc """
  The section 16 processing algorithm.

  For each input entry, in order, the engine:

    1. validates log identity;
    2. pins or validates the one permitted writer ID;
    3. validates the next writer sequence and predecessor entry ID;
    4. classifies the body as unrelated, epoch, operation, or malformed;
    5. for an epoch, validates the envelope, resolves the plugin, initializes
       its state, and atomically replaces that projection;
    6. for an operation, validates the envelope and applies it to the active
       projection;
    7. if processing succeeds, advances the engine head to the entry; and
    8. if processing fails, returns the state through the preceding entry.

  Steps 1 through 3 belong to `Commonplace.LogReducer.State.validate_entry/2`
  and step 4 to `Commonplace.LogReducer.Envelope.classify/1`. This module owns
  steps 5 through 8: routing, the epoch rules of section 9.1, the operation
  rules of section 10.1, and the failure contract of section 15.1.

  ## Atomicity

  Section 16: "a plugin failure cannot partially install an epoch or partially
  update its projection." Every step below builds a *candidate* projection in
  full and only then returns a state containing it. There is no intermediate
  state in which a projection has the new epoch ID but the old plugin state, or
  a registered module but no initialized state. Since Elixir terms are
  immutable, a failure simply discards the candidate and hands back the state
  that entered the step -- there is nothing to roll back.

  ## Plugin errors

  A plugin's `{:error, reason}` is mapped to a section 21 code by *which
  callback* returned it, never by inspecting the reason:

  | callback | code |
  | --- | --- |
  | `init/2` | `invalid_epoch_base` (section 9.1.5) |
  | `apply/3` | `invalid_operation` (section 10.1.6) |

  with one exception, which overrides the table: a reason of the exact shape
  `{:missing_resource, key}` becomes `missing_resource`, whichever callback
  produced it. That is the single structurally recognized reason shape, and it
  exists because section 13 requires a reducer to return an explicit
  missing-resource error rather than acquire the resource itself; the engine
  must be able to tell that case apart to report the section 21 code for it.

  Every other reason is opaque. It is carried verbatim into
  `details.reason` and never matched on: section 21 states that
  human-readable messages are not protocol identifiers, so branching on a
  plugin's reason term would make one plugin's private vocabulary into
  protocol.
  """

  alias Commonplace.LogReducer.{Context, Envelope, Error, Projection, Registry, State}

  @typedoc "Either a section 21 error or a contract breach (see `reduce/3`)."
  @type error :: Error.t() | {:invalid_entry, map()}

  @doc """
  Reduces `entries` into `state` in input-log order (section 15).

  Returns `{:ok, state}`, or `{:error, error, state}` where `state` is the last
  successfully reduced prefix -- the state through the entry *preceding* the
  failure (sections 15.1 and 16.8). The failing entry alters no projection and
  does not advance the head.

  ## Options

    * `:resources` -- the section 13 map of immutable resource identifiers to
      already-resolved bytes or JSON values, handed to every plugin callback
      through the context. Defaults to `%{}`. Resource acquisition happens
      outside deterministic reduction; a plugin that finds one absent returns
      an explicit missing-resource error rather than fetching it.

  ## Two error shapes

  `error` is `%Commonplace.LogReducer.Error{}` for every section 21 code, but
  it can also be `{:invalid_entry, details}` for a *contract breach*: an entry
  that is not a map, or that is missing or ill-types one of the coordinate keys
  `log_id`, `entry_id`, `writer_id`, `writer_seq`, `prev_entry_id`, or `body`.
  That is a caller bug rather than a fact about durable history, so it is
  deliberately not laundered into one of the section 21 codes -- inventing a
  code for it would put a caller's type error into the same namespace as
  permanent-history verdicts. Section 15 leaves `error()` unspecified, which
  permits both shapes.

  **A caller that matches only on `%Error{}` will not see the contract-breach
  case.** Match `{:error, error, state}` and dispatch on the shape.
  """
  @spec reduce(State.t(), Enumerable.t(), keyword()) ::
          {:ok, State.t()} | {:error, error(), State.t()}
  def reduce(%State{} = state, entries, opts \\ []) do
    resources = Keyword.get(opts, :resources, %{})

    entries
    |> Enum.reduce_while({:ok, state}, fn entry, {:ok, acc} ->
      case entry(acc, entry, resources) do
        {:ok, next} -> {:cont, {:ok, next}}
        # Section 16.8: `acc` is the state through the preceding entry.
        {:error, error} -> {:halt, {:error, error, acc}}
      end
    end)
  end

  # One entry: steps 1 through 7. Returns the state INCLUDING this entry, or an
  # error, in which case the caller keeps the state that went in unchanged.
  defp entry(state, entry, resources) do
    with {:ok, coords} <- State.validate_entry(state, entry),
         {:ok, state} <- body(state, coords, resources) do
      # Section 16.7: the head advances only after the body has been processed
      # successfully. An unrelated body succeeds trivially and still advances
      # it (section 16, final paragraph).
      {:ok, State.advance(state, coords)}
    end
  end

  # Step 4, then step 5 or 6.
  defp body(state, coords, resources) do
    case Envelope.classify(coords.body) do
      {:unrelated, _body} -> {:ok, state}
      {:epoch, body} -> install_epoch(state, coords, body, resources)
      {:operation, body} -> apply_operation(state, coords, body, resources)
      {:error, %Error{} = err} -> {:error, with_coordinate(err, coords)}
    end
  end

  # -- step 5: epochs -------------------------------------------------------

  defp install_epoch(state, coords, body, resources) do
    name = body["projection"]
    active = Map.get(state.projections, name)

    with :ok <- check_parent(active, body, coords),
         :ok <- check_unseen(active, body, coords),
         {:ok, module} <- resolve_reducer(state, body, coords),
         {:ok, plugin_state} <- init_plugin(module, body, coords, resources) do
      # The candidate is complete before anything is installed. Nothing above
      # this line touched `state`.
      projection = %Projection{
        epoch_id: body["epoch_id"],
        seen_epoch_ids: MapSet.put(seen_epoch_ids(active), body["epoch_id"]),
        reducer_id: body["reducer"]["id"],
        reducer_version: body["reducer"]["version"],
        module: module,
        state: plugin_state,
        epoch_entry_id: coords.entry_id,
        epoch_writer_seq: coords.writer_seq
      }

      # Section 9.1.7: exactly one key of the projection map is replaced, so no
      # other projection can be altered by an epoch entry.
      {:ok, %{state | projections: Map.put(state.projections, name, projection)}}
    end
  end

  # Section 9.1.3 with plan decision D5. The set of epoch IDs a projection has
  # ever seen is PROJECTION-SCOPED STATE THAT OUTLIVES THE EPOCH THAT CARRIES
  # IT. Section 9.1.3 forbids reusing an epoch ID "for that projection" -- not
  # "for that epoch" -- and section 19 stores the set inside the projection,
  # which is the structure epoch replacement rebuilds.
  #
  # So the rebuild MUST carry the retired IDs forward. Starting a fresh set
  # here re-admits every ID retired by a replacement, which is silent
  # corruption of permanent history: replaying the same log twice would then
  # accept an epoch entry the first replay rejected. `engine_test.exs` pins
  # this directly ("seen_epoch_ids survives epoch replacement"), because the
  # bug passes every other test in the suite.
  defp seen_epoch_ids(nil), do: MapSet.new()
  defp seen_epoch_ids(%Projection{seen_epoch_ids: seen}), do: seen

  # Section 9.1.1 and 9.1.2: null for the first epoch of a projection,
  # otherwise the projection's currently active epoch. An ancestor that is no
  # longer active is as wrong as an unrelated UUID.
  defp check_parent(active, body, coords) do
    expected = if active, do: active.epoch_id
    actual = body["parent_epoch_id"]

    if expected == actual do
      :ok
    else
      error(:epoch_parent_mismatch, coords, body, %{expected: expected, actual: actual})
    end
  end

  # Section 9.1.3.
  defp check_unseen(active, body, coords) do
    epoch_id = body["epoch_id"]

    if active && MapSet.member?(active.seen_epoch_ids, epoch_id) do
      error(:duplicate_epoch, coords, body, %{epoch_id: epoch_id})
    else
      :ok
    end
  end

  # Section 9.1.4. The registry is trusted code configuration (section 22); a
  # durable entry only selects among already registered pairs.
  defp resolve_reducer(state, body, coords) do
    case Registry.resolve(state.registry, body["reducer"]["id"], body["reducer"]["version"]) do
      {:ok, module} -> {:ok, module}
      {:error, %Error{} = err} -> {:error, located(err, coords, body)}
    end
  end

  # Section 9.1.5: the new reducer initializes from `base` BEFORE the epoch
  # becomes active. `base` is self-contained -- the plugin is never handed a
  # previous reducer module's opaque state value.
  defp init_plugin(module, body, coords, resources) do
    context =
      context(coords, body,
        epoch_id: body["epoch_id"],
        reducer_id: body["reducer"]["id"],
        reducer_version: body["reducer"]["version"],
        resources: resources
      )

    case module.init(body["base"], context) do
      {:ok, plugin_state} -> {:ok, plugin_state}
      {:error, reason} -> plugin_error(:invalid_epoch_base, reason, coords, body)
      other -> plugin_error(:invalid_epoch_base, {:unexpected_return, other}, coords, body)
    end
  end

  # -- step 6: operations ---------------------------------------------------

  defp apply_operation(state, coords, body, resources) do
    name = body["projection"]

    with {:ok, active} <- require_active(state, coords, body),
         :ok <- check_epoch(active, body, coords),
         {:ok, plugin_state} <- apply_plugin(active, body, coords, resources) do
      # Section 10.1.3: the operation reached the active reducer instance of
      # exactly one projection, and only that projection's plugin state moved.
      projection = %{active | state: plugin_state}
      {:ok, %{state | projections: Map.put(state.projections, name, projection)}}
    end
  end

  # Section 10.1.1.
  defp require_active(state, coords, body) do
    case Map.fetch(state.projections, body["projection"]) do
      {:ok, active} ->
        {:ok, active}

      :error ->
        error(:projection_not_initialized, coords, body, %{epoch_id: body["epoch_id"]})
    end
  end

  # Section 10.1.2. An operation for an earlier or unknown epoch is invalid
  # durable history under this profile; admission code remaps or rejects it
  # before it is appended, so the engine only has to refuse it.
  defp check_epoch(active, body, coords) do
    if active.epoch_id == body["epoch_id"] do
      :ok
    else
      error(:stale_epoch, coords, body, %{expected: active.epoch_id, actual: body["epoch_id"]})
    end
  end

  # Section 10.1.6: stop at the failing entry. The refused operation produces no
  # partial update -- the candidate plugin state is simply discarded.
  defp apply_plugin(active, body, coords, resources) do
    context =
      context(coords, body,
        epoch_id: active.epoch_id,
        reducer_id: active.reducer_id,
        reducer_version: active.reducer_version,
        resources: resources
      )

    case active.module.apply(body["operation"], context, active.state) do
      {:ok, plugin_state} -> {:ok, plugin_state}
      {:error, reason} -> plugin_error(:invalid_operation, reason, coords, body)
      other -> plugin_error(:invalid_operation, {:unexpected_return, other}, coords, body)
    end
  end

  # -- shared ---------------------------------------------------------------

  defp context(coords, body, fields) do
    %Context{
      log_id: coords.log_id,
      writer_id: coords.writer_id,
      writer_seq: coords.writer_seq,
      entry_id: coords.entry_id,
      projection: body["projection"],
      epoch_id: Keyword.fetch!(fields, :epoch_id),
      reducer_id: Keyword.fetch!(fields, :reducer_id),
      reducer_version: Keyword.fetch!(fields, :reducer_version),
      resources: Keyword.fetch!(fields, :resources)
    }
  end

  # The plugin-error mapping. `{:missing_resource, key}` overrides the
  # callback's own code; every other reason is opaque and passes through
  # untouched, unexamined, into `details.reason`.
  defp plugin_error(_callback_code, {:missing_resource, key}, coords, body) do
    error(:missing_resource, coords, body, %{resource: key})
  end

  defp plugin_error(callback_code, reason, coords, body) do
    error(callback_code, coords, body, %{reason: reason})
  end

  defp error(code, coords, body, details) do
    {:error, located(Error.new(code, details: details), coords, body)}
  end

  defp located(%Error{} = err, coords, body) do
    %{
      err
      | log_id: coords.log_id,
        writer_seq: coords.writer_seq,
        entry_id: coords.entry_id,
        projection: err.projection || body["projection"]
    }
  end

  defp with_coordinate(%Error{} = err, coords) do
    %{err | log_id: coords.log_id, writer_seq: coords.writer_seq, entry_id: coords.entry_id}
  end
end
