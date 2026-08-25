defmodule EntryV2Test do
  @moduledoc """
  commonplace-log entry version 2 (jes, 2026-08-25T19:15Z) persists a durable
  `operation_id` as a top-level ENTRY field. The engine reads only its six §6
  required keys and must neither refuse nor be influenced by that field: it is
  the host's, derived by the host's own replay, never the engine's.
  """
  use ExUnit.Case, async: true

  alias Commonplace.LogReducer

  @log "0198d83c-eaf8-7c5d-b1e3-4387f1d8d9b8"
  @writer "0198d83d-54de-7c06-b574-ea1fb40d3a86"
  @epoch "0198d900-0000-7000-8000-00000000000a"

  defp entry(seq, body, extra) do
    Map.merge(
      %{
        "log_id" => @log,
        "entry_id" => "e#{seq}",
        "writer_id" => @writer,
        "writer_seq" => seq,
        "prev_entry_id" => if(seq > 1, do: "e#{seq - 1}"),
        "created_at" => "2026-08-25T00:00:00Z",
        "body" => body
      },
      extra
    )
  end

  defp bodies do
    [
      %{
        "type" => "commonplace.reducer.epoch",
        "version" => 1,
        "projection" => "counts",
        "epoch_id" => @epoch,
        "parent_epoch_id" => nil,
        "reducer" => %{"id" => "fixture.counter", "version" => 1},
        "base" => %{"start" => 1}
      },
      %{
        "type" => "commonplace.reducer.operation",
        "version" => 1,
        "projection" => "counts",
        "epoch_id" => @epoch,
        "operation" => %{"type" => "inc", "by" => 2}
      }
    ]
  end

  defp reduce_with(extras) do
    {:ok, fresh} = LogReducer.new(@log, FixturePlugin.registry())

    entries =
      bodies()
      |> Enum.with_index(1)
      |> Enum.map(fn {body, seq} -> entry(seq, body, Enum.at(extras, seq - 1)) end)

    {:ok, state} = LogReducer.reduce(fresh, entries)
    {:ok, view} = LogReducer.view(state, "counts")
    {:ok, checkpoint} = LogReducer.checkpoint(state)
    {view, checkpoint}
  end

  test "a version-2 entry carrying operation_id reduces identically to a version-1 entry" do
    v1 = reduce_with([%{}, %{}])
    id = ~s(["X",0,"#{String.duplicate("a", 64)}"])

    v2 =
      reduce_with([
        %{"version" => 2, "operation_id" => id},
        %{"version" => 2, "operation_id" => id}
      ])

    assert v1 == v2
    assert {%{value: 3}, _} = v1
  end

  test "changing operation_id alone changes nothing" do
    a =
      reduce_with([
        %{"version" => 2, "operation_id" => "X"},
        %{"version" => 2, "operation_id" => "X"}
      ])

    b =
      reduce_with([
        %{"version" => 2, "operation_id" => "Y"},
        %{"version" => 2, "operation_id" => "Y"}
      ])

    assert a == b
  end

  test "the engine does not validate operation_id: it is not the engine's field" do
    # The log validates its own entry fields on receipt (its spec §7). Here an
    # ill-typed value is simply never read -- the same stance as created_at.
    assert reduce_with([%{"operation_id" => 7}, %{"operation_id" => nil}]) ==
             reduce_with([%{}, %{}])
  end
end
