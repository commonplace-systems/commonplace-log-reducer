defmodule Commonplace.LogReducer do
  @moduledoc """
  Deterministic reduction of a single-writer Commonplace log into named
  projections (section 15).

  A caller builds engine state for one log with `new/3` and feeds it entries in
  input-log order with `reduce/3`. Reduction is a pure function of the durable
  entries, the trusted registry, and explicitly supplied immutable resources:
  no clock, no randomness, no I/O, no ambient authority (sections 13, 20, 22).

      {:ok, state} = Commonplace.LogReducer.new(log_id, registry)
      {:ok, state} = Commonplace.LogReducer.reduce(state, entries)

  The registry is trusted code configuration, not durable data. Durable entries
  select only among pairs the host already registered (section 22).

  Views (`view/2`, `views/1`) are the application-facing read side; checkpoints
  (`checkpoint/1`, `restore/3`) are a derived, disposable accelerator for
  rebuilding state without replaying a whole log.

  ## Raw replica synchronization is not semantic Document synchronization
  (section 40)

  This engine is a pure function from entries to projections. It does not
  synchronize anything. When some other layer replicates the underlying log
  bytes between replicas, that is *raw replica synchronization*: it makes the
  same entries available in the same order somewhere else. It does not, by
  itself, mean two Documents agree semantically. Agreement here is a
  consequence of two things this module can state precisely: the entries a
  replica has actually reduced (the head in `view/2`), and the epoch under
  which it reduced them. Two replicas holding the same bytes but stopped at
  different heads, or running different registries, hold different views and
  are not synchronized in any sense this library will vouch for. Document
  messaging, Cell authority, and replica transport are owned elsewhere; see
  `README.md`.
  """

  alias Commonplace.LogReducer.{Checkpoint, Engine, Error, Projection, Registry, State}

  @type log_id :: String.t()
  @type registry :: Registry.t() | %{optional({String.t(), pos_integer()}) => module()}
  @type error :: Engine.error()

  @doc """
  Builds engine state for `log_id` (section 15).

  `registry` is a built `Commonplace.LogReducer.Registry` or the plain
  `%{{reducer_id, reducer_version} => module}` map of section 11, which is
  validated here.

  Options are those of `Commonplace.LogReducer.State.new/3`: `:writer_id`,
  `:head`, and `:projections`, which together let a caller resume mid-log
  rather than only from the start of a log.
  """
  @spec new(log_id(), registry(), keyword()) :: {:ok, State.t()} | {:error, term()}
  defdelegate new(log_id, registry, opts \\ []), to: State

  @doc """
  Reduces `entries` into `state` in input-log order (sections 15, 15.1, 16).

  Returns `{:ok, state}`, or `{:error, error, state}` where `state` is the last
  successfully reduced prefix -- the state through the entry preceding the
  failure. The failing entry alters no projection and does not advance the
  head. Because state is immutable, a caller that wants all-or-nothing batch
  behaviour simply keeps the state it passed in.

  `opts` carries `:resources`, the section 13 map of immutable resource
  identifiers to already-resolved values, supplied to every plugin callback
  through the context.

  `error` is a `%Commonplace.LogReducer.Error{}` carrying a section 21 code for
  every fact about the log, and `{:invalid_entry, details}` for a caller
  contract breach (an entry that is not a map, or whose coordinate keys are
  missing or ill-typed). **A caller matching only on `%Error{}` will miss the
  contract-breach case**; see `Commonplace.LogReducer.Engine.reduce/3` for why
  the two shapes stay distinct.
  """
  @spec reduce(State.t(), Enumerable.t(), keyword()) ::
          {:ok, State.t()} | {:error, error(), State.t()}
  defdelegate reduce(state, entries, opts \\ []), to: Engine

  @doc """
  The view of one projection (section 18).

  Returns `{:ok, %{head: head, epoch_id: epoch_id, value: json, ...}}` where:

    * `head` is the **shared** engine head -- the exact input-log coordinate
      through which *every* projection in this state has been processed, not a
      per-projection coordinate. Section 18: "all projections in one engine
      state are coherent at the same log head, even when an entry affected only
      one projection." An unrelated entry, or an entry for another projection,
      moves this projection's head too, because the head answers "as of when
      was this read", not "when did this last change";
    * `epoch_id` is the projection's currently active epoch; and
    * `value` is the plugin's canonical JSON view.

  Section 18 permits additional fields, which MUST NOT change `value`. Two are
  provided: `epoch_head`, the coordinate at which the active epoch was
  installed, and `reducer`, its resolved `%{id: ..., version: ...}`.

  ## Errors are not section 21 codes

  A view neither reduces an entry nor advances a head, so nothing about it is a
  fact about durable history. An unknown projection is
  `{:error, {:unknown_projection, name}}` -- deliberately not
  `projection_not_initialized`, which section 21 defines as "an operation
  arrived before the first epoch", a verdict about an *entry*. A plugin's own
  failure is `{:error, {:view_failed, name, reason}}` with the plugin's reason
  carried verbatim and never matched on.
  """
  @spec view(State.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def view(%State{} = state, name) do
    case Map.fetch(state.projections, name) do
      {:ok, projection} -> render(state, name, projection)
      :error -> {:error, {:unknown_projection, name}}
    end
  end

  @doc """
  Every initialized projection's view, keyed by projection name (section 18).

  All of them report the one shared head. A projection that has never been
  initialized has no view and does not appear; a fresh engine returns `%{}`.

  One plugin's failure fails the whole call, with that plugin's
  `{:view_failed, name, reason}`: a partial map would silently drop a
  projection the caller asked for.
  """
  @spec views(State.t()) :: {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  def views(%State{} = state) do
    state.projections
    |> Enum.sort_by(fn {name, _projection} -> name end)
    |> Enum.reduce_while({:ok, %{}}, fn {name, projection}, {:ok, acc} ->
      case render(state, name, projection) do
        {:ok, view} -> {:cont, {:ok, Map.put(acc, name, view)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Applies one of the plugin's own functions to one projection's state, inside
  the boundary, and returns whatever the plugin returned.

  `plugin_call(state, name, fun, args)` resolves the projection named `name`,
  and calls `fun` on the module that owns it with the plugin state as the first
  argument followed by `args`. The plugin state is handed only to the module
  that produced it; it never reaches the caller, and neither does the module.

  ## Why this exists, and why it is not an accessor

  A plugin's state is opaque to this engine and *should* be opaque to the
  host. But the plugin may define operations over its state beyond `view/1` --
  a merkle CRDT assembling one document by id, say -- and the host needs to
  reach them. An accessor returning the state would grant every operation the
  state permits, not the one the host wanted; so would a closure taking the
  state, since `fn _, s -> s end` is a closure. Moving the operation inside the
  boundary is the alternative: the host names the function, the engine does
  the calling.

  The engine's own callbacks (`Commonplace.LogReducer.Plugin`) are refused
  with `{:reserved_callback, name, fun, arity}`. They are the engine's to call,
  in order, with a section 13 context: running `apply/3` or `checkpoint/1`
  against a live state out of band is exactly the reach-in this function
  exists to prevent, whatever the return value.

  ## Errors

  Like `view/2`, none of these are section 21 codes; nothing here reduces an
  entry or moves a head.

    * `{:error, {:unknown_projection, name}}` -- as `view/2`;
    * `{:error, {:undefined_plugin_function, name, fun, arity}}` -- the
      plugin module exports no such `fun/arity`, where `arity` counts the
      state argument;
    * `{:error, {:reserved_callback, name, fun, arity}}` -- see above.

  The plugin's return value is wrapped as `{:ok, result}` verbatim, including
  a `{:error, _}` the plugin itself returned: the engine is not in a position
  to interpret it. Exceptions the plugin raises propagate, as they do from
  `view/2`.
  """
  @spec plugin_call(State.t(), String.t(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  def plugin_call(%State{} = state, name, fun, args) when is_atom(fun) and is_list(args) do
    arity = length(args) + 1

    with {:ok, %Projection{module: module} = projection} <- fetch_projection(state, name),
         :ok <- not_reserved(name, fun, arity),
         :ok <- exported(module, name, fun, arity) do
      {:ok, Kernel.apply(module, fun, [projection.state | args])}
    end
  end

  defp fetch_projection(%State{projections: projections}, name) do
    case Map.fetch(projections, name) do
      {:ok, projection} -> {:ok, projection}
      :error -> {:error, {:unknown_projection, name}}
    end
  end

  defp not_reserved(name, fun, arity) do
    if {fun, arity} in Registry.required_callbacks(),
      do: {:error, {:reserved_callback, name, fun, arity}},
      else: :ok
  end

  defp exported(module, name, fun, arity) do
    Code.ensure_loaded(module)

    if function_exported?(module, fun, arity),
      do: :ok,
      else: {:error, {:undefined_plugin_function, name, fun, arity}}
  end

  defp render(%State{} = state, name, %Projection{} = projection) do
    case projection.module.view(projection.state) do
      {:ok, value} ->
        {:ok,
         %{
           head: State.head(state),
           epoch_id: projection.epoch_id,
           value: value,
           epoch_head: %{
             writer_seq: projection.epoch_writer_seq,
             entry_id: projection.epoch_entry_id
           },
           reducer: %{id: projection.reducer_id, version: projection.reducer_version}
         }}

      {:error, reason} ->
        {:error, {:view_failed, name, reason}}

      other ->
        {:error, {:view_failed, name, {:unexpected_return, other}}}
    end
  end

  @doc """
  Serializes engine state as a version 1 checkpoint (section 19).

  See `Commonplace.LogReducer.Checkpoint` for the shape, for what section 19
  requires of it, and for the head verification it leaves to the caller.
  """
  @spec checkpoint(State.t()) :: {:ok, map()} | {:error, Error.t()}
  defdelegate checkpoint(state), to: Checkpoint, as: :build

  @doc """
  Rebuilds engine state from a version 1 checkpoint (section 19).

  A restored checkpoint is **not** verified against the log: section 19 makes
  that the caller's obligation. Before trusting the result, confirm that the
  named log still exists, that the head entry exists at the claimed writer
  sequence, and that its entry ID is identical. If verification fails, discard
  the checkpoint and rebuild from a known valid prefix.

  See `Commonplace.LogReducer.Checkpoint` for the validation performed here and
  the errors it produces.
  """
  @spec restore(map(), registry(), keyword()) :: {:ok, State.t()} | {:error, term()}
  defdelegate restore(checkpoint, registry, opts \\ []), to: Checkpoint
end
