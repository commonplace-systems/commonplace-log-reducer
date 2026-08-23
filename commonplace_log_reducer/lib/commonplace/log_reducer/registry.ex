defmodule Commonplace.LogReducer.Registry do
  @moduledoc """
  The host-supplied reducer registry of section 11.

  A registry maps durable wire identifiers -- `{reducer_id, reducer_version}`
  where the ID is a binary and the version a positive integer -- to Elixir
  modules implementing the reducer plugin callbacks.

  ## Plugins are trusted installed code, not code named by untrusted input
  (sections 22, 40)

  A registry entry is code the *host operator* installed and wrote down, in
  code, at startup. A durable log entry only ever *selects* among entries that
  are already there, by `{reducer_id, reducer_version}` string and integer. An
  entry naming something unregistered is `unknown_reducer` and reduction
  halts; it is never a request to go and find, load, or name code. Anyone who
  can write to the log therefore chooses among the plugins the host already
  trusts, and can do nothing else. Adding a plugin is a deployment decision,
  not a log entry.

  Registry contents are trusted code configuration (section 22). Durable log
  content selects only among already-registered identifiers; it never names a
  module. Accordingly this module never converts a reducer string into an atom,
  never interprets a stored module name, and never loads code during
  resolution. `Code.ensure_loaded?/1` is used at *build* time only, so that
  `function_exported?/3` reports a module's real exports rather than reporting
  a not-yet-loaded module as callback-less.

  Resolution is exact. A registered ID at an unregistered version is
  `:unknown_reducer`, never a fallback to a neighbouring version, and never a
  silent skip.

  Identity (section 12.1) is checked at build time: a plugin MUST report the
  exact ID and version under which it is registered. Catching a mismatch at
  registration turns a silent data-corruption bug -- a plugin reducing under
  another reducer's identity and writing checkpoints labelled with the wrong
  ID -- into a startup error.
  """

  alias Commonplace.LogReducer.Error

  # Derived from the behaviour itself rather than restated here, so the
  # registry cannot drift from section 12's callback list: adding a callback to
  # `Commonplace.LogReducer.Plugin` immediately tightens registration.
  @required_callbacks Commonplace.LogReducer.Plugin.behaviour_info(:callbacks)

  @enforce_keys [:entries]
  defstruct entries: %{}

  @type reducer_id :: String.t()
  @type reducer_version :: pos_integer()
  @type key :: {reducer_id(), reducer_version()}
  @type t :: %__MODULE__{entries: %{optional(key()) => module()}}

  @doc "The callbacks a registered module must export."
  @spec required_callbacks() :: keyword(arity())
  def required_callbacks, do: @required_callbacks

  @doc """
  Validates a host-supplied `%{{id, version} => module}` map.

  Returns `{:ok, registry}` or `{:error, {:invalid_registry, reason}}`, where
  reason is `:not_a_map` or a list of `{key, problem}` pairs, one per rejected
  entry, sorted by key.
  """
  @spec build(map()) :: {:ok, t()} | {:error, {:invalid_registry, term()}}
  def build(entries) when is_map(entries) do
    problems =
      entries
      |> Enum.flat_map(fn {key, module} ->
        case validate_entry(key, module) do
          :ok -> []
          {:error, problem} -> [{key, problem}]
        end
      end)
      |> Enum.sort_by(fn {key, _problem} -> inspect(key) end)

    case problems do
      [] -> {:ok, %__MODULE__{entries: entries}}
      _ -> {:error, {:invalid_registry, problems}}
    end
  end

  def build(_other), do: {:error, {:invalid_registry, :not_a_map}}

  @doc """
  Resolves a durable `{reducer_id, reducer_version}` pair to its module.

  The ID stays a binary throughout; nothing here can create an atom from it.
  Any pair not present exactly as registered is `:unknown_reducer`.
  """
  @spec resolve(t(), reducer_id(), reducer_version()) ::
          {:ok, module()} | {:error, Error.t()}
  def resolve(%__MODULE__{entries: entries}, reducer_id, reducer_version)
      when is_binary(reducer_id) and is_integer(reducer_version) and reducer_version > 0 do
    case Map.fetch(entries, {reducer_id, reducer_version}) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, unknown(reducer_id, reducer_version)}
    end
  end

  def resolve(%__MODULE__{}, reducer_id, reducer_version) do
    {:error, unknown(reducer_id, reducer_version)}
  end

  defp unknown(reducer_id, reducer_version) do
    Error.new(:unknown_reducer,
      details: %{reducer_id: reducer_id, reducer_version: reducer_version}
    )
  end

  defp validate_entry({id, version}, module)
       when is_binary(id) and is_integer(version) and version > 0 and is_atom(module) do
    _ = Code.ensure_loaded?(module)

    case Enum.reject(@required_callbacks, fn {f, a} -> function_exported?(module, f, a) end) do
      [] -> validate_identity(id, version, module)
      missing -> {:error, {:missing_callbacks, missing}}
    end
  end

  defp validate_entry(_key, _module), do: {:error, :not_a_reducer_key}

  defp validate_identity(id, version, module) do
    reported_id = module.reducer_id()
    reported_version = module.reducer_version()

    cond do
      reported_id != id ->
        {:error, {:reducer_id_mismatch, %{registered: id, reported: reported_id}}}

      reported_version != version ->
        {:error, {:reducer_version_mismatch, %{registered: version, reported: reported_version}}}

      true ->
        :ok
    end
  end
end
