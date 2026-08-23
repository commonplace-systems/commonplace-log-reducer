defmodule EmittedTest do
  # async: false -- :emitted_codes is a named table; concurrent tests would race it.
  use ExUnit.Case, async: false

  alias Commonplace.LogReducer.Error

  # Emitted underpins the Task 12 reachability gate. It is committed with zero
  # callers until tasks 3/6/7/9 wire it in, which means its ETS-present branch
  # would otherwise go unexercised until the gate itself depends on it -- and a
  # recorder that silently records nothing makes that gate go red for a reason
  # that has nothing to do with the codes. Both branches are proven here.

  setup do
    existed? = :ets.whereis(:emitted_codes) != :undefined
    on_exit(fn ->
      if not existed? and :ets.whereis(:emitted_codes) != :undefined do
        :ets.delete(:emitted_codes)
      end
    end)
    %{pre_existing: existed?}
  end

  test "with no table present it is a silent no-op and returns its argument" do
    if :ets.whereis(:emitted_codes) != :undefined, do: :ets.delete(:emitted_codes)

    err = Error.new(:stale_epoch, log_id: "L")
    assert Emitted.record(err) == err
    assert :ets.whereis(:emitted_codes) == :undefined, "must not create the table"
  end

  test "with a table present it actually inserts the code" do
    if :ets.whereis(:emitted_codes) == :undefined do
      :ets.new(:emitted_codes, [:named_table, :public, :set])
    end

    :ets.delete_all_objects(:emitted_codes)
    assert :ets.tab2list(:emitted_codes) == [], "positive control: table starts empty"

    err = Error.new(:writer_gap, log_id: "L", writer_seq: 3)
    assert Emitted.record(err) == err

    assert :ets.tab2list(:emitted_codes) == [{:writer_gap}],
           "the recorder must actually write -- a silent no-op here would make the " <>
             "Task 12 gate red for the wrong reason"
  end

  test "a non-error term passes through untouched" do
    assert Emitted.record(:not_an_error) == :not_an_error
    assert Emitted.record(%{no_code_key: 1}) == %{no_code_key: 1}
  end
end
