defmodule PluginCallTest do
  use ExUnit.Case, async: true

  alias Commonplace.LogReducer

  @log "0198d83c-eaf8-7c5d-b1e3-4387f1d8d9b8"
  @writer "0198d83d-54de-7c06-b574-ea1fb40d3a86"
  @epoch "0198d900-0000-7000-8000-00000000000a"

  defp state_with_count(count) do
    bodies = [
      %{
        "type" => "commonplace.reducer.epoch",
        "version" => 1,
        "projection" => "counts",
        "epoch_id" => @epoch,
        "parent_epoch_id" => nil,
        "reducer" => %{"id" => "fixture.counter", "version" => 1},
        "base" => %{"start" => count}
      }
    ]

    entries =
      bodies
      |> Enum.with_index(1)
      |> Enum.map(fn {body, seq} ->
        %{
          "log_id" => @log,
          "entry_id" => "e#{seq}",
          "writer_id" => @writer,
          "writer_seq" => seq,
          "prev_entry_id" => if(seq > 1, do: "e#{seq - 1}"),
          "created_at" => "2026-08-22T00:00:00Z",
          "body" => body
        }
      end)

    {:ok, fresh} = LogReducer.new(@log, FixturePlugin.registry())
    {:ok, state} = LogReducer.reduce(fresh, entries)
    state
  end

  describe "plugin_call/4" do
    test "applies a plugin function to the projection's state and returns its result" do
      state = state_with_count(40)
      assert {:ok, {:ok, 42}} = LogReducer.plugin_call(state, "counts", :plus, [2])
    end

    test "control: the result tracks the state, so the call is not a constant" do
      assert {:ok, {:ok, 7}} = LogReducer.plugin_call(state_with_count(5), "counts", :plus, [2])
    end

    test "an unknown projection is refused the same way view/2 refuses it" do
      assert {:error, {:unknown_projection, "nope"}} =
               LogReducer.plugin_call(state_with_count(0), "nope", :plus, [2])
    end

    test "a function the plugin does not export is refused before anything runs" do
      assert {:error, {:undefined_plugin_function, "counts", :plus, 3}} =
               LogReducer.plugin_call(state_with_count(0), "counts", :plus, [1, 2])
    end

    test "engine callbacks are not reachable: the state may not be run through apply/checkpoint out of band" do
      state = state_with_count(0)

      for {fun, arity} <- Commonplace.LogReducer.Registry.required_callbacks(),
          arity >= 1 do
        args = List.duplicate(nil, arity - 1)

        assert {:error, {:reserved_callback, "counts", ^fun, ^arity}} =
                 LogReducer.plugin_call(state, "counts", fun, args),
               "#{fun}/#{arity} was callable through plugin_call"
      end
    end

    test "the engine state is untouched: plugin_call is read-only" do
      state = state_with_count(3)
      {:ok, _} = LogReducer.plugin_call(state, "counts", :plus, [100])
      assert {:ok, %{value: 3}} = LogReducer.view(state, "counts")
    end
  end
end
