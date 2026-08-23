defmodule Commonplace.LogReducer.ErrorTest do
  use ExUnit.Case, async: true
  alias Commonplace.LogReducer.Error

  @codes ~w(
    log_mismatch writer_gap writer_fork multiwriter_document_unsupported
    invalid_reducer_envelope invalid_projection_name unknown_reducer
    duplicate_epoch epoch_parent_mismatch projection_not_initialized
    stale_epoch invalid_epoch_base invalid_operation missing_resource
    invalid_checkpoint
  )a

  test "every §21 code is declared" do
    assert Enum.sort(Error.codes()) == Enum.sort(@codes)
  end

  test "codes are a closed set" do
    assert length(Error.codes()) == 15
    refute :not_a_real_code in Error.codes()
  end

  test "an error carries the stable code and failing coordinate" do
    e = Error.new(:stale_epoch, log_id: "L", writer_seq: 47, entry_id: "E",
                  projection: "content", details: %{expected: "a", actual: "b"})

    assert %Error{code: :stale_epoch, writer_seq: 47, entry_id: "E",
                  projection: "content"} = e
    assert e.details == %{expected: "a", actual: "b"}
  end

  test "an unknown code is rejected rather than silently accepted" do
    assert_raise ArgumentError, fn -> Error.new(:made_up, log_id: "L") end
  end
end
