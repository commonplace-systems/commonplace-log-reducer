defmodule Commonplace.LogReducer.ChainTest do
  @moduledoc """
  Entry-chain validation and head tracking: §6's five reducer verifications,
  §16 steps 1 through 3 and step 7, and §17's single-writer requirement.

  This layer never looks inside a body beyond "is it a JSON object" and never
  touches plugins or epochs. Everything here is about coordinates.
  """

  use ExUnit.Case, async: true

  alias Commonplace.LogReducer.{Error, Projection, Registry, State}

  @log "0198d83c-eaf8-7c5d-b1e3-4387f1d8d9b8"
  @other_log "0198d840-0000-7000-8000-000000000000"
  @writer "0198d83d-54de-7c06-b574-ea1fb40d3a86"
  @other_writer "0198d841-0000-7000-8000-000000000000"

  defp registry do
    {:ok, registry} = Registry.build(FixturePlugin.registry())
    registry
  end

  defp fresh(opts \\ []) do
    {:ok, state} = State.new(@log, registry(), opts)
    state
  end

  defp entry(fields) do
    defaults = %{
      "log_id" => @log,
      "entry_id" => "entry-#{fields[:seq] || fields["writer_seq"] || 1}",
      "writer_id" => @writer,
      "writer_seq" => 1,
      "prev_entry_id" => nil,
      "created_at" => "2026-08-22T00:00:00Z",
      "body" => %{"kind" => "unrelated"}
    }

    fields
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.delete("seq")
    |> then(&Map.merge(defaults, &1))
  end

  # Walks the state forward over entries that are expected to validate.
  defp accept(state, entry) do
    assert {:ok, coords} = State.validate_entry(state, entry)
    State.advance(state, coords)
  end

  defp reject(state, entry) do
    assert {:error, %Error{} = err} = State.validate_entry(state, entry)
    Emitted.record(err)
    err
  end

  describe "State.new/3" do
    test "starts at head_seq 0, head_entry_id nil, writer_id nil" do
      state = fresh()

      assert %State{
               version: 1,
               log_id: @log,
               writer_id: nil,
               head_seq: 0,
               head_entry_id: nil,
               projections: %{}
             } = state
    end

    test "rejects a bad log id" do
      assert {:error, _} = State.new(nil, registry())
      assert {:error, _} = State.new("", registry())
    end

    test "accepts a plain registry map as well as a built registry" do
      assert {:ok, %State{}} = State.new(@log, FixturePlugin.registry())
    end
  end

  describe "a fresh engine" do
    test "requires writer_seq 1 with prev_entry_id nil" do
      # D4, derived (see State's moduledoc): §14's initial state is head_seq 0 /
      # head_entry_id nil and §19 says input resumes at head + 1 with the
      # correct predecessor, so entry one is seq 1 with a nil predecessor.
      state = accept(fresh(), entry(%{"writer_seq" => 1, "prev_entry_id" => nil}))

      assert state.head_seq == 1
    end

    test "rejects writer_seq 2 as writer_gap" do
      err = reject(fresh(), entry(%{"writer_seq" => 2, "entry_id" => "e2"}))

      assert err.code == :writer_gap
      assert err.writer_seq == 2
      assert err.entry_id == "e2"
    end

    test "rejects a non-nil prev_entry_id as writer_fork" do
      err = reject(fresh(), entry(%{"writer_seq" => 1, "prev_entry_id" => "ghost"}))

      assert err.code == :writer_fork
    end
  end

  describe "writer identity (§17)" do
    test "the writer id is pinned by the first entry" do
      state = fresh()
      assert state.writer_id == nil

      state = accept(state, entry(%{"writer_seq" => 1, "entry_id" => "e1"}))

      assert state.writer_id == @writer
    end

    test "a second writer id yields multiwriter_document_unsupported" do
      state = accept(fresh(), entry(%{"writer_seq" => 1, "entry_id" => "e1"}))

      err =
        reject(
          state,
          entry(%{
            "writer_seq" => 2,
            "entry_id" => "e2",
            "prev_entry_id" => "e1",
            "writer_id" => @other_writer
          })
        )

      assert err.code == :multiwriter_document_unsupported
      assert err.details == %{expected: @writer, actual: @other_writer}
    end

    test "the SAME writer id across many entries is accepted" do
      state =
        Enum.reduce(1..25, fresh(), fn seq, state ->
          accept(
            state,
            entry(%{
              "writer_seq" => seq,
              "entry_id" => "e#{seq}",
              "prev_entry_id" => if(seq > 1, do: "e#{seq - 1}")
            })
          )
        end)

      assert state.head_seq == 25
      assert state.head_entry_id == "e25"
      assert state.writer_id == @writer
    end
  end

  describe "log identity (§6)" do
    test "an entry naming another log yields log_mismatch" do
      err = reject(fresh(), entry(%{"log_id" => @other_log}))

      assert err.code == :log_mismatch
      assert err.details == %{expected: @log, actual: @other_log}
    end
  end

  describe "sequence and predecessor continuity (§6, §21)" do
    setup do
      state =
        Enum.reduce(1..3, fresh(), fn seq, state ->
          accept(
            state,
            entry(%{
              "writer_seq" => seq,
              "entry_id" => "e#{seq}",
              "prev_entry_id" => if(seq > 1, do: "e#{seq - 1}")
            })
          )
        end)

      %{state: state}
    end

    test "a skipped sequence yields writer_gap", %{state: state} do
      err =
        reject(state, entry(%{"writer_seq" => 5, "entry_id" => "e5", "prev_entry_id" => "e3"}))

      assert err.code == :writer_gap
    end

    test "a repeated sequence yields writer_fork", %{state: state} do
      err =
        reject(state, entry(%{"writer_seq" => 3, "entry_id" => "e3b", "prev_entry_id" => "e2"}))

      assert err.code == :writer_fork
    end

    test "a backwards sequence yields writer_fork", %{state: state} do
      err =
        reject(state, entry(%{"writer_seq" => 2, "entry_id" => "e2b", "prev_entry_id" => "e1"}))

      assert err.code == :writer_fork
    end

    test "correct sequence with a WRONG predecessor yields writer_fork", %{state: state} do
      err =
        reject(state, entry(%{"writer_seq" => 4, "entry_id" => "e4", "prev_entry_id" => "e2"}))

      assert err.code == :writer_fork
      assert err.details == %{expected: "e3", actual: "e2"}
    end

    test "correct sequence with a nil predecessor mid-log yields writer_fork", %{state: state} do
      err =
        reject(state, entry(%{"writer_seq" => 4, "entry_id" => "e4", "prev_entry_id" => nil}))

      assert err.code == :writer_fork
    end
  end

  describe "body (§6)" do
    test "a non-object body yields invalid_reducer_envelope" do
      for body <- ["a string", 7, [1, 2], nil, true] do
        err = reject(fresh(), entry(%{"body" => body}))
        assert err.code == :invalid_reducer_envelope
      end
    end

    test "an object body of any shape passes this layer" do
      assert {:ok, _} = State.validate_entry(fresh(), entry(%{"body" => %{}}))
    end
  end

  describe "structurally malformed entries" do
    test "an entry missing a required §6 field is rejected" do
      full = entry(%{})

      for key <- ["log_id", "entry_id", "writer_id", "writer_seq", "prev_entry_id", "body"] do
        assert {:error, {:invalid_entry, details}} =
                 State.validate_entry(fresh(), Map.delete(full, key)),
               "deleting #{key} was not rejected"

        assert details.field == key
      end
    end

    test "an entry with an ill-typed coordinate is rejected" do
      for {key, value} <- [
            {"log_id", 42},
            {"entry_id", 42},
            {"writer_id", 42},
            {"writer_seq", "1"},
            {"writer_seq", 0},
            {"prev_entry_id", 42}
          ] do
        assert {:error, {:invalid_entry, _}} =
                 State.validate_entry(fresh(), entry(%{key => value})),
               "#{key} => #{inspect(value)} was not rejected"
      end
    end

    test "a non-map entry is rejected rather than crashing" do
      assert {:error, {:invalid_entry, _}} = State.validate_entry(fresh(), "not an entry")
    end
  end

  describe "head tracking (§16.7, §16.8)" do
    test "an unrelated entry advances the head" do
      state = accept(fresh(), entry(%{"writer_seq" => 1, "entry_id" => "e1"}))

      assert state.head_seq == 1
      assert state.head_entry_id == "e1"
      assert state.projections == %{}
    end

    test "head does NOT advance when validation fails" do
      state = accept(fresh(), entry(%{"writer_seq" => 1, "entry_id" => "e1"}))

      for bad <- [
            entry(%{"writer_seq" => 9, "entry_id" => "e9", "prev_entry_id" => "e1"}),
            entry(%{"writer_seq" => 1, "entry_id" => "e1b"}),
            entry(%{
              "writer_seq" => 2,
              "entry_id" => "e2",
              "prev_entry_id" => "e1",
              "log_id" => @other_log
            }),
            entry(%{"writer_seq" => 2, "entry_id" => "e2", "prev_entry_id" => "e1", "body" => 5})
          ] do
        assert {:error, err} = State.validate_entry(state, bad)
        Emitted.record(err)
      end

      assert state.head_seq == 1
      assert state.head_entry_id == "e1"
      assert state.writer_id == @writer
    end
  end

  describe "seeded head (Task 9 restore)" do
    test "seeding a starting head makes the engine expect head_seq + 1" do
      state = fresh(writer_id: @writer, head: %{writer_seq: 93, entry_id: "e93"})

      assert state.head_seq == 93
      assert state.head_entry_id == "e93"
      assert state.writer_id == @writer

      err =
        reject(state, entry(%{"writer_seq" => 95, "entry_id" => "e95", "prev_entry_id" => "e93"}))

      assert err.code == :writer_gap

      err =
        reject(state, entry(%{"writer_seq" => 94, "entry_id" => "e94", "prev_entry_id" => "e92"}))

      assert err.code == :writer_fork

      state =
        accept(state, entry(%{"writer_seq" => 94, "entry_id" => "e94", "prev_entry_id" => "e93"}))

      assert state.head_seq == 94
    end

    test "a seeded head requires a pinned writer id" do
      assert {:error, _} = State.new(@log, registry(), head: %{writer_seq: 93, entry_id: "e93"})
    end

    test "a seeded head must be a well-formed coordinate" do
      assert {:error, _} =
               State.new(@log, registry(),
                 writer_id: @writer,
                 head: %{writer_seq: 0, entry_id: "e"}
               )

      assert {:error, _} =
               State.new(@log, registry(),
                 writer_id: @writer,
                 head: %{writer_seq: 1, entry_id: nil}
               )
    end

    test "seeded projections are carried into the state" do
      projection = %Projection{
        epoch_id: "0198d83a-0a1f-7ba0-aa24-21f9130f883d",
        seen_epoch_ids: MapSet.new(["0198d83a-0a1f-7ba0-aa24-21f9130f883d"]),
        reducer_id: "fixture.counter",
        reducer_version: 1,
        module: FixturePlugin.Counter,
        state: 3,
        epoch_entry_id: "e1",
        epoch_writer_seq: 1
      }

      {:ok, state} =
        State.new(@log, registry(),
          writer_id: @writer,
          head: %{writer_seq: 5, entry_id: "e5"},
          projections: %{"counter" => projection}
        )

      assert state.projections == %{"counter" => projection}
    end
  end
end
