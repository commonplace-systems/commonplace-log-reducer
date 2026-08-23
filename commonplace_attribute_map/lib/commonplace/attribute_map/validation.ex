defmodule Commonplace.AttributeMap.Validation do
  @moduledoc """
  Attribute key and value validation for commonplace-attribute-map version 1
  (spec sections 24 and 25).

  Everything here is a pure predicate returning `:ok` or `{:error, reason}`.
  Nothing in this module mutates state, and no caller may apply an operation
  before validation has returned `:ok` for every part of it -- section 29
  requires a patch to succeed or fail atomically, and the only way to get that
  is to separate the judgement from the change.

  ## Reasons

  Reasons are `{atom, details}` pairs. The atom is the stable identifier from
  section 33 and is what tests pin; `details` is a map for humans and may grow
  without notice. Two reasons here are not in section 33's recommended table,
  which is introduced with "include" rather than as a closed set:

    * `:key_invalid_utf8` -- section 25 requires an attribute key to "contain
      valid Unicode", and no listed reason covers a key that is a binary but
      not valid UTF-8.
    * `:values_not_object` is reused for a non-object `patch.put`. It is the
      same condition -- a key/value object that is not an object -- and reusing
      the listed reason keeps this implementation inside section 33's
      vocabulary rather than inventing `put_not_object`.

  ## Null values versus non-finite numbers

  `nil` is a *valid* value: section 24 makes null an ordinary present value and
  deletion a separate operation. Non-finite numbers are rejected, but note that
  the BEAM cannot represent one: float arithmetic overflowing raises
  `ArithmeticError` and the external term format refuses the NaN and infinity
  bit patterns. Non-finite numbers can therefore only arrive as the atoms some
  JSON decoders emit for them, and those are rejected by the same clause that
  rejects every other atom.
  """

  @max_key_bytes 1024

  @type reason :: {atom(), map()}

  @doc "The section 25 attribute-key byte limit."
  @spec max_key_bytes() :: pos_integer()
  def max_key_bytes, do: @max_key_bytes

  @doc """
  Validates one attribute key against section 25.

  A key MUST be a non-empty string, contain valid Unicode, contain at most
  1,024 **UTF-8 bytes**, and contain no null code point. The limit is measured
  in bytes, not graphemes: 300 emoji are 300 graphemes and 1,200 bytes, and are
  rejected.
  """
  @spec validate_key(term()) :: :ok | {:error, reason()}
  def validate_key(key) when is_binary(key) do
    cond do
      key == "" ->
        {:error, {:key_empty, %{}}}

      not String.valid?(key) ->
        {:error, {:key_invalid_utf8, %{}}}

      :binary.match(key, <<0>>) != :nomatch ->
        {:error, {:key_contains_null, %{key: key}}}

      byte_size(key) > @max_key_bytes ->
        {:error, {:key_too_large, %{bytes: byte_size(key), max_bytes: @max_key_bytes}}}

      true ->
        :ok
    end
  end

  def validate_key(key), do: {:error, {:key_not_string, %{key: key}}}

  @doc """
  Validates one attribute value against section 24's I-JSON restriction.

  Permitted: null, boolean, finite number, string, array, and object with
  string keys, recursively. Object keys inside a value are ordinary I-JSON
  keys; the section 25 attribute-key limits apply only to attribute keys.
  """
  @spec validate_value(term()) :: :ok | {:error, reason()}
  def validate_value(nil), do: :ok
  def validate_value(true), do: :ok
  def validate_value(false), do: :ok
  def validate_value(value) when is_integer(value), do: :ok

  # Every float the BEAM can hold is finite; see the moduledoc.
  def validate_value(value) when is_float(value), do: :ok

  def validate_value(value) when is_binary(value) do
    if String.valid?(value), do: :ok, else: invalid_value(value)
  end

  def validate_value(value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn element, :ok ->
      case validate_value(element) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def validate_value(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, :ok, fn {key, element}, :ok ->
      # An object key inside a value is an ordinary I-JSON key: it must be a
      # valid UTF-8 string, but the section 25 attribute-key limits do not
      # reach in here.
      if is_binary(key) and String.valid?(key) do
        case validate_value(element) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      else
        {:halt, invalid_value(key)}
      end
    end)
  end

  def validate_value(value), do: invalid_value(value)

  @doc """
  Validates a whole attribute object -- an epoch base's `values`, a
  checkpoint's `values`, or a `patch.put`.

  Rejects a non-map with `:values_not_object`, then validates every key against
  `validate_key/1` and every value against `validate_value/1`.
  """
  @spec validate_values(term()) :: :ok | {:error, reason()}
  def validate_values(values) when is_map(values) and not is_struct(values) do
    Enum.reduce_while(values, :ok, fn {key, value}, :ok ->
      with :ok <- validate_key(key),
           :ok <- validate_value(value) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def validate_values(values), do: {:error, {:values_not_object, %{values: values}}}

  defp invalid_value(value), do: {:error, {:invalid_json_value, %{value: inspect(value)}}}
end
