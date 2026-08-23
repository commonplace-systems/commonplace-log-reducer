defmodule Commonplace.LogReducer.Error do
  @moduledoc """
  A reducer error: the stable code from section 21 of the specification, the
  failing coordinate, the projection when known, and structured details.

  The code is the protocol identifier. Human-readable messages are not
  protocol identifiers, so no behaviour may be derived from message text.
  """

  @codes [
    :log_mismatch,
    :writer_gap,
    :writer_fork,
    :multiwriter_document_unsupported,
    :invalid_reducer_envelope,
    :invalid_projection_name,
    :unknown_reducer,
    :duplicate_epoch,
    :epoch_parent_mismatch,
    :projection_not_initialized,
    :stale_epoch,
    :invalid_epoch_base,
    :invalid_operation,
    :missing_resource,
    :invalid_checkpoint
  ]

  @enforce_keys [:code]
  defstruct [:code, :log_id, :writer_seq, :entry_id, :projection, details: %{}]

  @type code ::
          :log_mismatch
          | :writer_gap
          | :writer_fork
          | :multiwriter_document_unsupported
          | :invalid_reducer_envelope
          | :invalid_projection_name
          | :unknown_reducer
          | :duplicate_epoch
          | :epoch_parent_mismatch
          | :projection_not_initialized
          | :stale_epoch
          | :invalid_epoch_base
          | :invalid_operation
          | :missing_resource
          | :invalid_checkpoint

  @type t :: %__MODULE__{
          code: code(),
          log_id: String.t() | nil,
          writer_seq: non_neg_integer() | nil,
          entry_id: String.t() | nil,
          projection: String.t() | nil,
          details: map()
        }

  @doc "The closed set of section 21 error codes."
  @spec codes() :: [code()]
  def codes, do: @codes

  @doc """
  Builds an error for a declared code.

  Raises `ArgumentError` for any code outside `codes/0`.
  """
  @spec new(code(), keyword()) :: t()
  def new(code, fields \\ [])

  def new(code, fields) when code in @codes do
    struct!(__MODULE__, Keyword.put(fields, :code, code))
  end

  def new(code, _fields) do
    raise ArgumentError, "unknown reducer error code: #{inspect(code)}"
  end
end
