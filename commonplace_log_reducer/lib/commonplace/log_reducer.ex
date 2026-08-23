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
