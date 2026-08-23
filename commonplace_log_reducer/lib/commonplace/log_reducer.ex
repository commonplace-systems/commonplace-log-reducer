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

  Views and checkpoints (`view/2`, `views/1`, `checkpoint/1`, `restore/3`) are
  not implemented yet.
  """

  alias Commonplace.LogReducer.{Engine, Registry, State}

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
end
