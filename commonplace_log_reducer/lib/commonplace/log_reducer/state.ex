defmodule Commonplace.LogReducer.State do
  @moduledoc """
  Engine state (section 14) and the entry-chain layer that guards it
  (sections 6, 16 steps 1 through 3 and step 7, and 17).

  This module owns *coordinates*: which log, which writer, which sequence,
  which predecessor, and whether the body is a JSON object at all. It never
  interprets a body, resolves a reducer, installs an epoch, or calls a plugin.
  Those belong to the engine layer above it.

  ## The surface the engine calls, per entry

      {:ok, coords} = State.validate_entry(state, entry)   # sections 6, 16.1-16.3
      # ... classify and process the body ...
      state = State.advance(state, coords)                 # sections 16.7, 16.8

  `validate_entry/2` is pure and changes nothing; `advance/2` pins the writer
  ID on the first entry and moves the head to the entry's coordinate. They are
  deliberately separate because section 16.8 requires the head to advance for
  an *unrelated* entry (whose body changes no projection) while section 15.1
  requires a *failing* entry to advance nothing: the engine advances only after
  the body has been processed successfully.

  ## Multi-writer reduction is unsupported in version 1 (sections 17, 40)

  This engine reduces a **single-writer** log. The first entry pins
  `writer_id`, and any later entry carrying a different one is
  `multiwriter_document_unsupported` -- an explicit refusal at a named
  coordinate, not a merge, not a last-writer-wins tiebreak, and not a silent
  skip. The same rule holds on restore: a checkpoint naming several writer ids
  is `invalid_checkpoint`.

  This is a stated limit of version 1, not an oversight to be worked around by
  a caller. There is no ordering rule in this specification that could relate
  two writers' entries to each other -- `created_at` is not one, per section 20
  -- so accepting a second writer would mean inventing an order and calling it
  history. Concurrent writing needs a version 2 with a real merge rule.

  ## The first sequence number (plan decision D4, derived -- not spec text)

  The specification does not state the first writer sequence directly. It is
  derived: section 14 gives the initial state as `head_seq: 0` with
  `head_entry_id: nil`, and section 19 requires input after a head to begin at
  `head.writer_seq` plus one with the correct predecessor. Applying that rule
  to the initial head yields: the next expected sequence is `head_seq + 1` and
  the expected predecessor is `head_entry_id`, so a fresh engine requires
  `writer_seq: 1` with `prev_entry_id: nil`. The check itself carries this note.

  ## Malformed entries are not a section 21 classification

  Section 6 makes canonical entry validation the *caller's* responsibility and
  then lists five things the reducer MUST re-verify. Those five have section 21
  codes. A structurally malformed entry -- a missing `writer_seq`, a
  non-binary `entry_id` -- is not one of them: it is a breach of the input
  contract, before any coordinate can be compared. Section 21 defines no code
  for it and inventing one is forbidden, so such an entry is rejected as
  `{:error, {:invalid_entry, details}}` rather than being forced into a
  neighbouring code. Stretching `writer_gap` to cover "the key was absent"
  would blur exactly the distinction that section 21 draws between a *missing*
  and a *conflicting* coordinate.

  Note that presence and shape are separate from value: an ill-typed `log_id`
  is `{:invalid_entry, ...}`, while a well-formed `log_id` naming another log
  is `log_mismatch`.

  `created_at` is never read here, for any purpose (sections 6 and 20).
  """

  alias Commonplace.LogReducer.{Envelope, Error, Projection, Registry}

  @enforce_keys [:log_id, :registry]
  defstruct [
    :log_id,
    :registry,
    :writer_id,
    :head_entry_id,
    version: 1,
    head_seq: 0,
    projections: %{}
  ]

  @type head :: %{writer_seq: pos_integer(), entry_id: String.t()}

  @type coords :: %{
          log_id: String.t(),
          entry_id: String.t(),
          writer_id: String.t(),
          writer_seq: pos_integer(),
          prev_entry_id: String.t() | nil,
          body: term()
        }

  @type t :: %__MODULE__{
          version: 1,
          log_id: String.t(),
          registry: Registry.t(),
          writer_id: String.t() | nil,
          head_seq: non_neg_integer(),
          head_entry_id: String.t() | nil,
          projections: %{optional(String.t()) => Projection.t()}
        }

  @required_keys ["log_id", "entry_id", "writer_id", "writer_seq", "prev_entry_id", "body"]

  @doc """
  Builds engine state for `log_id` (section 15).

  `registry` is either a built `Commonplace.LogReducer.Registry` or the plain
  `%{{id, version} => module}` map of section 11, which is validated here. The
  registry is engine-local: it is trusted code configuration (section 22), not
  part of the section 14 semantic state, and it is never serialized.

  ## Options

  All optional; together they let a caller resume mid-log rather than only from
  the start of a log (this is what checkpoint restore needs).

    * `:writer_id` -- the pinned writer ID (section 17). Required whenever a
      head is seeded, since a head that exists was written by someone.
    * `:head` -- `%{writer_seq: pos_integer, entry_id: binary}`, the coordinate
      through which this state has already been reduced. The next accepted
      entry is then `writer_seq + 1` with `entry_id` as its predecessor.
    * `:projections` -- a `%{name => %Projection{}}` map to start from.

  Returns `{:error, {:invalid_option, details}}` for an unusable option, and
  `{:error, {:invalid_registry, _}}` for an unusable registry map.
  """
  @spec new(String.t(), Registry.t() | map(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(log_id, registry, opts \\ [])

  def new(log_id, _registry, _opts) when not is_binary(log_id) or log_id == "" do
    {:error, {:invalid_option, %{option: :log_id, value: log_id}}}
  end

  def new(log_id, %Registry{} = registry, opts) when is_binary(log_id) do
    with {:ok, writer_id} <- option_writer_id(opts),
         {:ok, head} <- option_head(opts),
         :ok <- head_needs_writer(head, writer_id),
         {:ok, projections} <- option_projections(opts) do
      {seq, entry_id} =
        case head do
          nil -> {0, nil}
          %{writer_seq: seq, entry_id: entry_id} -> {seq, entry_id}
        end

      {:ok,
       %__MODULE__{
         log_id: log_id,
         registry: registry,
         writer_id: writer_id,
         head_seq: seq,
         head_entry_id: entry_id,
         projections: projections
       }}
    end
  end

  def new(log_id, entries, opts) when is_map(entries) and not is_struct(entries) do
    case Registry.build(entries) do
      {:ok, registry} -> new(log_id, registry, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  def new(_log_id, registry, _opts) do
    {:error, {:invalid_registry, registry}}
  end

  @doc """
  Performs the reducer's own entry checks of section 6, in the order of section
  16 steps 1 through 3, plus the "body is a JSON object" check.

  Returns `{:ok, coords}` -- the validated coordinate to hand to `advance/2`
  once the body has been processed -- or:

    * `{:error, {:invalid_entry, details}}` for a structurally malformed entry
      (see this module's documentation);
    * `{:error, %Error{code: :log_mismatch}}` for another log;
    * `{:error, %Error{code: :multiwriter_document_unsupported}}` for a second
      writer ID (section 17);
    * `{:error, %Error{code: :writer_gap}}` when the next sequence is missing,
      that is, the sequence jumps past `head_seq + 1`;
    * `{:error, %Error{code: :writer_fork}}` when a coordinate conflicts with
      the head: the sequence repeats or goes backwards, or the sequence is
      right but the predecessor is not `head_entry_id`;
    * `{:error, %Error{code: :invalid_reducer_envelope}}` when the body is not
      a JSON object.

  This function changes no state and reads no clock.
  """
  @spec validate_entry(t(), term()) :: {:ok, coords()} | {:error, Error.t() | term()}
  def validate_entry(%__MODULE__{} = state, entry) do
    with {:ok, coords} <- coordinates(entry),
         :ok <- check_log(state, coords),
         :ok <- check_writer(state, coords),
         :ok <- check_chain(state, coords),
         :ok <- check_body(coords) do
      {:ok, coords}
    end
  end

  @doc """
  Advances the head to a validated entry's coordinate and pins the writer ID if
  it is not pinned yet (section 16 steps 2 and 7).

  Call this only with coordinates returned by `validate_entry/2` for this same
  state, and only after the body has been processed successfully: section 15.1
  requires a failing entry to leave the head where it was, while section 16.8
  requires an unrelated entry to advance it.
  """
  @spec advance(t(), coords()) :: t()
  def advance(%__MODULE__{} = state, %{writer_seq: seq, entry_id: entry_id, writer_id: writer_id})
      when is_integer(seq) and is_binary(entry_id) do
    %{state | writer_id: state.writer_id || writer_id, head_seq: seq, head_entry_id: entry_id}
  end

  @doc """
  The current head as the section 5.6 coordinate, or `nil` for a fresh engine
  that has reduced nothing.
  """
  @spec head(t()) :: head() | nil
  def head(%__MODULE__{head_entry_id: nil}), do: nil

  def head(%__MODULE__{head_seq: seq, head_entry_id: entry_id}),
    do: %{writer_seq: seq, entry_id: entry_id}

  # -- entry shape ----------------------------------------------------------

  defp coordinates(entry) when is_map(entry) do
    with :ok <- present(entry),
         :ok <- binary_field(entry, "log_id"),
         :ok <- binary_field(entry, "entry_id"),
         :ok <- binary_field(entry, "writer_id"),
         :ok <- seq_field(entry),
         :ok <- prev_field(entry) do
      {:ok,
       %{
         log_id: entry["log_id"],
         entry_id: entry["entry_id"],
         writer_id: entry["writer_id"],
         writer_seq: entry["writer_seq"],
         prev_entry_id: entry["prev_entry_id"],
         body: entry["body"]
       }}
    end
  end

  defp coordinates(entry), do: invalid_entry(%{reason: :not_an_object, entry: entry})

  defp present(entry) do
    case Enum.reject(@required_keys, &Map.has_key?(entry, &1)) do
      [] -> :ok
      [field | _] = missing -> invalid_entry(%{reason: :missing, field: field, missing: missing})
    end
  end

  defp binary_field(entry, field) do
    case entry[field] do
      value when is_binary(value) and value != "" ->
        :ok

      value ->
        invalid_entry(%{reason: :not_a_non_empty_string, field: field, value: value})
    end
  end

  defp seq_field(entry) do
    case entry["writer_seq"] do
      value when is_integer(value) and value > 0 ->
        :ok

      value ->
        invalid_entry(%{reason: :not_a_positive_integer, field: "writer_seq", value: value})
    end
  end

  defp prev_field(entry) do
    case entry["prev_entry_id"] do
      nil ->
        :ok

      value when is_binary(value) and value != "" ->
        :ok

      value ->
        invalid_entry(%{reason: :not_a_string_or_null, field: "prev_entry_id", value: value})
    end
  end

  defp invalid_entry(details), do: {:error, {:invalid_entry, details}}

  # -- section 16.1: log identity -------------------------------------------

  defp check_log(%{log_id: expected}, %{log_id: expected}), do: :ok

  defp check_log(%{log_id: expected}, coords) do
    error(:log_mismatch, coords, %{expected: expected, actual: coords.log_id})
  end

  # -- section 16.2 / section 17: the one permitted writer ------------------

  defp check_writer(%{writer_id: nil}, _coords), do: :ok
  defp check_writer(%{writer_id: pinned}, %{writer_id: pinned}), do: :ok

  defp check_writer(%{writer_id: pinned}, coords) do
    error(:multiwriter_document_unsupported, coords, %{expected: pinned, actual: coords.writer_id})
  end

  # -- section 16.3: contiguous sequence, continuous predecessor chain ------

  defp check_chain(state, coords) do
    # D4, derived rather than quoted: the next expected sequence is
    # head_seq + 1 and the expected predecessor is head_entry_id. Section 14's
    # initial head (0, nil) plus section 19's "input begins at head.writer_seq
    # plus one with the correct predecessor" is where this comes from, so on a
    # fresh engine it requires writer_seq 1 with a nil predecessor.
    expected_seq = state.head_seq + 1

    cond do
      coords.writer_seq > expected_seq ->
        # Section 21: the next sequence is MISSING -- the entries between the
        # head and this one have not been seen.
        error(:writer_gap, coords, %{expected: expected_seq, actual: coords.writer_seq})

      coords.writer_seq < expected_seq ->
        # Section 21: the coordinate CONFLICTS with the head -- this sequence
        # was already reduced, so a different entry claims it.
        error(:writer_fork, coords, %{expected: expected_seq, actual: coords.writer_seq})

      coords.prev_entry_id != state.head_entry_id ->
        # Right sequence, wrong parent: a conflicting predecessor, not a
        # missing one. Section 21 calls that a fork.
        error(:writer_fork, coords, %{
          expected: state.head_entry_id,
          actual: coords.prev_entry_id
        })

      true ->
        :ok
    end
  end

  # -- section 6: body is a JSON object -------------------------------------

  defp check_body(%{body: body}) when is_map(body), do: :ok

  defp check_body(coords) do
    # Classification of an object body is the engine's next step (section 16.4);
    # here only the "is it an object at all" half of section 6 applies, and
    # Envelope already renders exactly that rejection.
    {:error, err} = Envelope.classify(coords.body)
    {:error, with_coordinate(err, coords)}
  end

  defp error(code, coords, details) do
    {:error,
     Error.new(code,
       log_id: coords.log_id,
       writer_seq: coords.writer_seq,
       entry_id: coords.entry_id,
       details: details
     )}
  end

  defp with_coordinate(%Error{} = err, coords) do
    %{err | log_id: coords.log_id, writer_seq: coords.writer_seq, entry_id: coords.entry_id}
  end

  # -- options --------------------------------------------------------------

  defp option_writer_id(opts) do
    case Keyword.get(opts, :writer_id) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_option, %{option: :writer_id, value: value}}}
    end
  end

  defp option_head(opts) do
    case Keyword.get(opts, :head) do
      nil ->
        {:ok, nil}

      %{writer_seq: seq, entry_id: entry_id} = head
      when is_integer(seq) and seq > 0 and is_binary(entry_id) and entry_id != "" ->
        {:ok, head}

      value ->
        {:error, {:invalid_option, %{option: :head, value: value}}}
    end
  end

  defp head_needs_writer(nil, _writer_id), do: :ok
  defp head_needs_writer(_head, writer_id) when is_binary(writer_id), do: :ok

  defp head_needs_writer(_head, _writer_id) do
    {:error, {:invalid_option, %{option: :head, reason: :writer_id_required}}}
  end

  defp option_projections(opts) do
    case Keyword.get(opts, :projections, %{}) do
      projections when is_map(projections) ->
        if Enum.all?(projections, fn {name, projection} ->
             is_binary(name) and match?(%Projection{}, projection)
           end) do
          {:ok, projections}
        else
          {:error, {:invalid_option, %{option: :projections, value: projections}}}
        end

      value ->
        {:error, {:invalid_option, %{option: :projections, value: value}}}
    end
  end
end
