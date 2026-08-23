defmodule Conformance do
  @moduledoc """
  The shared harness behind the `conformance/reducer-engine` and
  `conformance/attribute-map` corpora (specification section 38), **for tests
  only**.

  It lives in `test_support/` because both projects run the same vector format
  against the same engine API and only differ in which corpus they read and
  which fixture keys they can resolve. One harness, so a fix to the comparison
  cannot land in one project and quietly not the other.

  ## The fixture-key indirection

  A vector's `registry` entry is `%{"id" => ..., "version" => ..., "plugin" =>
  key}` where `key` is a **corpus-level fixture key**, never an Elixir module
  name. Section 11 forbids interpreting a stored module name, and a
  language-neutral corpus has no business naming one. `registry/2` maps the key
  to a module using a table the *caller* supplies, so the corpus stays portable
  and the trust boundary stays where section 22 puts it: in code
  configuration.

  ## Comparison is canonical JSON bytes, not Elixir terms

  Section 20 asks for RFC 8785 when comparing runs, so every comparison here
  goes through `Jcs.encode!/1`. Comparing Elixir terms instead would make
  `1` and `1.0`, or two maps with differently-typed keys, compare as they
  happen to compare in the BEAM rather than as JSON.

  ## What `actual/2` takes from expected

  An `expected.json` error object may omit the optional `reason` and `views`
  fields. `actual/2` therefore restricts the produced map to exactly the keys
  the vector states. A key the vector states and the implementation does not
  produce is simply absent from the restriction, so it still mismatches -- the
  restriction can weaken a vector, never a run.

  `reason` is a normalization, not a protocol identifier: section 21 says
  human-readable messages are not protocol identifiers, and a plugin's reason
  term is opaque. What is compared is the leading atom of `details.reason`,
  rendered as a string, which is the part section 33 makes stable.
  """

  alias Commonplace.LogReducer
  alias Commonplace.LogReducer.{Error, State}

  @doc """
  Case directories of a corpus, sorted.

  Filtered to DIRECTORIES: a `README.md` sitting beside the cases is not a case
  and must not be counted as one, or the count floor goes red and sends the
  reader hunting a case that was never missing.
  """
  @spec case_dirs(Path.t()) :: [Path.t()]
  def case_dirs(corpus) do
    corpus
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort()
  end

  @doc """
  Reads one case as `{input, expected}`, both decoded.

  `File.read!` and not `File.read`: a swallowed `{:error, :enoent}` defaulting
  to an empty document is exactly how a harness stops reading its corpus while
  staying green.
  """
  @spec read_case(Path.t()) :: {map(), map()}
  def read_case(dir) do
    input = dir |> Path.join("input.json") |> File.read!() |> Jason.decode!()
    expected = dir |> Path.join("expected.json") |> File.read!() |> Jason.decode!()
    {input, expected}
  end

  @doc "Builds the section 11 registry map from a vector's fixture keys."
  @spec registry(map(), %{optional(String.t()) => module()}) :: map()
  def registry(input, plugins) do
    Map.new(input["registry"], fn entry ->
      {{entry["id"], entry["version"]}, Map.fetch!(plugins, entry["plugin"])}
    end)
  end

  @doc "Reduces a whole vector in one batch."
  @spec run(map(), %{optional(String.t()) => module()}) ::
          {:ok, State.t()} | {:error, term(), State.t()}
  def run(input, plugins) do
    {:ok, state} = LogReducer.new(input["log_id"], registry(input, plugins))
    LogReducer.reduce(state, input["entries"])
  end

  @doc """
  Reduces the first `split_at` entries, checkpoints, restores, and reduces the
  rest (section 42.7). The result must equal `run/2`'s.
  """
  @spec split_run(map(), %{optional(String.t()) => module()}, non_neg_integer()) ::
          {:ok, State.t()} | {:error, term(), State.t()}
  def split_run(input, plugins, split_at) do
    registry = registry(input, plugins)
    {prefix, suffix} = Enum.split(input["entries"], split_at)

    {:ok, state} = LogReducer.new(input["log_id"], registry)
    {:ok, state} = LogReducer.reduce(state, prefix)
    {:ok, checkpoint} = LogReducer.checkpoint(state)
    {:ok, state} = LogReducer.restore(checkpoint, registry)
    LogReducer.reduce(state, suffix)
  end

  @doc """
  Checkpoints a state and restores it through the registry (section 42.6).

  The restored state must produce byte-identical views and checkpoint.
  """
  @spec round_trip(State.t(), map(), %{optional(String.t()) => module()}) :: State.t()
  def round_trip(state, input, plugins) do
    {:ok, checkpoint} = LogReducer.checkpoint(state)
    {:ok, restored} = LogReducer.restore(checkpoint, registry(input, plugins))
    restored
  end

  @doc """
  The observed result, shaped like `expected` and restricted to the fields
  `expected` states.
  """
  @spec actual(map(), {:ok, State.t()} | {:error, term(), State.t()}) :: map()
  def actual(%{"ok" => stated}, {:ok, state}) do
    %{"ok" => Map.take(ok_shape(state), Map.keys(stated))}
  end

  def actual(%{"error" => stated}, {:error, error, prefix}) do
    %{"error" => Map.take(error_shape(error, prefix), Map.keys(stated))}
  end

  # Deliberately unlike either stated shape, so the comparison fails and the
  # message shows what happened instead.
  def actual(%{"ok" => _}, {:error, error, _prefix}) do
    %{"unexpected_error" => inspect(error)}
  end

  def actual(%{"error" => _}, {:ok, state}) do
    %{"unexpected_ok" => ok_shape(state)}
  end

  @doc "RFC 8785 canonical bytes of a decoded JSON value (section 20)."
  @spec canonical(term()) :: binary()
  def canonical(value), do: Jcs.encode!(value)

  @doc "The `ok` shape for a successfully reduced state."
  @spec ok_shape(State.t()) :: map()
  def ok_shape(%State{} = state) do
    {:ok, views} = LogReducer.views(state)
    {:ok, checkpoint} = LogReducer.checkpoint(state)

    %{
      "head" => json(State.head(state)),
      "projections" =>
        Map.new(views, fn {name, view} ->
          {name,
           %{
             "epoch_id" => view.epoch_id,
             "epoch_head" => json(view.epoch_head),
             "reducer" => json(view.reducer)
           }}
        end),
      "views" => json(views),
      "checkpoint" => json(checkpoint)
    }
  end

  defp error_shape(%Error{} = error, %State{} = prefix) do
    _ = Emitted.record(error)

    %{
      "code" => Atom.to_string(error.code),
      "writer_seq" => error.writer_seq,
      "entry_id" => error.entry_id,
      "projection" => error.projection,
      "head" => json(State.head(prefix)),
      "reason" => reason(error.details),
      "views" => prefix_views(prefix)
    }
  end

  # `reduce/3` can also return `{:invalid_entry, details}`, a caller-contract
  # breach rather than a section 21 verdict. No vector states one; if the
  # engine produces one anyway this shape mismatches loudly rather than being
  # laundered into a code.
  defp error_shape(other, _prefix), do: %{"contract_breach" => inspect(other)}

  defp prefix_views(%State{} = prefix) do
    case LogReducer.views(prefix) do
      {:ok, views} -> json(views)
      {:error, reason} -> %{"views_failed" => inspect(reason)}
    end
  end

  defp reason(details) when is_map(details) do
    case Map.get(details, :reason) do
      atom when is_atom(atom) and not is_nil(atom) -> Atom.to_string(atom)
      {atom, _details} when is_atom(atom) -> Atom.to_string(atom)
      _other -> nil
    end
  end

  defp reason(_details), do: nil

  @doc """
  Renders an Elixir term as decoded JSON: atom keys become strings, everything
  else must already be a JSON value.

  A stray atom *value* raises rather than being stringified. A view or
  checkpoint carrying one is not JSON, and silently rendering it would let a
  non-serializable value pass the corpus.
  """
  @spec json(term()) :: term()
  def json(nil), do: nil
  def json(value) when is_boolean(value), do: value
  def json(value) when is_binary(value) or is_number(value), do: value
  def json(value) when is_list(value), do: Enum.map(value, &json/1)

  def json(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, inner} -> {json_key(key), json(inner)} end)
  end

  def json(value) do
    raise ArgumentError, "not a JSON value: #{inspect(value)}"
  end

  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)

  defp json_key(key) do
    raise ArgumentError, "not a JSON object key: #{inspect(key)}"
  end
end
