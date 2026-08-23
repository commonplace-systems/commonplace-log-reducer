defmodule CheckpointTest.Naughty do
  @moduledoc """
  One fixture whose *base* selects which callback misbehaves.

  The engine's checkpoint paths need plugins that fail in specific callbacks
  (`view/1`, `checkpoint/1`, `restore/2`) while still initializing and reducing
  normally -- otherwise the failure can never be reached through a real log.
  Driving all of that from the base keeps it to one module instead of four
  near-identical ones.

  State is the base map itself, so `checkpoint/1` and `restore/2` round-trip it
  and the selected behaviour survives a restore.
  """

  @behaviour Commonplace.LogReducer.Plugin

  import Kernel, except: [apply: 3]

  @impl true
  def reducer_id, do: "fixture.naughty"

  @impl true
  def reducer_version, do: 1

  @impl true
  def init(base, _context) when is_map(base), do: {:ok, base}
  def init(base, _context), do: {:error, {:invalid_base, base}}

  @impl true
  def apply(operation, _context, state) when is_map(operation),
    do: {:ok, Map.merge(state, operation)}

  def apply(operation, _context, _state), do: {:error, {:invalid_operation, operation}}

  @impl true
  def view(%{"view" => "refuse"}), do: {:error, :refuses_view}
  def view(state), do: {:ok, state}

  @impl true
  def checkpoint(%{"checkpoint" => "refuse"}), do: {:error, :refuses_checkpoint}
  def checkpoint(%{"checkpoint" => "not_object"}), do: {:ok, "not an object"}
  def checkpoint(state), do: {:ok, state}

  @impl true
  def restore(%{"restore" => "refuse"}, _context), do: {:error, :refuses_restore}
  def restore(%{"restore" => "missing"}, _context), do: {:error, {:missing_resource, "r"}}

  def restore(%{"restore" => "capture"} = checkpoint, context),
    do: {:ok, Map.put(checkpoint, "context", context)}

  def restore(checkpoint, _context) when is_map(checkpoint), do: {:ok, checkpoint}
  def restore(checkpoint, _context), do: {:error, {:invalid_checkpoint, checkpoint}}
end

defmodule Commonplace.LogReducer.CheckpointTest do
  @moduledoc """
  Views (section 18), the version 1 checkpoint format (section 19), and the
  determinism obligations of section 20 that bear on them.
  """

  use ExUnit.Case, async: true

  alias Commonplace.LogReducer
  alias Commonplace.LogReducer.{Context, Error, State}

  @log "0198d83c-eaf8-7c5d-b1e3-4387f1d8d9b8"
  @writer "0198d83d-54de-7c06-b574-ea1fb40d3a86"
  @other_writer "0198d83d-54de-7c06-b574-ea1fb40d3a99"

  @epoch_a "0198d900-0000-7000-8000-00000000000a"
  @epoch_b "0198d900-0000-7000-8000-00000000000b"
  @epoch_c "0198d900-0000-7000-8000-00000000000c"

  # -- fixtures -------------------------------------------------------------

  defp registry_map do
    Map.put(
      FixturePlugin.registry(),
      {CheckpointTest.Naughty.reducer_id(), CheckpointTest.Naughty.reducer_version()},
      CheckpointTest.Naughty
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

  defp unrelated, do: %{"type" => "app.note", "kind" => "note"}

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

  defp reduce!(state, bodies, from) do
    assert {:ok, state} = LogReducer.reduce(state, entries(bodies, from))
    state
  end

  defp reduce!(bodies), do: reduce!(fresh(), bodies, 1)

  defp record({:error, %Error{} = err} = result) do
    Emitted.record(err)
    result
  end

  defp record(other), do: other

  # Two projections whose entries interleave, so the last entry touches only
  # one of them. This is the state the section 18 shared-head rule is about.
  defp two_projections do
    reduce!([
      epoch("counts", @epoch_a, nil),
      epoch("notes", @epoch_b, nil, reducer_id: "fixture.passthrough", base: %{}),
      operation("counts", @epoch_a),
      operation("notes", @epoch_b, %{"note" => "hello"}),
      unrelated(),
      operation("counts", @epoch_a, %{"type" => "inc", "by" => 41})
    ])
  end

  # ==========================================================================
  # Section 18 -- views
  # ==========================================================================

  describe "section 18 view/2" do
    test "names the projection epoch, the shared head, and the plugin value" do
      state = reduce!([epoch("counts", @epoch_a, nil), operation("counts", @epoch_a)])

      assert {:ok, view} = LogReducer.view(state, "counts")
      assert view.epoch_id == @epoch_a
      assert view.head == %{writer_seq: 2, entry_id: "e2"}
      assert view.value == 1
    end

    # THE TRAP. A per-projection head is the natural implementation and it is
    # wrong: section 18 says all projections in one engine state are coherent at
    # the SAME log head, "even when an entry affected only one projection".
    # Here entry 6 touched only "counts", and "notes" must still report e6.
    test "all projections report the same head even when an entry touched one" do
      state = two_projections()
      shared = State.head(state)

      assert shared == %{writer_seq: 6, entry_id: "e6"}
      assert {:ok, counts} = LogReducer.view(state, "counts")
      assert {:ok, notes} = LogReducer.view(state, "notes")

      assert counts.head == shared
      assert notes.head == shared
      assert counts.value == 42
      assert notes.value == [%{"note" => "hello"}]
    end

    test "an unrelated entry advances the head every view reports" do
      state = reduce!([epoch("counts", @epoch_a, nil)])
      assert {:ok, before} = LogReducer.view(state, "counts")

      state = reduce!(state, [unrelated()], 2)
      assert {:ok, later} = LogReducer.view(state, "counts")

      assert before.head == %{writer_seq: 1, entry_id: "e1"}
      assert later.head == %{writer_seq: 2, entry_id: "e2"}
      assert later.value == before.value
    end

    test "the optional additions do not change the plugin's value" do
      state = reduce!([epoch("counts", @epoch_a, nil), operation("counts", @epoch_a)])
      assert {:ok, view} = LogReducer.view(state, "counts")

      # Section 18 MAY: epoch-start coordinate and reducer identity.
      assert view.epoch_head == %{writer_seq: 1, entry_id: "e1"}
      assert view.reducer == %{id: "fixture.counter", version: 1}
      assert view.value == 1
    end

    test "an unknown projection errors and is not a section 21 code" do
      state = reduce!([epoch("counts", @epoch_a, nil)])

      # Not a %Error{}, and so not a section 21 code: an unknown projection is
      # a question about this state, not a verdict about durable history.
      assert LogReducer.view(state, "nope") == {:error, {:unknown_projection, "nope"}}
    end

    test "a plugin view error surfaces as {:error, term} and is not a section 21 code" do
      state =
        reduce!([
          epoch("noisy", @epoch_a, nil,
            reducer_id: "fixture.naughty",
            base: %{"view" => "refuse"}
          )
        ])

      # Again not a %Error{}: producing a view neither reduces an entry nor
      # moves the head, so the plugin's reason surfaces verbatim.
      assert LogReducer.view(state, "noisy") == {:error, {:view_failed, "noisy", :refuses_view}}
    end
  end

  describe "section 18 views/1" do
    test "returns every initialized projection at the one shared head" do
      state = two_projections()

      assert {:ok, views} = LogReducer.views(state)
      assert Map.keys(views) |> Enum.sort() == ["counts", "notes"]
      assert views["counts"].value == 42
      assert views["notes"].value == [%{"note" => "hello"}]
      assert views["counts"].head == views["notes"].head
    end

    test "a fresh engine has no projections" do
      assert {:ok, views} = LogReducer.views(fresh())
      assert views == %{}
    end

    test "one failing plugin fails the whole call" do
      state =
        reduce!([
          epoch("counts", @epoch_a, nil),
          epoch("noisy", @epoch_b, nil,
            reducer_id: "fixture.naughty",
            base: %{"view" => "refuse"}
          )
        ])

      assert {:error, {:view_failed, "noisy", :refuses_view}} = LogReducer.views(state)
    end
  end

  # ==========================================================================
  # Section 19 -- checkpoint format
  # ==========================================================================

  describe "section 19 checkpoint/1" do
    test "matches the section 19 shape" do
      state = reduce!([epoch("counts", @epoch_a, nil), operation("counts", @epoch_a)])

      assert {:ok, checkpoint} = LogReducer.checkpoint(state)

      assert %{
               "version" => 1,
               "log_id" => @log,
               "writer_id" => @writer,
               "head" => %{"writer_seq" => 2, "entry_id" => "e2"},
               "projections" => %{
                 "counts" => %{
                   "epoch_id" => @epoch_a,
                   "seen_epoch_ids" => [@epoch_a],
                   "epoch_head" => %{"writer_seq" => 1, "entry_id" => "e1"},
                   "reducer" => %{"id" => "fixture.counter", "version" => 1},
                   "state" => %{"count" => 1}
                 }
               }
             } = checkpoint

      assert Map.keys(checkpoint) |> Enum.sort() ==
               ["head", "log_id", "projections", "version", "writer_id"]

      assert checkpoint["projections"]["counts"] |> Map.keys() |> Enum.sort() ==
               ["epoch_head", "epoch_id", "reducer", "seen_epoch_ids", "state"]
    end

    # THE TRAP. Section 19: "sort seen_epoch_ids lexically when encoding." A
    # MapSet enumerates in term order, which for these UUID binaries happens to
    # look sorted often enough to hide a missing sort; the epochs below are
    # installed in an order whose insertion order is NOT the sorted order.
    test "seen_epoch_ids is sorted lexically when encoded" do
      state =
        reduce!([
          epoch("counts", @epoch_c, nil),
          epoch("counts", @epoch_b, @epoch_c),
          epoch("counts", @epoch_a, @epoch_b)
        ])

      assert {:ok, checkpoint} = LogReducer.checkpoint(state)
      seen = checkpoint["projections"]["counts"]["seen_epoch_ids"]

      assert seen == [@epoch_a, @epoch_b, @epoch_c]
      assert seen == Enum.sort(seen)
    end

    test "a state that has reduced nothing has no head to checkpoint" do
      assert {:error, %Error{code: :invalid_checkpoint} = err} =
               record(LogReducer.checkpoint(fresh()))

      assert err.details.reason == :no_head
    end

    test "a plugin refusing its own checkpoint yields invalid_checkpoint" do
      state =
        reduce!([
          epoch("noisy", @epoch_a, nil,
            reducer_id: "fixture.naughty",
            base: %{"checkpoint" => "refuse"}
          )
        ])

      assert {:error, %Error{code: :invalid_checkpoint} = err} =
               record(LogReducer.checkpoint(state))

      assert err.projection == "noisy"
      assert err.details.reason == :refuses_checkpoint
      assert err.writer_seq == 1
      assert err.entry_id == "e1"
    end

    test "a plugin checkpoint that is not a JSON object yields invalid_checkpoint" do
      state =
        reduce!([
          epoch("noisy", @epoch_a, nil,
            reducer_id: "fixture.naughty",
            base: %{"checkpoint" => "not_object"}
          )
        ])

      assert {:error, %Error{code: :invalid_checkpoint} = err} =
               record(LogReducer.checkpoint(state))

      assert err.details.reason == :plugin_checkpoint_not_an_object
    end

    test "a plugin missing a resource overrides to missing_resource" do
      {:ok, checkpoint} =
        reduce!([
          epoch("noisy", @epoch_a, nil,
            reducer_id: "fixture.naughty",
            base: %{"restore" => "missing"}
          )
        ])
        |> LogReducer.checkpoint()

      assert {:error, %Error{code: :missing_resource} = err} =
               record(LogReducer.restore(checkpoint, registry_map()))

      assert err.details.resource == "r"
    end
  end

  # ==========================================================================
  # Section 19 -- restore
  # ==========================================================================

  describe "section 19 restore/3" do
    test "rebuilds a state whose views equal the original's" do
      original = two_projections()
      {:ok, checkpoint} = LogReducer.checkpoint(original)

      assert {:ok, restored} = LogReducer.restore(checkpoint, registry_map())
      assert {:ok, original_views} = LogReducer.views(original)
      assert {:ok, restored_views} = LogReducer.views(restored)

      assert restored_views == original_views
      assert State.head(restored) == State.head(original)
      assert restored.log_id == original.log_id
      assert restored.writer_id == original.writer_id
    end

    test "resolves the exact reducer id and version from the registry" do
      state = reduce!([epoch("counts", @epoch_a, nil)])
      {:ok, checkpoint} = LogReducer.checkpoint(state)

      assert {:ok, restored} = LogReducer.restore(checkpoint, registry_map())
      assert restored.projections["counts"].module == FixturePlugin.Counter
      assert restored.projections["counts"].reducer_id == "fixture.counter"
      assert restored.projections["counts"].reducer_version == 1

      # Section 19: the EXACT pair. A registered id at an unregistered version
      # must not fall back to a neighbouring version.
      bumped = put_in(checkpoint["projections"]["counts"]["reducer"]["version"], 2)

      assert {:error, %Error{code: :unknown_reducer} = err} =
               record(LogReducer.restore(bumped, registry_map()))

      assert err.details == %{reducer_id: "fixture.counter", reducer_version: 2}
    end

    test "seen_epoch_ids survives the round trip" do
      state =
        reduce!([
          epoch("counts", @epoch_c, nil),
          epoch("counts", @epoch_b, @epoch_c),
          epoch("counts", @epoch_a, @epoch_b)
        ])

      {:ok, checkpoint} = LogReducer.checkpoint(state)
      assert {:ok, restored} = LogReducer.restore(checkpoint, registry_map())

      assert restored.projections["counts"].seen_epoch_ids ==
               state.projections["counts"].seen_epoch_ids
    end

    test "calls each plugin's restore/2 callback with a section 13 context" do
      state = reduce!([epoch("noisy", @epoch_a, nil, reducer_id: "fixture.naughty", base: %{})])
      {:ok, checkpoint} = LogReducer.checkpoint(state)

      # Naughty's restore/2 returns the checkpoint map verbatim, so a state that
      # equals the plugin checkpoint proves restore/2 ran rather than the engine
      # copying a stored term.
      assert {:ok, restored} = LogReducer.restore(checkpoint, registry_map())
      assert restored.projections["noisy"].state == %{}

      # And a plugin that refuses proves the engine is not ignoring the return.
      refusing = put_in(checkpoint["projections"]["noisy"]["state"], %{"restore" => "refuse"})

      assert {:error, %Error{code: :invalid_checkpoint}} =
               LogReducer.restore(refusing, registry_map())
    end

    test "the restore context carries the checkpoint coordinate" do
      state =
        reduce!([
          epoch("spy", @epoch_a, nil,
            reducer_id: "fixture.naughty",
            base: %{"restore" => "capture"}
          )
        ])

      {:ok, checkpoint} = LogReducer.checkpoint(state)
      assert {:ok, restored} = LogReducer.restore(checkpoint, registry_map())

      assert %Context{} = context = restored.projections["spy"].state["context"]
      assert context.log_id == @log
      assert context.writer_id == @writer
      # The checkpoint HEAD, not the epoch coordinate: restore rebuilds the
      # state as of the head the checkpoint names.
      assert context.writer_seq == 1
      assert context.entry_id == "e1"
      assert context.projection == "spy"
      assert context.epoch_id == @epoch_a
      assert context.reducer_id == "fixture.naughty"
      assert context.reducer_version == 1
      assert context.resources == %{}
    end

    test "restore passes :resources through to the plugin" do
      state =
        reduce!([
          epoch("spy", @epoch_a, nil,
            reducer_id: "fixture.naughty",
            base: %{"restore" => "capture"}
          )
        ])

      {:ok, checkpoint} = LogReducer.checkpoint(state)

      assert {:ok, restored} =
               LogReducer.restore(checkpoint, registry_map(), resources: %{"r" => 1})

      assert restored.projections["spy"].state["context"].resources == %{"r" => 1}
    end

    test "a checkpoint naming an unknown reducer yields unknown_reducer" do
      state = reduce!([epoch("counts", @epoch_a, nil)])
      {:ok, checkpoint} = LogReducer.checkpoint(state)
      renamed = put_in(checkpoint["projections"]["counts"]["reducer"]["id"], "fixture.nobody")

      assert {:error, %Error{code: :unknown_reducer}} =
               record(LogReducer.restore(renamed, registry_map()))
    end

    test "a malformed projection name yields invalid_checkpoint" do
      state = reduce!([epoch("counts", @epoch_a, nil)])
      {:ok, checkpoint} = LogReducer.checkpoint(state)

      for bad <- ["Counts", "9counts", "", "counts!", String.duplicate("a", 129)] do
        projections = %{bad => checkpoint["projections"]["counts"]}
        broken = %{checkpoint | "projections" => projections}

        assert {:error, %Error{code: :invalid_checkpoint} = err} =
                 record(LogReducer.restore(broken, registry_map()))

        assert err.details.reason == :invalid_projection_name
        assert err.details.projection == bad
      end
    end

    test "a duplicate projection name yields invalid_checkpoint" do
      state = reduce!([epoch("counts", @epoch_a, nil)])
      {:ok, checkpoint} = LogReducer.checkpoint(state)
      spec = checkpoint["projections"]["counts"]

      # An Elixir map cannot hold the same key twice, so a duplicate can only
      # arrive from a duplicate-preserving JSON decoder, whose object is a list
      # of pairs. That is the shape restore has to refuse.
      duplicated = %{checkpoint | "projections" => [{"counts", spec}, {"counts", spec}]}

      assert {:error, %Error{code: :invalid_checkpoint} = err} =
               record(LogReducer.restore(duplicated, registry_map()))

      assert err.details.reason == :duplicate_projection_name
      assert err.details.projection == "counts"
    end

    test "a checkpoint with two writer ids yields invalid_checkpoint" do
      state = reduce!([epoch("counts", @epoch_a, nil)])
      {:ok, checkpoint} = LogReducer.checkpoint(state)

      # Section 19: "reject a checkpoint using several writer IDs." Section 5.6
      # allows a writer ID to be stored alongside a head, so a projection may
      # carry one -- but every writer ID in one checkpoint must be the same one.
      forked = put_in(checkpoint["projections"]["counts"]["writer_id"], @other_writer)

      assert {:error, %Error{code: :invalid_checkpoint} = err} =
               record(LogReducer.restore(forked, registry_map()))

      assert err.details.reason == :several_writer_ids
      assert Enum.sort(err.details.writer_ids) == Enum.sort([@writer, @other_writer])
    end

    test "a plugin refusing restore yields invalid_checkpoint" do
      state =
        reduce!([
          epoch("noisy", @epoch_a, nil,
            reducer_id: "fixture.naughty",
            base: %{"restore" => "refuse"}
          )
        ])

      {:ok, checkpoint} = LogReducer.checkpoint(state)

      assert {:error, %Error{code: :invalid_checkpoint} = err} =
               record(LogReducer.restore(checkpoint, registry_map()))

      assert err.projection == "noisy"
      assert err.details.reason == :refuses_restore
    end

    test "core validation rejects a structurally broken checkpoint" do
      state = reduce!([epoch("counts", @epoch_a, nil)])
      {:ok, checkpoint} = LogReducer.checkpoint(state)

      broken = [
        {:not_an_object, "nope"},
        {:unsupported_version, %{checkpoint | "version" => 2}},
        {:missing_field, Map.delete(checkpoint, "log_id")},
        {:invalid_log_id, %{checkpoint | "log_id" => 7}},
        {:invalid_writer_id, %{checkpoint | "writer_id" => nil}},
        {:invalid_head, %{checkpoint | "head" => %{"writer_seq" => 0, "entry_id" => "e1"}}},
        {:invalid_head, %{checkpoint | "head" => %{"writer_seq" => 1}}},
        {:invalid_projections, %{checkpoint | "projections" => 3}},
        {:invalid_projection, put_in(checkpoint["projections"]["counts"], "nope")},
        {:invalid_epoch_id, put_in(checkpoint["projections"]["counts"]["epoch_id"], 1)},
        {:invalid_seen_epoch_ids,
         put_in(checkpoint["projections"]["counts"]["seen_epoch_ids"], "a")},
        {:invalid_seen_epoch_ids,
         put_in(checkpoint["projections"]["counts"]["seen_epoch_ids"], [1])},
        {:invalid_epoch_head, put_in(checkpoint["projections"]["counts"]["epoch_head"], %{})},
        {:invalid_reducer,
         put_in(checkpoint["projections"]["counts"]["reducer"], %{"id" => "x"})},
        {:plugin_state_not_an_object, put_in(checkpoint["projections"]["counts"]["state"], [])}
      ]

      for {reason, bad} <- broken do
        assert {:error, %Error{code: :invalid_checkpoint} = err} =
                 record(LogReducer.restore(bad, registry_map())),
               "expected #{reason} to be rejected"

        assert err.details.reason == reason
      end
    end

    test "an unusable registry is rejected before any plugin runs" do
      state = reduce!([epoch("counts", @epoch_a, nil)])
      {:ok, checkpoint} = LogReducer.checkpoint(state)

      assert {:error, {:invalid_registry, _}} = LogReducer.restore(checkpoint, %{"bad" => 1})
    end
  end

  # ==========================================================================
  # Section 19 head verification and section 42.7 equivalence
  # ==========================================================================

  describe "checkpoint plus suffix" do
    # Section 42.7: "a checkpoint plus the remaining suffix is equivalent to
    # full replay."
    test "equals full replay" do
      prefix = [
        epoch("counts", @epoch_a, nil),
        epoch("notes", @epoch_b, nil, reducer_id: "fixture.passthrough", base: %{}),
        operation("counts", @epoch_a),
        unrelated()
      ]

      suffix = [
        operation("notes", @epoch_b, %{"note" => "later"}),
        operation("counts", @epoch_a, %{"type" => "inc", "by" => 5}),
        epoch("counts", @epoch_c, @epoch_a, base: %{"start" => 100}),
        operation("counts", @epoch_c)
      ]

      full = reduce!(prefix ++ suffix)

      {:ok, checkpoint} = LogReducer.checkpoint(reduce!(prefix))
      {:ok, restored} = LogReducer.restore(checkpoint, registry_map())
      resumed = reduce!(restored, suffix, length(prefix) + 1)

      assert {:ok, full_views} = LogReducer.views(full)
      assert {:ok, resumed_views} = LogReducer.views(resumed)
      assert resumed_views == full_views
      assert State.head(resumed) == State.head(full)

      assert LogReducer.checkpoint(resumed) == LogReducer.checkpoint(full)

      assert resumed.projections["counts"].seen_epoch_ids ==
               full.projections["counts"].seen_epoch_ids
    end

    test "input after restore must begin at head.writer_seq + 1 with the right predecessor" do
      {:ok, checkpoint} =
        LogReducer.checkpoint(
          reduce!([epoch("counts", @epoch_a, nil), operation("counts", @epoch_a)])
        )

      {:ok, restored} = LogReducer.restore(checkpoint, registry_map())
      assert State.head(restored) == %{writer_seq: 2, entry_id: "e2"}

      # The right next entry: seq 3 with predecessor e2.
      assert {:ok, _} = LogReducer.reduce(restored, entries([operation("counts", @epoch_a)], 3))

      # A skipped sequence is a gap.
      assert {:error, %Error{code: :writer_gap}, ^restored} =
               LogReducer.reduce(restored, entries([operation("counts", @epoch_a)], 4))

      # A re-sent sequence is a fork.
      assert {:error, %Error{code: :writer_fork}, ^restored} =
               LogReducer.reduce(restored, entries([operation("counts", @epoch_a)], 2))

      # The right sequence with the wrong predecessor is a fork too.
      wrong_parent =
        entries([operation("counts", @epoch_a)], 3)
        |> Enum.map(&Map.put(&1, "prev_entry_id", "somewhere-else"))

      assert {:error, %Error{code: :writer_fork}, ^restored} =
               LogReducer.reduce(restored, wrong_parent)

      # And another writer's lane is still refused after a restore.
      other_lane =
        entries([operation("counts", @epoch_a)], 3)
        |> Enum.map(&Map.put(&1, "writer_id", @other_writer))

      assert {:error, %Error{code: :multiwriter_document_unsupported}, ^restored} =
               LogReducer.reduce(restored, other_lane)
    end
  end

  # ==========================================================================
  # Section 20 -- determinism
  # ==========================================================================

  describe "section 20 canonical JSON" do
    test "a checkpoint round-trips through canonical JSON byte-identically" do
      state = two_projections()
      {:ok, checkpoint} = LogReducer.checkpoint(state)

      bytes = Jcs.encode!(checkpoint)

      assert {:ok, restored} = LogReducer.restore(Jason.decode!(bytes), registry_map())
      assert {:ok, again} = LogReducer.checkpoint(restored)

      assert Jcs.encode!(again) == bytes
    end

    test "two independent replays of the same prefix produce identical bytes" do
      bodies = [
        epoch("counts", @epoch_a, nil),
        operation("counts", @epoch_a),
        epoch("notes", @epoch_b, nil, reducer_id: "fixture.passthrough", base: %{}),
        operation("notes", @epoch_b, %{"note" => "x"})
      ]

      {:ok, one} = LogReducer.checkpoint(reduce!(bodies))
      {:ok, two} = LogReducer.checkpoint(reduce!(bodies))

      assert Jcs.encode!(one) == Jcs.encode!(two)
      assert {:ok, views_one} = LogReducer.views(reduce!(bodies))
      assert {:ok, views_two} = LogReducer.views(reduce!(bodies))
      assert views_one == views_two
    end

    test "created_at does not affect the checkpoint" do
      bodies = [epoch("counts", @epoch_a, nil), operation("counts", @epoch_a)]

      shifted =
        bodies
        |> entries()
        |> Enum.map(&Map.put(&1, "created_at", "1999-01-01T00:00:00Z"))

      {:ok, plain} = LogReducer.reduce(fresh(), entries(bodies))
      {:ok, moved} = LogReducer.reduce(fresh(), shifted)

      assert LogReducer.checkpoint(plain) == LogReducer.checkpoint(moved)
    end
  end
end
