defmodule EmittedTest do
  use ExUnit.Case, async: true

  alias Commonplace.LogReducer.Error

  # Emitted underpins the Task 12 reachability gate, and was committed with
  # zero callers until tasks 3+ wire it in -- so its ETS-present branch would
  # otherwise go unexercised until the gate itself depended on it. A recorder
  # that silently records nothing makes that gate go red for a reason that has
  # nothing to do with the codes, and the tempting fix at that point is to
  # weaken the gate.
  #
  # Every test here uses its OWN table. Nothing touches :emitted_codes, so this
  # suite cannot disturb the live accumulator Task 12 depends on.

  setup do
    table = :"emitted_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
    %{table: table}
  end

  test "with no table present it is a silent no-op and returns its argument", %{table: t} do
    assert :ets.whereis(t) == :undefined, "positive control: table must start absent"

    err = Error.new(:stale_epoch, log_id: "L")
    assert Emitted.record(err, t) == err
    assert :ets.whereis(t) == :undefined, "must not create the table"
  end

  test "with a table present it actually inserts the code", %{table: t} do
    :ets.new(t, [:named_table, :public, :set])
    assert :ets.tab2list(t) == [], "positive control: table starts empty"

    err = Error.new(:writer_gap, log_id: "L", writer_seq: 3)
    assert Emitted.record(err, t) == err

    assert :ets.tab2list(t) == [{:writer_gap}],
           "the recorder must actually write -- a silent no-op here would make " <>
             "the Task 12 gate red for the wrong reason"
  end

  test "a non-error term passes through untouched", %{table: t} do
    :ets.new(t, [:named_table, :public, :set])
    assert Emitted.record(:not_an_error, t) == :not_an_error
    assert Emitted.record(%{no_code_key: 1}, t) == %{no_code_key: 1}
    assert :ets.tab2list(t) == [], "a non-error must record nothing"
  end

  test "the default table is the one Task 12 accumulates into" do
    assert Emitted.default_table() == :emitted_codes
  end
end
