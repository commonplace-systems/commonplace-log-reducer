defmodule Commonplace.AttributeMap.V1Test do
  use ExUnit.Case, async: true

  alias Commonplace.AttributeMap
  alias Commonplace.AttributeMap.V1
  alias Commonplace.LogReducer.Context
  alias Commonplace.LogReducer.Registry

  # Reasons are pinned as atoms (spec 33), never as message strings.
  defp reason({:error, {reason, _details}}), do: reason

  defp ctx do
    %Context{
      log_id: "log-1",
      writer_id: "writer-1",
      writer_seq: 1,
      entry_id: "entry-1",
      projection: "attributes",
      epoch_id: "epoch-1",
      reducer_id: "commonplace.attribute-map",
      reducer_version: 1
    }
  end

  defp init!(values) do
    {:ok, state} = V1.init(%{"values" => values}, ctx())
    state
  end

  defp apply!(state, operation) do
    {:ok, next} = V1.apply(operation, ctx(), state)
    next
  end

  describe "identity (spec 23)" do
    test "reports the spec's id and version" do
      assert "commonplace.attribute-map" = V1.reducer_id()
      assert 1 = V1.reducer_version()
    end

    test "Registry.build/1 accepts the registration key" do
      assert {:ok, registry} =
               Registry.build(%{{"commonplace.attribute-map", 1} => V1})

      assert {:ok, V1} = Registry.resolve(registry, "commonplace.attribute-map", 1)
    end

    test "the facade module reports identity and default projection" do
      assert "commonplace.attribute-map" = AttributeMap.reducer_id()
      assert 1 = AttributeMap.reducer_version()
      assert "attributes" = AttributeMap.default_projection()
      assert V1 = AttributeMap.plugin()
      assert {:ok, _} = Registry.build(AttributeMap.registry_entries())
    end
  end

  describe "epoch base (spec 26)" do
    test "init from an empty values object" do
      assert {:ok, state} = V1.init(%{"values" => %{}}, ctx())
      assert {:ok, %{}} = V1.view(state)
    end

    test "init from a non-empty values object" do
      base = %{"values" => %{"commonplace.type" => "page", "commonplace.title" => "Hello"}}
      assert {:ok, state} = V1.init(base, ctx())

      assert {:ok, %{"commonplace.type" => "page", "commonplace.title" => "Hello"}} =
               V1.view(state)
    end

    test "a base with an extra field is rejected" do
      assert :base_fields =
               reason(V1.init(%{"values" => %{}, "epoch" => 2}, ctx()))
    end

    test "a base missing \"values\" is rejected" do
      assert :base_fields = reason(V1.init(%{}, ctx()))
      assert :base_fields = reason(V1.init(%{"vals" => %{}}, ctx()))
    end

    test "a non-object base is rejected" do
      assert :base_not_object = reason(V1.init([], ctx()))
      assert :base_not_object = reason(V1.init("values", ctx()))
      assert :base_not_object = reason(V1.init(nil, ctx()))
    end

    test "a non-object values is rejected" do
      assert :values_not_object = reason(V1.init(%{"values" => []}, ctx()))
      assert :values_not_object = reason(V1.init(%{"values" => nil}, ctx()))
    end

    test "a base with an invalid key or value is rejected" do
      assert :key_empty = reason(V1.init(%{"values" => %{"" => 1}}, ctx()))
      assert :invalid_json_value = reason(V1.init(%{"values" => %{"a" => :bad}}, ctx()))
    end

    test "a later base is a complete replacement, not a patch" do
      state = init!(%{"a" => 1, "b" => 2})
      assert {:ok, replaced} = V1.init(%{"values" => %{"c" => 3}}, ctx())
      assert {:ok, %{"c" => 3}} = V1.view(replaced)
      refute Map.has_key?(elem(V1.view(replaced), 1), "a")
      # the prior state is untouched, being an immutable term
      assert {:ok, %{"a" => 1, "b" => 2}} = V1.view(state)
    end
  end

  describe "put (spec 27)" do
    test "put adds a new key" do
      state = init!(%{}) |> apply!(%{"type" => "put", "key" => "a", "value" => 1})
      assert {:ok, %{"a" => 1}} = V1.view(state)
    end

    test "put overwrites an existing key" do
      state =
        init!(%{"a" => 1, "b" => 2})
        |> apply!(%{"type" => "put", "key" => "a", "value" => "new"})

      assert {:ok, %{"a" => "new", "b" => 2}} = V1.view(state)
    end

    test "put of null leaves the key PRESENT" do
      state = init!(%{"a" => 1}) |> apply!(%{"type" => "put", "key" => "a", "value" => nil})
      {:ok, view} = V1.view(state)

      assert Map.has_key?(view, "a"), "null must be present, not absent (spec 24, 42.9)"
      assert view["a"] == nil
      assert view == %{"a" => nil}

      # and it is observably different from deletion
      deleted = apply!(state, %{"type" => "delete", "key" => "a"})
      {:ok, deleted_view} = V1.view(deleted)
      refute Map.has_key?(deleted_view, "a")
      assert view != deleted_view
    end

    test "put validates its key and value" do
      state = init!(%{"a" => 1})

      assert :key_empty =
               reason(V1.apply(%{"type" => "put", "key" => "", "value" => 1}, ctx(), state))

      assert :key_not_string =
               reason(V1.apply(%{"type" => "put", "key" => 1, "value" => 1}, ctx(), state))

      assert :invalid_json_value =
               reason(V1.apply(%{"type" => "put", "key" => "a", "value" => :bad}, ctx(), state))
    end

    test "a rejected put leaves state completely unchanged" do
      state = init!(%{"a" => 1})
      assert {:error, _} = V1.apply(%{"type" => "put", "key" => "", "value" => 2}, ctx(), state)
      assert {:ok, %{"a" => 1}} = V1.view(state)
    end
  end

  describe "delete (spec 28)" do
    test "delete removes an existing key" do
      state = init!(%{"a" => 1, "b" => 2}) |> apply!(%{"type" => "delete", "key" => "a"})
      {:ok, view} = V1.view(state)
      refute Map.has_key?(view, "a")
      assert view == %{"b" => 2}
    end

    test "delete of an absent key succeeds unchanged" do
      state = init!(%{"b" => 2})
      assert {:ok, next} = V1.apply(%{"type" => "delete", "key" => "gone"}, ctx(), state)
      assert {:ok, %{"b" => 2}} = V1.view(next)
      # idempotent: doing it again changes nothing either
      assert {:ok, ^next} = V1.apply(%{"type" => "delete", "key" => "gone"}, ctx(), next)
    end

    test "delete validates its key" do
      state = init!(%{})
      assert :key_empty = reason(V1.apply(%{"type" => "delete", "key" => ""}, ctx(), state))
      assert :key_not_string = reason(V1.apply(%{"type" => "delete", "key" => nil}, ctx(), state))
    end
  end

  describe "operation shape (spec 27, 28, 29)" do
    setup do: {:ok, state: init!(%{"a" => 1})}

    test "an operation with an extra field is rejected", %{state: state} do
      assert :operation_fields =
               reason(
                 V1.apply(
                   %{"type" => "put", "key" => "a", "value" => 1, "extra" => true},
                   ctx(),
                   state
                 )
               )

      assert :operation_fields =
               reason(V1.apply(%{"type" => "delete", "key" => "a", "value" => 1}, ctx(), state))

      assert :operation_fields =
               reason(
                 V1.apply(
                   %{"type" => "patch", "put" => %{}, "delete" => [], "x" => 1},
                   ctx(),
                   state
                 )
               )
    end

    test "an operation missing a field is rejected", %{state: state} do
      assert :operation_fields = reason(V1.apply(%{"type" => "put", "key" => "a"}, ctx(), state))
      assert :operation_fields = reason(V1.apply(%{"type" => "delete"}, ctx(), state))

      assert :operation_fields =
               reason(V1.apply(%{"type" => "patch", "put" => %{}}, ctx(), state))

      # no "type" at all
      assert :operation_fields = reason(V1.apply(%{"key" => "a"}, ctx(), state))
    end

    test "an unknown operation type is rejected", %{state: state} do
      assert :unknown_operation =
               reason(V1.apply(%{"type" => "frobnicate", "key" => "a"}, ctx(), state))

      assert :unknown_operation = reason(V1.apply(%{"type" => "PUT", "key" => "a"}, ctx(), state))
      assert :unknown_operation = reason(V1.apply(%{"type" => 1}, ctx(), state))
    end

    test "a non-object operation is rejected", %{state: state} do
      assert :operation_fields = reason(V1.apply([], ctx(), state))
      assert :operation_fields = reason(V1.apply("put", ctx(), state))
      assert :operation_fields = reason(V1.apply(nil, ctx(), state))
    end
  end

  describe "patch (spec 29)" do
    test "patch applies all puts and deletes" do
      state =
        init!(%{"keep" => 0, "gone" => 1, "old" => 2})
        |> apply!(%{
          "type" => "patch",
          "put" => %{"old" => "new", "fresh" => true},
          "delete" => ["gone"]
        })

      assert {:ok, view} = V1.view(state)
      assert view == %{"keep" => 0, "old" => "new", "fresh" => true}
      refute Map.has_key?(view, "gone")
    end

    test "an empty patch is a successful no-op" do
      state = init!(%{"a" => 1})

      assert {:ok, next} =
               V1.apply(%{"type" => "patch", "put" => %{}, "delete" => []}, ctx(), state)

      assert next == state
      assert {:ok, %{"a" => 1}} = V1.view(next)
    end

    test "patch delete of an absent key succeeds" do
      state = init!(%{"a" => 1})

      assert {:ok, next} =
               V1.apply(%{"type" => "patch", "put" => %{}, "delete" => ["nope"]}, ctx(), state)

      assert {:ok, %{"a" => 1}} = V1.view(next)
    end

    test "a key in both put and delete is rejected" do
      state = init!(%{"a" => 1})

      assert :overlapping_patch_key =
               reason(
                 V1.apply(
                   %{"type" => "patch", "put" => %{"a" => 2}, "delete" => ["a"]},
                   ctx(),
                   state
                 )
               )
    end

    test "duplicate delete keys are rejected" do
      state = init!(%{"a" => 1})

      assert :duplicate_delete_key =
               reason(
                 V1.apply(
                   %{"type" => "patch", "put" => %{}, "delete" => ["a", "b", "a"]},
                   ctx(),
                   state
                 )
               )
    end

    test "a non-array delete is rejected" do
      state = init!(%{"a" => 1})

      assert :delete_not_array =
               reason(V1.apply(%{"type" => "patch", "put" => %{}, "delete" => %{}}, ctx(), state))

      assert :delete_not_array =
               reason(V1.apply(%{"type" => "patch", "put" => %{}, "delete" => "a"}, ctx(), state))
    end

    test "a non-object put is rejected" do
      state = init!(%{"a" => 1})

      assert :values_not_object =
               reason(V1.apply(%{"type" => "patch", "put" => [], "delete" => []}, ctx(), state))
    end

    test "patch validates every delete key" do
      state = init!(%{"a" => 1})

      assert :key_empty =
               reason(
                 V1.apply(%{"type" => "patch", "put" => %{}, "delete" => [""]}, ctx(), state)
               )

      assert :key_not_string =
               reason(V1.apply(%{"type" => "patch", "put" => %{}, "delete" => [1]}, ctx(), state))
    end

    test "A PATCH REJECTED FOR ITS LAST KEY CHANGES NOTHING" do
      # The trap, and what it actually catches -- both sabotages were run.
      #
      #   (a) Rewriting the patch path to validate-and-apply in one fold, still
      #       returning {:error, _} on the bad key, left this test GREEN. That
      #       is correct, not a gap: plugin state is an immutable term, so a
      #       partially-built map that is never returned cannot be observed.
      #       Atomicity in this language is "return {:error, _}, not a partial
      #       {:ok, _}" -- there is no in-place mutation to roll back.
      #
      #   (b) Rewriting the fold to halt with {:ok, partial_state} -- the fold
      #       bug that IS reachable here, and a section 12.1 "silently ignore"
      #       violation -- turned this test RED, along with two others, with
      #       V1.apply/3 returning {:ok, %{"a" => 1, "p1" => "x", "p2" => "y"}}:
      #       "b" and "c" deleted and both puts applied.
      #
      # So the load-bearing assertion is that apply/3 returns an error at all
      # and no state alongside it; the whole-state equality below is the
      # backstop for any future implementation that does not keep state
      # immutable.
      before = init!(%{"a" => 1, "b" => 2, "c" => 3})

      operation = %{
        "type" => "patch",
        "put" => %{"p1" => "x", "p2" => "y"},
        "delete" => ["b", "c", ""]
      }

      assert :key_empty = reason(V1.apply(operation, ctx(), before))

      {:ok, after_view} = V1.view(before)
      assert after_view == %{"a" => 1, "b" => 2, "c" => 3}
      assert {:ok, ^before} = V1.init(%{"values" => %{"a" => 1, "b" => 2, "c" => 3}}, ctx())
    end

    test "a patch rejected for its last PUT value changes nothing" do
      before = init!(%{"a" => 1, "b" => 2, "c" => 3})

      # 40 puts so the map is large enough that iteration order is not
      # insertion order, plus one invalid value somewhere in it.
      puts =
        1..40
        |> Map.new(fn n -> {"p#{n}", n} end)
        |> Map.put("bad", :not_json)

      operation = %{"type" => "patch", "put" => puts, "delete" => ["b"]}

      assert :invalid_json_value = reason(V1.apply(operation, ctx(), before))
      assert {:ok, %{"a" => 1, "b" => 2, "c" => 3}} = V1.view(before)
    end

    test "a rejected overlapping patch changes nothing" do
      before = init!(%{"a" => 1, "b" => 2})

      operation = %{
        "type" => "patch",
        "put" => %{"z" => 9, "b" => 3},
        "delete" => ["a", "b"]
      }

      assert :overlapping_patch_key = reason(V1.apply(operation, ctx(), before))
      assert {:ok, %{"a" => 1, "b" => 2}} = V1.view(before)
    end
  end

  describe "sequential overwrite (spec 30)" do
    test "the last operation in sequence wins" do
      state =
        init!(%{})
        |> apply!(%{"type" => "put", "key" => "title", "value" => "one"})
        |> apply!(%{"type" => "put", "key" => "title", "value" => "two"})
        |> apply!(%{"type" => "delete", "key" => "title"})
        |> apply!(%{"type" => "put", "key" => "title", "value" => "three"})

      assert {:ok, %{"title" => "three"}} = V1.view(state)
    end

    test "context fields do not affect the result" do
      # Spec 30 / 12.1: reduction depends on state, operation, and resources.
      # Nothing in the coordinate may change the outcome.
      op = %{"type" => "put", "key" => "a", "value" => 1}
      state = init!(%{})

      other = %Context{
        ctx()
        | writer_seq: 99,
          entry_id: "entry-999",
          log_id: "other-log",
          epoch_id: "other-epoch"
      }

      assert V1.apply(op, ctx(), state) == V1.apply(op, other, state)
    end
  end

  describe "view (spec 31)" do
    test "the view is exactly the attribute map, no wrapper" do
      state = init!(%{"commonplace.title" => "Renamed", "commonplace.archived" => false})
      assert {:ok, view} = V1.view(state)
      assert view == %{"commonplace.title" => "Renamed", "commonplace.archived" => false}
      refute Map.has_key?(view, "values")
      assert Map.keys(view) |> Enum.sort() == ["commonplace.archived", "commonplace.title"]
    end

    test "the view exposes no deletion tombstones" do
      state = init!(%{"a" => 1}) |> apply!(%{"type" => "delete", "key" => "a"})
      assert {:ok, %{}} = V1.view(state)
      assert {:ok, view} = V1.view(state)
      assert map_size(view) == 0
    end

    test "the view is JSON-encodable" do
      state = init!(%{"a" => nil, "b" => [1, %{"c" => true}]})
      {:ok, view} = V1.view(state)
      assert {:ok, json} = Jason.encode(view)
      assert {:ok, ^view} = Jason.decode(json)
    end
  end

  describe "checkpoint (spec 32)" do
    test "checkpoint round-trips through restore" do
      state = init!(%{"a" => 1, "b" => nil, "c" => %{"d" => [1, 2]}})
      assert {:ok, checkpoint} = V1.checkpoint(state)
      assert {:ok, restored} = V1.restore(checkpoint, ctx())
      assert restored == state
      assert V1.view(restored) == V1.view(state)
      # null survives the round trip as a present key
      {:ok, view} = V1.view(restored)
      assert Map.has_key?(view, "b")
      assert view["b"] == nil
    end

    test "a checkpoint of an empty map round-trips" do
      state = init!(%{})
      assert {:ok, %{"values" => %{}} = checkpoint} = V1.checkpoint(state)
      assert {:ok, restored} = V1.restore(checkpoint, ctx())
      assert restored == state
      assert {:ok, %{}} = V1.view(restored)
    end

    test "the checkpoint is identical in shape to an epoch base" do
      state = init!(%{"a" => 1})
      assert {:ok, checkpoint} = V1.checkpoint(state)
      assert checkpoint == %{"values" => %{"a" => 1}}
      # ... so it is accepted verbatim by init/2
      assert {:ok, ^state} = V1.init(checkpoint, ctx())
    end

    test "the checkpoint contains no log id, head, projection, epoch, or reducer identity" do
      state = init!(%{"a" => 1})
      assert {:ok, checkpoint} = V1.checkpoint(state)
      assert Map.keys(checkpoint) == ["values"]

      forbidden = ~w(log_id logId writer_id writerId head log_head projection
                     epoch_id epochId epoch reducer_id reducerId reducer
                     reducer_version reducerVersion)

      for field <- forbidden do
        refute Map.has_key?(checkpoint, field), "checkpoint must not carry #{field}"
      end

      # nor smuggled anywhere in the serialized form
      {:ok, json} = Jason.encode(checkpoint)

      for field <- forbidden do
        refute String.contains?(json, field), "serialized checkpoint mentions #{field}"
      end

      refute String.contains?(json, "commonplace.attribute-map")
      refute String.contains?(json, ctx().log_id)
      refute String.contains?(json, ctx().epoch_id)
    end

    test "the checkpoint is JSON-encodable" do
      state = init!(%{"a" => nil, "b" => [1, 2]})
      {:ok, checkpoint} = V1.checkpoint(state)
      assert {:ok, json} = Jason.encode(checkpoint)
      assert {:ok, decoded} = Jason.decode(json)
      assert {:ok, ^state} = V1.restore(decoded, ctx())
    end

    test "restore rejects a malformed checkpoint" do
      assert :base_not_object = reason(V1.restore([], ctx()))
      assert :base_fields = reason(V1.restore(%{}, ctx()))
      assert :base_fields = reason(V1.restore(%{"values" => %{}, "head" => 7}, ctx()))
      assert :values_not_object = reason(V1.restore(%{"values" => []}, ctx()))
      assert :key_empty = reason(V1.restore(%{"values" => %{"" => 1}}, ctx()))
      assert :invalid_json_value = reason(V1.restore(%{"values" => %{"a" => :bad}}, ctx()))
    end

    test "checkpoint plus suffix equals full replay" do
      ops = [
        %{"type" => "put", "key" => "a", "value" => 1},
        %{"type" => "put", "key" => "b", "value" => nil},
        %{"type" => "patch", "put" => %{"c" => 3}, "delete" => ["a"]},
        %{"type" => "delete", "key" => "c"},
        %{"type" => "put", "key" => "d", "value" => "last"}
      ]

      full = Enum.reduce(ops, init!(%{}), &apply!(&2, &1))

      {prefix, suffix} = Enum.split(ops, 2)
      mid = Enum.reduce(prefix, init!(%{}), &apply!(&2, &1))
      {:ok, checkpoint} = V1.checkpoint(mid)
      {:ok, restored} = V1.restore(checkpoint, ctx())
      resumed = Enum.reduce(suffix, restored, &apply!(&2, &1))

      assert resumed == full
      assert V1.view(resumed) == V1.view(full)
      assert V1.checkpoint(resumed) == V1.checkpoint(full)
    end
  end
end
