defmodule EngineTest.ContextSpy do
  @moduledoc """
  A fixture plugin that keeps every context it was handed.

  The section 13 context is otherwise invisible from outside a plugin: the
  engine builds it, passes it, and drops it. Asserting on its fields requires a
  plugin that records them, so this one stores the init context and every apply
  context in its own state.
  """

  @behaviour Commonplace.LogReducer.Plugin

  import Kernel, except: [apply: 3]

  @impl true
  def reducer_id, do: "fixture.context_spy"

  @impl true
  def reducer_version, do: 1

  @impl true
  def init(base, context) when is_map(base), do: {:ok, %{init: context, applied: []}}
  def init(base, _context), do: {:error, {:invalid_base, base}}

  @impl true
  def apply(operation, context, state) when is_map(operation),
    do: {:ok, %{state | applied: [context | state.applied]}}

  def apply(operation, _context, _state), do: {:error, {:invalid_operation, operation}}

  @impl true
  def view(_state), do: {:ok, nil}

  @impl true
  def checkpoint(_state), do: {:ok, %{}}

  @impl true
  def restore(checkpoint, _context) when is_map(checkpoint),
    do: {:ok, %{init: nil, applied: []}}

  def restore(checkpoint, _context), do: {:error, {:invalid_checkpoint, checkpoint}}
end

defmodule Commonplace.LogReducer.EngineTest do
  @moduledoc """
  The section 16 processing algorithm: epoch installation, operation routing,
  head advancement, and the section 15.1 failure contract.

  Steps 1 through 3 (coordinates) and step 4 (classification) are covered by
  `chain_test.exs` and `envelope_test.exs`. What is under test here is steps 5
  through 8: which projection an entry reaches, what the epoch rules of section
  9.1 and the operation rules of section 10.1 accept, and what survives a
  failure.
  """

  use ExUnit.Case, async: true

  alias Commonplace.LogReducer
  alias Commonplace.LogReducer.{Context, Error, Registry, State}

  @log "0198d83c-eaf8-7c5d-b1e3-4387f1d8d9b8"
  @writer "0198d83d-54de-7c06-b574-ea1fb40d3a86"

  @epoch_a "0198d900-0000-7000-8000-00000000000a"
  @epoch_b "0198d900-0000-7000-8000-00000000000b"
  @epoch_c "0198d900-0000-7000-8000-00000000000c"
  @epoch_z "0198d900-0000-7000-8000-00000000000f"

  # -- fixtures -------------------------------------------------------------

  defp registry_map do
    Map.put(
      FixturePlugin.registry(),
      {EngineTest.ContextSpy.reducer_id(), EngineTest.ContextSpy.reducer_version()},
      EngineTest.ContextSpy
    )
  end

  defp fresh(opts \\ []) do
    {:ok, state} = LogReducer.new(@log, registry_map(), opts)
    state
  end

  defp epoch(projection, epoch_id, parent, opts \\ []) do
    %{
      "type" => "commonplace.reducer.epoch",
      "version" => 1,
      "projection" => projection,
      "epoch_id" => epoch_id,
      "parent_epoch_id" => parent,
      "reducer" => %{
        "id" => Keyword.get(opts, :reducer_id, "fixture.counter"),
        "version" => Keyword.get(opts, :reducer_version, 1)
      },
      "base" => Keyword.get(opts, :base, %{"start" => 0})
    }
  end

  defp operation(projection, epoch_id, op \\ %{"type" => "inc", "by" => 1}) do
    %{
      "type" => "commonplace.reducer.operation",
      "version" => 1,
      "projection" => projection,
      "epoch_id" => epoch_id,
      "operation" => op
    }
  end

  defp unrelated(kind \\ "note") do
    %{"type" => "app.note", "kind" => kind}
  end

  # Numbers a list of bodies into a well-formed single-writer chain starting at
  # writer_seq 1. `from` continues a chain that an earlier call already built.
  defp entries(bodies, from \\ 1) do
    bodies
    |> Enum.with_index(from)
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
  end

  defp reduce!(bodies, opts \\ []) do
    assert {:ok, state} = LogReducer.reduce(fresh(), entries(bodies), opts)
    state
  end

  defp reduce_error(bodies, opts \\ []) do
    assert {:error, %Error{} = err, state} = LogReducer.reduce(fresh(), entries(bodies), opts)
    Emitted.record(err)
    {err, state}
  end

  defp projection(state, name), do: Map.get(state.projections, name)

  # ==========================================================================
  # Section 9.1 -- epoch rules
  # ==========================================================================

  describe "section 9.1 epoch rules" do
    test "the first epoch of a projection requires parent_epoch_id nil" do
      state = reduce!([epoch("counts", @epoch_a, nil)])

      p = projection(state, "counts")
      assert p.epoch_id == @epoch_a
      assert p.reducer_id == "fixture.counter"
      assert p.reducer_version == 1
      assert p.module == FixturePlugin.Counter
      assert p.state == 0
      assert p.epoch_entry_id == "e1"
      assert p.epoch_writer_seq == 1
      assert MapSet.to_list(p.seen_epoch_ids) == [@epoch_a]

      # Section 9.1.6: the epoch begins at the entry containing the epoch body,
      # and section 16.7 advances the head to it.
      assert State.head(state) == %{writer_seq: 1, entry_id: "e1"}
    end

    test "a first epoch naming a parent yields epoch_parent_mismatch" do
      {err, state} = reduce_error([epoch("counts", @epoch_a, @epoch_z)])

      assert err.code == :epoch_parent_mismatch
      assert err.projection == "counts"
      assert err.entry_id == "e1"
      assert err.writer_seq == 1
      assert err.details == %{expected: nil, actual: @epoch_z}

      assert state.projections == %{}
      assert State.head(state) == nil
    end

    test "a later epoch must name the ACTIVE epoch as parent" do
      state =
        reduce!([
          epoch("counts", @epoch_a, nil),
          operation("counts", @epoch_a),
          epoch("counts", @epoch_b, @epoch_a, base: %{"start" => 100})
        ])

      p = projection(state, "counts")
      assert p.epoch_id == @epoch_b
      # Section 9.1: the new reducer is initialized from `base` alone; it is
      # never handed the previous instance's opaque state.
      assert p.state == 100
      assert p.epoch_entry_id == "e3"
      assert p.epoch_writer_seq == 3
      assert State.head(state) == %{writer_seq: 3, entry_id: "e3"}
    end

    test "a later epoch naming a stale ancestor yields epoch_parent_mismatch" do
      {err, state} =
        reduce_error([
          epoch("counts", @epoch_a, nil),
          epoch("counts", @epoch_b, @epoch_a),
          # @epoch_a is an ancestor, but @epoch_b is the ACTIVE epoch.
          epoch("counts", @epoch_c, @epoch_a)
        ])

      assert err.code == :epoch_parent_mismatch
      assert err.details == %{expected: @epoch_b, actual: @epoch_a}
      assert err.writer_seq == 3

      assert projection(state, "counts").epoch_id == @epoch_b
      assert State.head(state) == %{writer_seq: 2, entry_id: "e2"}
    end

    test "a reused epoch id yields duplicate_epoch" do
      {err, state} =
        reduce_error([
          epoch("counts", @epoch_a, nil),
          epoch("counts", @epoch_a, @epoch_a)
        ])

      assert err.code == :duplicate_epoch
      assert err.projection == "counts"
      assert err.details == %{epoch_id: @epoch_a}

      assert projection(state, "counts").epoch_entry_id == "e1"
      assert State.head(state) == %{writer_seq: 1, entry_id: "e1"}
    end

    # ------------------------------------------------------------------
    # D5. Section 9.1.3 forbids reusing an epoch ID *for that projection*, and
    # section 19 stores `seen_epoch_ids` inside the projection -- the same
    # structure epoch replacement rebuilds. A rebuild that starts a fresh set
    # still passes every other test in this file and silently re-admits a
    # retired epoch ID, which is permanent-history corruption.
    # ------------------------------------------------------------------
    test "seen_epoch_ids survives epoch replacement" do
      state =
        reduce!([
          epoch("counts", @epoch_a, nil),
          epoch("counts", @epoch_b, @epoch_a),
          epoch("counts", @epoch_c, @epoch_b)
        ])

      p = projection(state, "counts")
      assert p.epoch_id == @epoch_c

      assert MapSet.equal?(p.seen_epoch_ids, MapSet.new([@epoch_a, @epoch_b, @epoch_c])),
             "epoch replacement dropped retired epoch IDs: #{inspect(MapSet.to_list(p.seen_epoch_ids))}"

      # And the set is load-bearing, not decorative: a retired ID cannot return.
      assert {:error, %Error{} = err, after_state} =
               LogReducer.reduce(state, entries([epoch("counts", @epoch_a, @epoch_c)], 4))

      Emitted.record(err)
      assert err.code == :duplicate_epoch
      assert err.details == %{epoch_id: @epoch_a}
      assert projection(after_state, "counts").epoch_id == @epoch_c
    end

    test "an unknown reducer suspends at the epoch entry" do
      {err, state} =
        reduce_error([
          epoch("counts", @epoch_a, nil, reducer_id: "fixture.counter", reducer_version: 99)
        ])

      assert err.code == :unknown_reducer
      assert err.projection == "counts"
      assert err.entry_id == "e1"
      assert err.details == %{reducer_id: "fixture.counter", reducer_version: 99}

      assert state.projections == %{}
      assert State.head(state) == nil
    end

    test "a plugin rejecting the base yields invalid_epoch_base and installs nothing" do
      {err, state} =
        reduce_error([
          epoch("counts", @epoch_a, nil, reducer_id: "fixture.base_rejector")
        ])

      assert err.code == :invalid_epoch_base
      assert err.projection == "counts"
      # Section 21: the plugin's reason is opaque and carried verbatim.
      assert err.details == %{reason: :base_always_refused}

      assert state.projections == %{}
      assert State.head(state) == nil
    end

    test "replacing one projection's epoch leaves another projection untouched" do
      before =
        reduce!([
          epoch("counts", @epoch_a, nil),
          epoch("other", @epoch_z, nil, base: %{"start" => 7}),
          operation("counts", @epoch_a),
          operation("other", @epoch_z)
        ])

      untouched = projection(before, "other")

      assert {:ok, state} =
               LogReducer.reduce(
                 before,
                 entries([epoch("counts", @epoch_b, @epoch_a, base: %{"start" => 50})], 5)
               )

      assert projection(state, "counts").epoch_id == @epoch_b
      assert projection(state, "counts").state == 50
      # Section 9.1.7, field by field rather than by identity.
      assert projection(state, "other") == untouched
      assert untouched.epoch_id == @epoch_z
      assert untouched.state == 8
    end
  end

  # ==========================================================================
  # Section 10.1 -- operation rules
  # ==========================================================================

  describe "section 10.1 operation rules" do
    test "an operation before any epoch yields projection_not_initialized" do
      {err, state} = reduce_error([operation("counts", @epoch_a)])

      assert err.code == :projection_not_initialized
      assert err.projection == "counts"
      assert err.entry_id == "e1"
      assert err.details == %{epoch_id: @epoch_a}

      assert state.projections == %{}
      assert State.head(state) == nil
    end

    test "an operation naming a stale epoch yields stale_epoch" do
      {err, state} =
        reduce_error([
          epoch("counts", @epoch_a, nil),
          epoch("counts", @epoch_b, @epoch_a),
          operation("counts", @epoch_a)
        ])

      assert err.code == :stale_epoch
      assert err.projection == "counts"
      assert err.writer_seq == 3
      assert err.details == %{expected: @epoch_b, actual: @epoch_a}

      assert projection(state, "counts").state == 0
      assert State.head(state) == %{writer_seq: 2, entry_id: "e2"}
    end

    test "an operation routes only to its own projection" do
      state =
        reduce!([
          epoch("counts", @epoch_a, nil),
          epoch("other", @epoch_z, nil, base: %{"start" => 5}),
          operation("counts", @epoch_a, %{"type" => "inc", "by" => 3})
        ])

      assert projection(state, "counts").state == 3
      assert projection(state, "other").state == 5
    end

    test "a plugin refusing an operation yields invalid_operation and stops at that entry" do
      {err, state} =
        reduce_error([
          epoch("counts", @epoch_a, nil, reducer_id: "fixture.rejector", base: %{}),
          operation("counts", @epoch_a, %{"anything" => true}),
          operation("counts", @epoch_a, %{"anything" => true})
        ])

      assert err.code == :invalid_operation
      assert err.projection == "counts"
      assert err.entry_id == "e2"
      assert err.writer_seq == 2
      assert err.details == %{reason: :always_refuses}

      # Section 10.1.6: stopped at the failing entry, not at the one after it.
      assert State.head(state) == %{writer_seq: 1, entry_id: "e1"}
    end

    test "the failing entry advances no head and changes no projection" do
      good =
        reduce!([
          epoch("counts", @epoch_a, nil),
          operation("counts", @epoch_a, %{"type" => "inc", "by" => 4})
        ])

      assert {:error, %Error{} = err, state} =
               LogReducer.reduce(
                 good,
                 entries([operation("counts", @epoch_a, %{"type" => "nope"})], 3)
               )

      Emitted.record(err)
      assert err.code == :invalid_operation
      assert state == good
      assert State.head(state) == %{writer_seq: 2, entry_id: "e2"}
      assert projection(state, "counts").state == 4
    end

    test "two projections evolve independently at one shared head" do
      state =
        reduce!([
          epoch("counts", @epoch_a, nil),
          epoch("other", @epoch_z, nil, base: %{"start" => 100}),
          operation("counts", @epoch_a, %{"type" => "inc", "by" => 1}),
          operation("other", @epoch_z, %{"type" => "inc", "by" => 10}),
          operation("counts", @epoch_a, %{"type" => "inc", "by" => 1})
        ])

      assert projection(state, "counts").state == 2
      assert projection(state, "other").state == 110
      # Section 18: one shared head through which all projections are processed.
      assert State.head(state) == %{writer_seq: 5, entry_id: "e5"}
    end

    test "a missing resource yields missing_resource" do
      {err, state} =
        reduce_error([
          epoch("counts", @epoch_a, nil, reducer_id: "fixture.needs_resource", base: %{})
        ])

      assert err.code == :missing_resource
      assert err.projection == "counts"
      assert err.details == %{resource: "r"}

      assert state.projections == %{}
    end

    test "a missing resource on an operation also yields missing_resource" do
      state =
        reduce!(
          [epoch("counts", @epoch_a, nil, reducer_id: "fixture.needs_resource", base: %{})],
          resources: %{"r" => "bytes"}
        )

      # The resource is supplied at epoch time but withheld on the next call.
      assert {:error, %Error{} = err, ^state} =
               LogReducer.reduce(state, entries([operation("counts", @epoch_a, %{})], 2))

      Emitted.record(err)
      assert err.code == :missing_resource
      assert err.details == %{resource: "r"}
    end

    test "resources supplied via opts reach the plugin context" do
      state =
        reduce!(
          [
            epoch("counts", @epoch_a, nil, reducer_id: "fixture.needs_resource", base: %{}),
            operation("counts", @epoch_a, %{}),
            operation("counts", @epoch_a, %{})
          ],
          resources: %{"r" => "bytes"}
        )

      assert projection(state, "counts").state == 2
      assert State.head(state) == %{writer_seq: 3, entry_id: "e3"}
    end
  end

  # ==========================================================================
  # Section 13 -- the reducer context
  # ==========================================================================

  describe "section 13 context" do
    test "the context carries every section 13 field" do
      state =
        reduce!(
          [
            epoch("counts", @epoch_a, nil, reducer_id: "fixture.context_spy", base: %{}),
            operation("counts", @epoch_a, %{"n" => 1})
          ],
          resources: %{"r" => "bytes"}
        )

      %{init: init_ctx, applied: [op_ctx]} = projection(state, "counts").state

      assert %Context{} = init_ctx

      assert init_ctx == %Context{
               log_id: @log,
               writer_id: @writer,
               writer_seq: 1,
               entry_id: "e1",
               projection: "counts",
               epoch_id: @epoch_a,
               reducer_id: "fixture.context_spy",
               reducer_version: 1,
               resources: %{"r" => "bytes"}
             }

      assert op_ctx == %Context{init_ctx | writer_seq: 2, entry_id: "e2"}
    end

    test "resources default to the empty map" do
      state =
        reduce!([epoch("counts", @epoch_a, nil, reducer_id: "fixture.context_spy", base: %{})])

      assert projection(state, "counts").state.init.resources == %{}
    end
  end

  # ==========================================================================
  # Section 16 -- atomicity, batching, and the head
  # ==========================================================================

  describe "section 16 atomicity and batching" do
    test "a plugin failure cannot partially install an epoch" do
      good =
        reduce!([
          epoch("counts", @epoch_a, nil),
          operation("counts", @epoch_a, %{"type" => "inc", "by" => 9})
        ])

      assert {:error, %Error{} = err, state} =
               LogReducer.reduce(
                 good,
                 entries(
                   [epoch("counts", @epoch_b, @epoch_a, reducer_id: "fixture.base_rejector")],
                   3
                 )
               )

      Emitted.record(err)
      assert err.code == :invalid_epoch_base

      # Nothing of the candidate epoch is visible: not the ID, not the module,
      # not the seen-set, not the state.
      assert state == good
      p = projection(state, "counts")
      assert p.epoch_id == @epoch_a
      assert p.module == FixturePlugin.Counter
      assert p.state == 9
      refute MapSet.member?(p.seen_epoch_ids, @epoch_b)
    end

    test "reduce returns the last good prefix state alongside the error" do
      prefix =
        reduce!([
          epoch("counts", @epoch_a, nil),
          operation("counts", @epoch_a, %{"type" => "inc", "by" => 1}),
          operation("counts", @epoch_a, %{"type" => "inc", "by" => 1})
        ])

      {err, state} =
        reduce_error([
          epoch("counts", @epoch_a, nil),
          operation("counts", @epoch_a, %{"type" => "inc", "by" => 1}),
          operation("counts", @epoch_a, %{"type" => "inc", "by" => 1}),
          operation("counts", @epoch_a, %{"type" => "boom"}),
          operation("counts", @epoch_a, %{"type" => "inc", "by" => 1})
        ])

      assert err.writer_seq == 4
      assert state == prefix
      assert State.head(state) == %{writer_seq: 3, entry_id: "e3"}
      assert projection(state, "counts").state == 2
    end

    test "splitting the same entries into two reduce calls gives the same state" do
      bodies = [
        epoch("counts", @epoch_a, nil),
        operation("counts", @epoch_a, %{"type" => "inc", "by" => 2}),
        epoch("other", @epoch_z, nil, base: %{"start" => 1}),
        unrelated(),
        epoch("counts", @epoch_b, @epoch_a, base: %{"start" => 40}),
        operation("counts", @epoch_b, %{"type" => "inc", "by" => 2})
      ]

      all = entries(bodies)
      {front, back} = Enum.split(all, 3)

      assert {:ok, one_shot} = LogReducer.reduce(fresh(), all)
      assert {:ok, partial} = LogReducer.reduce(fresh(), front)
      assert {:ok, split} = LogReducer.reduce(partial, back)

      assert split == one_shot
      assert projection(split, "counts").state == 42
      assert projection(split, "other").state == 1
    end

    test "an unrelated entry advances the head without changing projections" do
      before = reduce!([epoch("counts", @epoch_a, nil)])

      assert {:ok, state} = LogReducer.reduce(before, entries([unrelated(), unrelated()], 2))

      assert state.projections == before.projections
      assert State.head(state) == %{writer_seq: 3, entry_id: "e3"}
    end

    test "a contract-breach entry surfaces as invalid_entry, not a section 21 code" do
      bad = entries([unrelated()]) |> hd() |> Map.delete("writer_id")

      assert {:error, {:invalid_entry, details}, state} = LogReducer.reduce(fresh(), [bad])
      assert is_map(details)
      assert State.head(state) == nil
    end

    test "a malformed reducer body fails rather than being ignored" do
      {err, state} =
        reduce_error([%{"type" => "commonplace.reducer.epoch", "version" => 1}])

      assert err.code == :invalid_reducer_envelope
      assert State.head(state) == nil
    end
  end

  describe "LogReducer.new/3" do
    test "builds a fresh state from the plain registry map of section 11" do
      assert {:ok, state} = LogReducer.new(@log, registry_map())
      assert %State{} = state
      assert state.log_id == @log
      assert state.projections == %{}
      assert State.head(state) == nil
    end

    test "accepts an already built registry" do
      {:ok, registry} = Registry.build(registry_map())
      assert {:ok, state} = LogReducer.new(@log, registry)
      assert state.registry == registry
    end

    test "rejects an unusable registry" do
      assert {:error, _} = LogReducer.new(@log, :not_a_registry)
    end
  end
end
