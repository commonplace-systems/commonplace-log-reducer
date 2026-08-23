defmodule Commonplace.LogReducer.Checkpoint do
  @moduledoc """
  The version 1 checkpoint format (section 19): building one from engine state,
  and restoring engine state from one.

  A checkpoint is **derived and disposable** (section 5.8). It accelerates
  reconstruction; it creates no epoch, alters no history, establishes no
  authority, and never permits an entry to be skipped without head
  verification. Everything in it can be rebuilt by replaying the log.

  ## A checkpoint is not canonical history (section 40)

  The log is the canonical history. A checkpoint is a cache of a *reading* of
  it, and the log wins in every disagreement. Concretely: a checkpoint is
  always safe to delete, because the same state is reachable by replaying the
  log from the start; a checkpoint that disagrees with the log is the thing
  that is wrong, never the log; and no fact enters history by being written
  into a checkpoint. Nothing is ever *only* in a checkpoint. If it were, this
  would be a storage format with a log-shaped accelerator, which is the
  opposite arrangement.

  ## Shape

      %{
        "version" => 1,
        "log_id" => log_id,
        "writer_id" => writer_id,
        "head" => %{"writer_seq" => seq, "entry_id" => entry_id},
        "projections" => %{
          name => %{
            "epoch_id" => epoch_id,
            "seen_epoch_ids" => [sorted],
            "epoch_head" => %{"writer_seq" => seq, "entry_id" => entry_id},
            "reducer" => %{"id" => id, "version" => version},
            "state" => plugin_checkpoint
          }
        }
      }

  String keys throughout, and only JSON values, so the result can be handed
  straight to a JSON encoder (section 20 asks the conformance suite to compare
  runs through RFC 8785 canonical JSON).

  ## What section 19 makes this module do

    * **sort `seen_epoch_ids` lexically when encoding** -- the set lives in a
      `MapSet`, whose enumeration order is term order and therefore an accident
      of insertion; two runs that saw the same epochs in different orders must
      still serialize identically (section 20);
    * **validate every identifier and coordinate when restoring**;
    * **resolve the exact reducer ID and version from the registry** -- never a
      neighbouring version;
    * **call each plugin's `restore/2`** rather than reinstating a stored term;
    * **reject duplicate or malformed projection names**; and
    * **reject a checkpoint using several writer IDs.**

  ## What this module deliberately does NOT do

  Section 19 makes head verification the **caller's** obligation: before
  trusting a restored checkpoint the caller must confirm the named log still
  exists, that the head entry exists at the claimed writer sequence, and that
  its entry ID is identical. This module cannot do any of that -- it has no log
  and, by section 22, no ambient authority to go and read one.

  What it does provide is the half that *is* enforceable locally: the restored
  state's head is exactly the checkpoint's head, so the very next entry the
  engine will accept is `head.writer_seq + 1` with `head.entry_id` as its
  predecessor. A checkpoint whose head does not match the real log therefore
  fails at the first entry with `writer_gap` or `writer_fork` rather than
  silently reducing the wrong suffix. That is a backstop, not the verification:
  a checkpoint for a log that was rewritten from an earlier point can still
  present a self-consistent chain, which is why section 19 puts the "does this
  entry really exist, with this ID, at this sequence" question on the caller.

  ## Duplicate projection names, when a map cannot hold one

  An Elixir map cannot hold the same key twice, so `"reject duplicate ...
  projection names"` only bites for a checkpoint that has *not* been through a
  map. That is a real shape: a duplicate-preserving JSON decoder (Jason's
  `objects: :ordered_objects`) yields an ordered object whose members are a
  list of pairs. `projections` is therefore accepted as a map, as a
  `Jason.OrderedObject`, or as a plain list of `{name, spec}` pairs, and the
  duplicate check runs on the pair list before anything is looked up. Restoring
  from the pre-collapse shape is the only place the check can ever fire; a
  caller who decodes into plain maps has already lost the evidence.

  ## Plugin errors

  Extending the table in `Commonplace.LogReducer.Engine`, and matching
  `docs/PLUGIN_AUTHORS.md`:

  | callback | code |
  | --- | --- |
  | `checkpoint/1` | `invalid_checkpoint` |
  | `restore/2` | `invalid_checkpoint` |

  with the same override: a reason of the exact shape
  `{:missing_resource, key}` becomes `missing_resource`, whichever callback
  produced it. Every other reason is opaque and is carried verbatim into
  `details.reason`.
  """

  alias Commonplace.LogReducer.{Context, Envelope, Error, Projection, Registry, State}

  @version 1

  @required_fields ["version", "log_id", "writer_id", "head", "projections"]
  @required_projection_fields [
    "epoch_id",
    "seen_epoch_ids",
    "epoch_head",
    "reducer",
    "state"
  ]

  @doc """
  Builds a version 1 checkpoint from engine state (section 19).

  Returns `{:error, %Error{code: :invalid_checkpoint}}` when the state has no
  head to name (nothing has been reduced and nothing was seeded), or when a
  plugin refuses or mis-shapes its own checkpoint, and
  `{:error, %Error{code: :missing_resource}}` when a plugin reports a missing
  immutable resource.
  """
  @spec build(State.t()) :: {:ok, map()} | {:error, Error.t()}
  def build(%State{} = state) do
    with {:ok, head} <- require_head(state),
         {:ok, projections} <- build_projections(state, head) do
      {:ok,
       %{
         "version" => @version,
         "log_id" => state.log_id,
         "writer_id" => state.writer_id,
         "head" => %{"writer_seq" => head.writer_seq, "entry_id" => head.entry_id},
         "projections" => projections
       }}
    end
  end

  defp require_head(%State{} = state) do
    case State.head(state) do
      nil ->
        # Section 19 requires a head coordinate and section 5.8 defines a
        # checkpoint as state "at an exact log head". A state that has reduced
        # nothing has no such coordinate, so there is nothing to serialize --
        # and a checkpoint claiming sequence 0 would be a coordinate that can
        # never appear in a log.
        {:error, core_error(state.log_id, nil, nil, %{reason: :no_head})}

      head when is_binary(state.writer_id) ->
        {:ok, head}

      head ->
        # Unreachable through the engine (advancing the head pins the writer),
        # but a caller may seed a head through `State.new/3`.
        {:error, core_error(state.log_id, head, nil, %{reason: :no_writer_id})}
    end
  end

  defp build_projections(state, head) do
    state.projections
    # Sorted so that a checkpoint of a state with two failing projections
    # reports the same one every run (section 20).
    |> Enum.sort_by(fn {name, _projection} -> name end)
    |> Enum.reduce_while({:ok, %{}}, fn {name, projection}, {:ok, acc} ->
      case plugin_checkpoint(state, head, name, projection) do
        {:ok, plugin_state} ->
          {:cont, {:ok, Map.put(acc, name, encode_projection(projection, plugin_state))}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp encode_projection(%Projection{} = projection, plugin_state) do
    %{
      "epoch_id" => projection.epoch_id,
      # Section 19: sorted lexically ON ENCODE. The MapSet's own order is term
      # order, which is not the sorted order in general.
      "seen_epoch_ids" => projection.seen_epoch_ids |> MapSet.to_list() |> Enum.sort(),
      "epoch_head" => %{
        "writer_seq" => projection.epoch_writer_seq,
        "entry_id" => projection.epoch_entry_id
      },
      "reducer" => %{"id" => projection.reducer_id, "version" => projection.reducer_version},
      "state" => plugin_state
    }
  end

  defp plugin_checkpoint(state, head, name, %Projection{} = projection) do
    case projection.module.checkpoint(projection.state) do
      {:ok, plugin_state} when is_map(plugin_state) and not is_struct(plugin_state) ->
        {:ok, plugin_state}

      {:ok, _other} ->
        # Section 12.1: a plugin MUST return JSON-object checkpoints. A
        # non-object cannot be re-read by `restore/2` and would be a corrupt
        # checkpoint discovered only on the next restart.
        plugin_error(state.log_id, head, name, %{reason: :plugin_checkpoint_not_an_object})

      {:error, reason} ->
        plugin_error(state.log_id, head, name, %{reason: reason})

      other ->
        plugin_error(state.log_id, head, name, %{reason: {:unexpected_return, other}})
    end
  end

  # ==========================================================================
  # restore
  # ==========================================================================

  @doc """
  Rebuilds engine state from a version 1 checkpoint (section 19).

  `registry` is a built `Commonplace.LogReducer.Registry` or the plain
  `%{{id, version} => module}` map of section 11. `opts` carries `:resources`,
  the section 13 map handed to every plugin's `restore/2` through the context.

  Returns `{:error, %Error{code: :invalid_checkpoint}}` for core or plugin
  checkpoint validation failure, `{:error, %Error{code: :unknown_reducer}}`
  when the exact reducer pair is not registered,
  `{:error, %Error{code: :missing_resource}}` when a plugin reports a missing
  immutable resource, and `{:error, {:invalid_registry, _}}` for an unusable
  registry.
  """
  @spec restore(term(), Registry.t() | map(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def restore(checkpoint, registry, opts \\ []) do
    resources = Keyword.get(opts, :resources, %{})

    with {:ok, registry} <- registry(registry),
         {:ok, fields} <- top_level(checkpoint),
         {:ok, log_id} <- non_empty_string(fields, "log_id", :invalid_log_id, nil, nil),
         {:ok, writer_id} <-
           non_empty_string(fields, "writer_id", :invalid_writer_id, log_id, nil),
         {:ok, head} <- head(fields, log_id),
         {:ok, specs} <- projection_specs(fields, log_id, head),
         :ok <- one_writer(specs, writer_id, log_id, head),
         {:ok, projections} <-
           restore_projections(specs, registry, log_id, writer_id, head, resources) do
      State.new(log_id, registry,
        writer_id: writer_id,
        head: %{writer_seq: head.writer_seq, entry_id: head.entry_id},
        projections: projections
      )
    end
  end

  defp registry(%Registry{} = registry), do: {:ok, registry}
  defp registry(entries) when is_map(entries), do: Registry.build(entries)
  defp registry(other), do: {:error, {:invalid_registry, other}}

  defp top_level(checkpoint) do
    with {:ok, pairs} <- object(checkpoint),
         :ok <- no_duplicates(pairs, :duplicate_field, nil, nil),
         fields = Map.new(pairs),
         :ok <- required(fields, @required_fields, nil, nil),
         :ok <- version(fields) do
      {:ok, fields}
    else
      :not_an_object -> {:error, core_error(nil, nil, nil, %{reason: :not_an_object})}
      {:error, %Error{}} = error -> error
    end
  end

  defp version(%{"version" => @version}), do: :ok

  defp version(fields) do
    {:error, core_error(nil, nil, nil, %{reason: :unsupported_version, value: fields["version"]})}
  end

  defp head(fields, log_id) do
    case fields["head"] do
      %{"writer_seq" => seq, "entry_id" => entry_id} = head
      when is_integer(seq) and seq > 0 and is_binary(entry_id) and entry_id != "" and
             not is_struct(head) ->
        {:ok, %{writer_seq: seq, entry_id: entry_id}}

      value ->
        {:error, core_error(log_id, nil, nil, %{reason: :invalid_head, value: value})}
    end
  end

  defp projection_specs(fields, log_id, head) do
    with {:ok, pairs} <- object(fields["projections"]),
         :ok <- no_duplicates(pairs, :duplicate_projection_name, log_id, head) do
      {:ok, pairs}
    else
      :not_an_object ->
        {:error,
         core_error(log_id, head, nil, %{
           reason: :invalid_projections,
           value: fields["projections"]
         })}

      {:error, %Error{}} = error ->
        error
    end
  end

  # Section 19: "reject a checkpoint using several writer IDs." Section 5.6
  # permits a writer ID to be stored alongside a head, so a producer may repeat
  # one per projection -- but every writer ID a single checkpoint carries names
  # the same lane, because version 1 has exactly one (section 17).
  defp one_writer(specs, writer_id, log_id, head) do
    ids =
      specs
      |> Enum.flat_map(fn {_name, spec} ->
        case spec do
          %{"writer_id" => id} when not is_struct(spec) -> [id]
          _ -> []
        end
      end)
      |> Enum.concat([writer_id])
      |> Enum.uniq()

    case ids do
      [_one] ->
        :ok

      several ->
        {:error,
         core_error(log_id, head, nil, %{reason: :several_writer_ids, writer_ids: several})}
    end
  end

  defp restore_projections(specs, registry, log_id, writer_id, head, resources) do
    Enum.reduce_while(specs, {:ok, %{}}, fn {name, spec}, {:ok, acc} ->
      case restore_projection(name, spec, registry, log_id, writer_id, head, resources) do
        {:ok, projection} -> {:cont, {:ok, Map.put(acc, name, projection)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp restore_projection(name, spec, registry, log_id, writer_id, head, resources) do
    with :ok <- projection_name(name, log_id, head),
         {:ok, fields} <- projection_object(name, spec, log_id, head),
         :ok <- required(fields, @required_projection_fields, log_id, head, name),
         {:ok, epoch_id} <-
           non_empty_string(fields, "epoch_id", :invalid_epoch_id, log_id, head, name),
         {:ok, seen} <- seen_epoch_ids(fields, log_id, head, name),
         {:ok, epoch_head} <- epoch_head(fields, log_id, head, name),
         {:ok, reducer_id, reducer_version} <- reducer(fields, log_id, head, name),
         {:ok, plugin_checkpoint} <- plugin_state(fields, log_id, head, name),
         {:ok, module} <- resolve(registry, reducer_id, reducer_version, log_id, head, name),
         {:ok, plugin_state} <-
           call_restore(module, plugin_checkpoint, log_id, writer_id, head, name, epoch_id,
             reducer_id: reducer_id,
             reducer_version: reducer_version,
             resources: resources
           ) do
      {:ok,
       %Projection{
         epoch_id: epoch_id,
         seen_epoch_ids: seen,
         reducer_id: reducer_id,
         reducer_version: reducer_version,
         module: module,
         state: plugin_state,
         epoch_entry_id: epoch_head.entry_id,
         epoch_writer_seq: epoch_head.writer_seq
       }}
    end
  end

  # Section 7 is the same rule a live epoch entry is held to; a checkpoint is
  # not a way around it. Section 21 classifies the failure by WHERE it was
  # found: inside a checkpoint it is checkpoint validation, so the code is
  # invalid_checkpoint with the specific reason in the details, not
  # invalid_projection_name (which names an entry that violated section 7).
  defp projection_name(name, log_id, head) do
    if is_binary(name) and Envelope.valid_projection_name?(name) do
      :ok
    else
      {:error,
       core_error(log_id, head, nil, %{reason: :invalid_projection_name, projection: name})}
    end
  end

  defp projection_object(name, spec, log_id, head) do
    case object(spec) do
      {:ok, pairs} ->
        case no_duplicates(pairs, :duplicate_field, log_id, head, name) do
          :ok -> {:ok, Map.new(pairs)}
          {:error, _} = error -> error
        end

      :not_an_object ->
        {:error, core_error(log_id, head, name, %{reason: :invalid_projection, value: spec})}
    end
  end

  defp seen_epoch_ids(fields, log_id, head, name) do
    seen = fields["seen_epoch_ids"]

    if is_list(seen) and Enum.all?(seen, &(is_binary(&1) and &1 != "")) do
      {:ok, MapSet.new(seen)}
    else
      {:error, core_error(log_id, head, name, %{reason: :invalid_seen_epoch_ids, value: seen})}
    end
  end

  defp epoch_head(fields, log_id, head, name) do
    case fields["epoch_head"] do
      %{"writer_seq" => seq, "entry_id" => entry_id} = value
      when is_integer(seq) and seq > 0 and is_binary(entry_id) and entry_id != "" and
             not is_struct(value) ->
        {:ok, %{writer_seq: seq, entry_id: entry_id}}

      value ->
        {:error, core_error(log_id, head, name, %{reason: :invalid_epoch_head, value: value})}
    end
  end

  defp reducer(fields, log_id, head, name) do
    case fields["reducer"] do
      %{"id" => id, "version" => version} = value
      when is_binary(id) and id != "" and is_integer(version) and version > 0 and
             not is_struct(value) ->
        {:ok, id, version}

      value ->
        {:error, core_error(log_id, head, name, %{reason: :invalid_reducer, value: value})}
    end
  end

  defp plugin_state(fields, log_id, head, name) do
    case fields["state"] do
      value when is_map(value) and not is_struct(value) ->
        {:ok, value}

      value ->
        {:error,
         core_error(log_id, head, name, %{reason: :plugin_state_not_an_object, value: value})}
    end
  end

  defp resolve(registry, reducer_id, reducer_version, log_id, head, name) do
    case Registry.resolve(registry, reducer_id, reducer_version) do
      {:ok, module} ->
        {:ok, module}

      {:error, %Error{} = err} ->
        {:error,
         %{
           err
           | log_id: log_id,
             writer_seq: head.writer_seq,
             entry_id: head.entry_id,
             projection: name
         }}
    end
  end

  # Section 19: "call each plugin's restore callback." The stored plugin state
  # is JSON the plugin wrote; only the plugin can turn it back into its own
  # term, and section 12.1 requires it to validate the checkpoint first.
  defp call_restore(module, plugin_checkpoint, log_id, writer_id, head, name, epoch_id, fields) do
    context = %Context{
      log_id: log_id,
      writer_id: writer_id,
      # The coordinate of the state being rebuilt is the CHECKPOINT HEAD, not
      # the epoch start: this is the state as of the head.
      writer_seq: head.writer_seq,
      entry_id: head.entry_id,
      projection: name,
      epoch_id: epoch_id,
      reducer_id: Keyword.fetch!(fields, :reducer_id),
      reducer_version: Keyword.fetch!(fields, :reducer_version),
      resources: Keyword.fetch!(fields, :resources)
    }

    case module.restore(plugin_checkpoint, context) do
      {:ok, plugin_state} -> {:ok, plugin_state}
      {:error, reason} -> plugin_error(log_id, head, name, %{reason: reason})
      other -> plugin_error(log_id, head, name, %{reason: {:unexpected_return, other}})
    end
  end

  # ==========================================================================
  # shared shape helpers
  # ==========================================================================

  # A JSON object as an ordered list of pairs, whatever decoder produced it:
  # a plain map, a duplicate-preserving `Jason.OrderedObject`, or the list of
  # pairs such an object carries. Only the pair-list forms can still show a
  # duplicate key; a map has already collapsed it.
  defp object(%Jason.OrderedObject{values: values}), do: pairs(values)
  defp object(%_{}), do: :not_an_object
  defp object(map) when is_map(map), do: {:ok, Map.to_list(map)}
  defp object(list) when is_list(list), do: pairs(list)
  defp object(_other), do: :not_an_object

  defp pairs(list) do
    Enum.reduce_while(list, {:ok, []}, fn
      {key, value}, {:ok, acc} when is_binary(key) -> {:cont, {:ok, [{key, value} | acc]}}
      [key, value], {:ok, acc} when is_binary(key) -> {:cont, {:ok, [{key, value} | acc]}}
      _other, _acc -> {:halt, :not_an_object}
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :not_an_object -> :not_an_object
    end
  end

  defp no_duplicates(pairs, reason, log_id, head, projection \\ nil) do
    names = Enum.map(pairs, fn {key, _value} -> key end)

    case names -- Enum.uniq(names) do
      [] ->
        :ok

      [duplicate | _] ->
        {:error, core_error(log_id, head, projection, %{reason: reason, projection: duplicate})}
    end
  end

  defp required(fields, keys, log_id, head, projection \\ nil) do
    case Enum.reject(keys, &Map.has_key?(fields, &1)) do
      [] ->
        :ok

      [field | _] = missing ->
        {:error,
         core_error(log_id, head, projection, %{
           reason: :missing_field,
           field: field,
           missing: missing
         })}
    end
  end

  defp non_empty_string(fields, key, reason, log_id, head, projection \\ nil) do
    case fields[key] do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      value ->
        {:error, core_error(log_id, head, projection, %{reason: reason, value: value})}
    end
  end

  # ==========================================================================
  # errors
  # ==========================================================================

  # Section 21: "invalid_checkpoint -- core or plugin checkpoint validation
  # failed." Both halves land here; `details.reason` says which and why.
  defp core_error(log_id, head, projection, details) do
    Error.new(:invalid_checkpoint,
      log_id: log_id,
      writer_seq: head && head.writer_seq,
      entry_id: head && head.entry_id,
      projection: projection,
      details: details
    )
  end

  # The plugin-error mapping. `{:missing_resource, key}` overrides
  # `invalid_checkpoint`, exactly as it overrides the engine's own two codes;
  # every other reason is opaque and never matched on.
  defp plugin_error(log_id, head, projection, %{reason: {:missing_resource, key}}) do
    {:error,
     Error.new(:missing_resource,
       log_id: log_id,
       writer_seq: head && head.writer_seq,
       entry_id: head && head.entry_id,
       projection: projection,
       details: %{resource: key}
     )}
  end

  defp plugin_error(log_id, head, projection, details) do
    {:error, core_error(log_id, head, projection, details)}
  end
end
