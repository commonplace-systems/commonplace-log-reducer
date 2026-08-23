defmodule Commonplace.LogReducer.Envelope do
  @moduledoc """
  Pure classification of a log entry body against sections 7 through 10 of the
  specification.

  This module is a function of its input alone: no engine state, no registry,
  no clock, no randomness, no I/O (§12.1, §20, §22). It never inspects log,
  writer, or sequence coordinates -- that is the engine's job -- and it never
  converts any string taken from a body into an atom (§11, §22). Body keys stay
  strings throughout.
  """

  alias Commonplace.LogReducer.Error

  @namespace "commonplace.reducer."
  @epoch_type "commonplace.reducer.epoch"
  @operation_type "commonplace.reducer.operation"

  # §9: the epoch body has exactly these fields, and no additional fields are
  # permitted. Sorted, so one comparison rejects both missing and extra keys.
  @epoch_keys Enum.sort([
                "type",
                "version",
                "projection",
                "epoch_id",
                "parent_epoch_id",
                "reducer",
                "base"
              ])

  # §10: likewise for the operation body.
  @operation_keys Enum.sort(["type", "version", "projection", "epoch_id", "operation"])

  @reducer_keys Enum.sort(["id", "version"])

  # §7, normative: ^[a-z][a-z0-9._/-]{0,127}$ over UTF-8 BYTES.
  #
  # \A and \z rather than ^ and $: PCRE's $ also matches before a trailing
  # newline, which would admit "attributes\n". The pattern is compiled without
  # the /u flag so it runs over bytes, and the byte_size guard is kept as an
  # explicit statement of the 128-byte limit.
  @projection_name_regex ~r/\A[a-z][a-z0-9._\/-]{0,127}\z/

  # §9: "a lowercase canonical UUID" -- the 8-4-4-12 hyphenated form, lowercase
  # hex only. The specification states no version or variant requirement, so
  # none is imposed here.
  @uuid_regex ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @type classification ::
          {:unrelated, map()}
          | {:epoch, map()}
          | {:operation, map()}
          | {:error, Error.t()}

  @doc """
  Reports whether a projection name satisfies section 7.

  The 128-byte limit is counted in UTF-8 bytes, not graphemes or codepoints.
  """
  @spec valid_projection_name?(term()) :: boolean()
  def valid_projection_name?(name) when is_binary(name) do
    byte_size(name) <= 128 and Regex.match?(@projection_name_regex, name)
  end

  def valid_projection_name?(_name), do: false

  @doc """
  Classifies an entry body.

  * `{:unrelated, body}` -- the body carries no `type`, or a `type` outside the
    `commonplace.reducer.` namespace. §8: unrelated application history, whose
    body the engine ignores while still advancing the head.
  * `{:epoch, body}` / `{:operation, body}` -- a well-formed envelope.
  * `{:error, %Error{}}` -- a body inside the reducer namespace that is unknown
    or malformed. §8 requires this to stop reduction; it MUST NOT be ignored.
  """
  @spec classify(term()) :: classification()
  def classify(body) when is_map(body) do
    case Map.fetch(body, "type") do
      {:ok, @epoch_type} -> classify_epoch(body)
      {:ok, @operation_type} -> classify_operation(body)
      {:ok, type} when is_binary(type) -> classify_by_namespace(body, type)
      {:ok, _non_binary_type} -> {:unrelated, body}
      :error -> {:unrelated, body}
    end
  end

  # §6: the body must be a JSON object.
  def classify(body), do: envelope_error(nil, %{reason: :body_not_an_object, body: body})

  defp classify_by_namespace(body, type) do
    if String.starts_with?(type, @namespace) do
      # §8: known prefix, unknown type. An error, never silently ignored.
      envelope_error(nil, %{reason: :unknown_reducer_body_type, type: type})
    else
      {:unrelated, body}
    end
  end

  defp classify_epoch(body) do
    with :ok <- exact_keys(body, @epoch_keys),
         :ok <- projection(body),
         :ok <- version(body),
         :ok <- uuid(body, "epoch_id", body["epoch_id"]),
         :ok <- parent_epoch_id(body),
         :ok <- reducer(body),
         :ok <- object(body, "base", body["base"]) do
      {:epoch, body}
    end
  end

  defp classify_operation(body) do
    with :ok <- exact_keys(body, @operation_keys),
         :ok <- projection(body),
         :ok <- version(body),
         :ok <- uuid(body, "epoch_id", body["epoch_id"]),
         :ok <- object(body, "operation", body["operation"]) do
      {:operation, body}
    end
  end

  # §9/§10: "exactly these fields". Missing and additional are both rejected.
  defp exact_keys(body, expected) do
    actual = body |> Map.keys() |> Enum.sort()

    if actual == expected do
      :ok
    else
      envelope_error(nil, %{
        reason: :field_set_mismatch,
        missing: expected -- actual,
        unexpected: actual -- expected
      })
    end
  end

  defp projection(body) do
    name = body["projection"]

    if valid_projection_name?(name) do
      :ok
    else
      # §21: a projection name violating §7 is invalid_projection_name, which is
      # narrower than -- and therefore reported instead of -- the generic
      # invalid_reducer_envelope.
      {:error,
       Error.new(:invalid_projection_name,
         projection: if(is_binary(name), do: name),
         details: %{projection: name}
       )}
    end
  end

  defp version(body) do
    case body["version"] do
      1 -> :ok
      other -> envelope_error(body, %{reason: :unsupported_version, version: other})
    end
  end

  defp parent_epoch_id(body) do
    # §9: null for the first epoch of a projection, otherwise a UUID. The key's
    # presence was already established by exact_keys/2.
    case body["parent_epoch_id"] do
      nil -> :ok
      value -> uuid(body, "parent_epoch_id", value)
    end
  end

  defp uuid(body, field, value) do
    if is_binary(value) and Regex.match?(@uuid_regex, value) do
      :ok
    else
      envelope_error(body, %{reason: :invalid_uuid, field: field, value: value})
    end
  end

  defp object(body, field, value) do
    if is_map(value) do
      :ok
    else
      envelope_error(body, %{reason: :not_an_object, field: field, value: value})
    end
  end

  defp reducer(body) do
    case body["reducer"] do
      value when is_map(value) ->
        with :ok <- exact_reducer_keys(body, value),
             :ok <- reducer_id(body, value["id"]) do
          reducer_version(body, value["version"])
        end

      value ->
        envelope_error(body, %{reason: :not_an_object, field: "reducer", value: value})
    end
  end

  defp exact_reducer_keys(body, reducer) do
    actual = reducer |> Map.keys() |> Enum.sort()

    if actual == @reducer_keys do
      :ok
    else
      envelope_error(body, %{
        reason: :field_set_mismatch,
        field: "reducer",
        missing: @reducer_keys -- actual,
        unexpected: actual -- @reducer_keys
      })
    end
  end

  defp reducer_id(_body, id) when is_binary(id) and id != "", do: :ok
  defp reducer_id(body, id), do: envelope_error(body, %{reason: :invalid_reducer_id, value: id})

  # §9: "A positive SAFE integer." The upper bound is not decoration -- a runtime
  # whose JSON numbers are IEEE doubles cannot distinguish 2^53 from 2^53+1, so an
  # entry above the safe range would name a DIFFERENT active reducer on the BEAM
  # than in that runtime. §20 requires all conforming implementations to agree on
  # the active reducer for a fixed log prefix, so this bound is what keeps two
  # correct implementations from diverging on permanent history.
  @max_safe_integer 9_007_199_254_740_991

  defp reducer_version(_body, version)
       when is_integer(version) and version > 0 and version <= @max_safe_integer,
       do: :ok

  defp reducer_version(body, version),
    do: envelope_error(body, %{reason: :invalid_reducer_version, value: version})

  defp envelope_error(body, details) do
    projection = if is_map(body), do: body["projection"]

    {:error,
     Error.new(:invalid_reducer_envelope,
       projection: if(is_binary(projection), do: projection),
       details: details
     )}
  end
end
