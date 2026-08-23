defmodule Commonplace.AttributeMap.PropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduledoc """
  The section 39 attribute-map properties, over generated valid histories.

  Section 39 names seven:

    1. put followed by put yields the second value;
    2. put followed by delete yields absence;
    3. delete followed by put yields the put value;
    4. operations on distinct keys commute;
    5. a valid patch equals its puts and deletes applied in any order allowed
       by non-overlap;
    6. checkpoint and restore preserve the exact map; and
    7. all rejected operations leave state unchanged.

  An eighth is added here from sections 20, 38.16 and 42.4: re-running a
  history with `created_at` shuffled changes neither the view nor the
  checkpoint nor a failure coordinate.

  ## Presence, not value

  Sections 24 and 42.9 make attribute null and attribute deletion observably
  different: `put` with a null value leaves the key PRESENT holding null, and
  only `delete` makes it absent. Every absence assertion below is therefore
  `Map.has_key?/2`, never a comparison against `nil` -- comparing values makes
  the two cases identical and turns properties 2 and 3 into decoration.

  ## Comparison is canonical JSON bytes

  Section 20 compares runs with RFC 8785 canonical JSON, so map comparisons go
  through `canon/1` rather than Elixir term equality, which would let `1` and
  `1.0` compare equal.

  ## Two levels, deliberately

  Properties 1 through 6 are algebra over the plugin and are exercised through
  `V1` directly, which is where the claims live. Property 7 is exercised
  THROUGH THE ENGINE: at the plugin level "a rejected operation leaves state
  unchanged" is trivially true, because `apply/3` returns `{:error, reason}`
  and no state at all. The claim only has content one level up, where the
  question is whether the engine's projection and head moved -- so that is
  where it is asked.
  """

  alias Commonplace.AttributeMap
  alias Commonplace.AttributeMap.V1
  alias Commonplace.LogReducer
  alias Commonplace.LogReducer.{Context, Error, State}

  @log "0198d83c-eaf8-7c5d-b1e3-4387f1d8d9b8"
  @writer "0198d83d-54de-7c06-b574-ea1fb40d3a86"
  @epoch "0198d900-0000-7000-8000-00000000000a"
  @epoch_two "0198d900-0000-7000-8000-00000000000b"

  # -- generators -------------------------------------------------------------

  defp key do
    one_of([
      string(:alphanumeric, min_length: 1, max_length: 6),
      member_of(["commonplace.title", "commonplace.type", "a/b", "ünïcode-kéy", "0", " "])
    ])
  end

  # Null is in here on purpose: it is an ordinary present value (section 24),
  # and a value generator that omitted it could not tell properties 1 and 2
  # apart.
  defp value do
    tree(
      one_of([
        constant(nil),
        boolean(),
        integer(-1000..1000),
        float(min: -1000.0, max: 1000.0),
        string(:printable, max_length: 6)
      ]),
      fn child ->
        one_of([
          list_of(child, max_length: 3),
          map_of(string(:alphanumeric, min_length: 1, max_length: 3), child, max_length: 3)
        ])
      end
    )
  end

  defp values(opts \\ []) do
    map_of(key(), value(), Keyword.merge([max_length: 4], opts))
  end

  # A single valid operation. Every shape here is one section 27-29 accepts, so
  # a generated history is valid by construction rather than by luck.
  defp operation do
    one_of([
      map(tuple({key(), value()}), fn {k, v} ->
        %{"type" => "put", "key" => k, "value" => v}
      end),
      map(key(), fn k -> %{"type" => "delete", "key" => k} end),
      patch()
    ])
  end

  # Non-overlap (section 29) is enforced by construction: the delete list is
  # the generated keys MINUS the put keys.
  defp patch do
    gen all(
          put <- values(),
          delete <- list_of(key(), max_length: 3)
        ) do
      %{
        "type" => "patch",
        "put" => put,
        "delete" => Enum.uniq(delete) -- Map.keys(put)
      }
    end
  end

  defp history do
    gen all(
          base <- values(),
          operations <- list_of(operation(), max_length: 8)
        ) do
      %{base: base, operations: operations}
    end
  end

  # A generated attribute map: a base plus a generated run of valid operations,
  # applied through the real plugin.
  defp attribute_map do
    map(history(), &state_of/1)
  end

  defp permutation(list) do
    gen all(keys <- list_of(integer(), length: length(list))) do
      keys
      |> Enum.zip(list)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))
    end
  end

  defp created_at do
    map(integer(0..999_999), fn n -> "2026-08-22T00:00:00.#{n}Z" end)
  end

  # -- plugin helpers ---------------------------------------------------------

  defp ctx do
    %Context{
      log_id: @log,
      writer_id: @writer,
      writer_seq: 1,
      entry_id: "entry-1",
      projection: "attributes",
      epoch_id: @epoch,
      reducer_id: AttributeMap.reducer_id(),
      reducer_version: AttributeMap.reducer_version()
    }
  end

  defp init!(base) do
    {:ok, state} = V1.init(%{"values" => base}, ctx())
    state
  end

  defp apply!(state, operation) do
    assert {:ok, next} = V1.apply(operation, ctx(), state),
           "the generator produced an operation the plugin rejects: #{inspect(operation)}"

    next
  end

  defp state_of(%{base: base, operations: operations}) do
    Enum.reduce(operations, init!(base), &apply!(&2, &1))
  end

  defp put(k, v), do: %{"type" => "put", "key" => k, "value" => v}
  defp delete(k), do: %{"type" => "delete", "key" => k}

  defp canon(term), do: Jcs.encode!(Conformance.json(term))

  # -- engine helpers ---------------------------------------------------------

  defp registry, do: AttributeMap.registry_entries()

  defp entries(%{base: base, operations: operations}, stamps) do
    bodies = [
      %{
        "type" => "commonplace.reducer.epoch",
        "version" => 1,
        "projection" => "attributes",
        "epoch_id" => @epoch,
        "parent_epoch_id" => nil,
        "reducer" => %{
          "id" => AttributeMap.reducer_id(),
          "version" => AttributeMap.reducer_version()
        },
        "base" => %{"values" => base}
      }
      | Enum.map(operations, &operation_body/1)
    ]

    bodies
    |> Enum.with_index(1)
    |> Enum.map(fn {body, seq} ->
      entry(seq, body, Enum.at(stamps, seq - 1, "2026-08-22T00:00:00Z"))
    end)
  end

  defp operation_body(operation) do
    %{
      "type" => "commonplace.reducer.operation",
      "version" => 1,
      "projection" => "attributes",
      "epoch_id" => @epoch,
      "operation" => operation
    }
  end

  defp entry(seq, body, stamp) do
    %{
      "log_id" => @log,
      "entry_id" => entry_id(seq),
      "writer_id" => @writer,
      "writer_seq" => seq,
      "prev_entry_id" => if(seq > 1, do: entry_id(seq - 1)),
      "created_at" => stamp,
      "body" => body
    }
  end

  defp entry_id(seq), do: "0198d901-0000-7000-8000-" <> String.pad_leading("#{seq}", 12, "0")

  defp run(entries) do
    {:ok, state} = LogReducer.new(@log, registry())
    LogReducer.reduce(state, entries)
  end

  defp run!(entries) do
    assert {:ok, state} = run(entries)
    state
  end

  defp view!(state) do
    {:ok, view} = LogReducer.view(state, "attributes")
    view
  end

  defp checkpoint!(state) do
    {:ok, checkpoint} = LogReducer.checkpoint(state)
    checkpoint
  end

  defp stamps(history), do: List.duplicate("2026-08-22T00:00:00Z", length(history.operations) + 1)

  # -- generator health -------------------------------------------------------

  describe "generator health" do
    property "a generated history is non-empty and every operation is accepted" do
      check all(history <- history()) do
        state = state_of(history)

        assert is_map(state)
        assert Enum.all?(Map.keys(state), &is_binary/1)
        assert length(entries(history, stamps(history))) == length(history.operations) + 1
      end
    end

    property "a generated history actually reduces through the engine" do
      check all(history <- history()) do
        state = run!(entries(history, stamps(history)))

        # And the engine's view agrees with the direct fold, so the two levels
        # this suite works at are not testing two different plugins.
        assert canon(view!(state).value) == canon(state_of(history))
      end
    end

    test "different seeds produce different histories" do
      generator = history()

      :rand.seed(:exsss, {1, 2, 3})
      first = Enum.take(generator, 20)

      :rand.seed(:exsss, {9, 8, 7})
      second = Enum.take(generator, 20)

      refute first == second, "the generator ignores its seed"
      assert length(Enum.uniq(first)) > 1, "the generator emits one case forever"
    end

    test "the generated corpus reaches every operation type, and null values" do
      :rand.seed(:exsss, {4, 5, 6})
      histories = Enum.take(history(), 300)
      operations = Enum.flat_map(histories, & &1.operations)

      assert Enum.sort(Enum.uniq(Enum.map(operations, & &1["type"]))) == [
               "delete",
               "patch",
               "put"
             ]

      assert Enum.any?(operations, &(&1["type"] == "put" and is_nil(&1["value"]))),
             "no null value was ever generated: properties 1 and 2 cannot tell " <>
               "null from absent on this corpus"

      assert Enum.any?(histories, &(&1.base != %{})), "every generated base was empty"
    end
  end

  # -- section 39, property 1 -------------------------------------------------

  property "put then put yields the second value" do
    check all(
            state <- attribute_map(),
            k <- key(),
            first <- value(),
            second <- value()
          ) do
      result = state |> apply!(put(k, first)) |> apply!(put(k, second))

      assert Map.has_key?(result, k)
      assert canon(Map.fetch!(result, k)) == canon(second)
      assert canon(Map.delete(result, k)) == canon(Map.delete(state, k))
    end
  end

  # -- section 39, property 2 -------------------------------------------------

  property "put then delete yields absence" do
    check all(
            state <- attribute_map(),
            k <- key(),
            v <- value()
          ) do
      result = state |> apply!(put(k, v)) |> apply!(delete(k))

      # `Map.has_key?`, never `== nil`: a put of null leaves the key present
      # holding null, and value comparison cannot see the difference.
      refute Map.has_key?(result, k)
      assert canon(result) == canon(Map.delete(state, k))
    end
  end

  # -- section 39, property 3 -------------------------------------------------

  property "delete then put yields the put value" do
    check all(
            state <- attribute_map(),
            k <- key(),
            v <- value()
          ) do
      result = state |> apply!(delete(k)) |> apply!(put(k, v))

      assert Map.has_key?(result, k)
      assert canon(Map.fetch!(result, k)) == canon(v)
    end
  end

  # -- section 39, property 4 -------------------------------------------------

  property "operations on distinct keys commute" do
    check all(
            state <- attribute_map(),
            keys <- uniq_list_of(key(), min_length: 2, max_length: 4),
            operations <-
              list_of(one_of([constant(:put), constant(:delete)]), length: length(keys)),
            payloads <- list_of(value(), length: length(keys)),
            ordered <- permutation(Enum.zip([keys, operations, payloads]))
          ) do
      original = Enum.zip([keys, operations, payloads])

      assert canon(fold(state, original)) == canon(fold(state, ordered)),
             "operations on distinct keys did not commute"
    end
  end

  defp fold(state, operations) do
    Enum.reduce(operations, state, fn
      {k, :put, v}, acc -> apply!(acc, put(k, v))
      {k, :delete, _v}, acc -> apply!(acc, delete(k))
    end)
  end

  # -- section 39, property 5 -------------------------------------------------

  property "a valid patch equals its puts and deletes in any non-overlapping order" do
    check all(
            state <- attribute_map(),
            patch <- patch(),
            order <- permutation(patch_operations(patch))
          ) do
      patched = apply!(state, patch)
      one_by_one = Enum.reduce(order, state, &apply!(&2, &1))

      assert canon(patched) == canon(one_by_one)

      # Presence, not value: a patch that put a null must leave that key
      # present in both, and byte equality alone would also be satisfied by
      # two maps that are both missing it.
      for k <- Map.keys(patch["put"]), do: assert(Map.has_key?(patched, k))
      for k <- patch["delete"], do: refute(Map.has_key?(patched, k))
    end
  end

  defp patch_operations(patch) do
    Enum.map(patch["put"], fn {k, v} -> put(k, v) end) ++
      Enum.map(patch["delete"], &delete/1)
  end

  # -- section 39, property 6 -------------------------------------------------

  property "checkpoint then restore preserves the map exactly" do
    check all(state <- attribute_map()) do
      assert {:ok, checkpoint} = V1.checkpoint(state)
      assert {:ok, restored} = V1.restore(checkpoint, ctx())

      assert canon(restored) == canon(state)

      # Key-by-key presence, because byte equality of two views cannot
      # distinguish "restored the null" from "dropped the key" if the
      # canonicalizer ever collapsed the two.
      assert Enum.sort(Map.keys(restored)) == Enum.sort(Map.keys(state))
      for k <- Map.keys(state), do: assert(Map.has_key?(restored, k))
    end
  end

  property "checkpoint then restore preserves the map through the engine too" do
    check all(history <- history()) do
      state = run!(entries(history, stamps(history)))
      assert {:ok, restored} = LogReducer.restore(checkpoint!(state), registry())

      assert canon(view!(restored)) == canon(view!(state))
      assert canon(checkpoint!(restored)) == canon(checkpoint!(state))
    end
  end

  # -- section 39, property 7 -------------------------------------------------

  # Every shape here is rejected for a DIFFERENT section 33 reason, and each is
  # named, so this list is a statement about the plugin rather than a bag of
  # things that happen to fail.
  @rejected [
    {:operation_fields, %{"type" => "put", "key" => "a"}},
    {:operation_fields, %{"type" => "put", "key" => "a", "value" => 1, "extra" => true}},
    {:operation_fields, %{"type" => "delete"}},
    {:key_not_string, %{"type" => "put", "key" => 1, "value" => 1}},
    {:key_empty, %{"type" => "put", "key" => "", "value" => 1}},
    {:key_contains_null, %{"type" => "put", "key" => "a\0b", "value" => 1}},
    {:unknown_operation, %{"type" => "frobnicate"}},
    {:overlapping_patch_key, %{"type" => "patch", "put" => %{"a" => 1}, "delete" => ["a"]}},
    {:duplicate_delete_key, %{"type" => "patch", "put" => %{}, "delete" => ["a", "a"]}},
    {:delete_not_array, %{"type" => "patch", "put" => %{}, "delete" => "a"}},
    {:values_not_object, %{"type" => "patch", "put" => [], "delete" => []}}
  ]

  property "every rejected operation leaves state unchanged" do
    check all(
            history <- history(),
            {_reason, operation} <- member_of(@rejected)
          ) do
      entries = entries(history, stamps(history))
      good = run!(entries)
      bad = entry(length(entries) + 1, operation_body(operation), "2026-08-22T00:00:00Z")

      assert {:error, %Error{} = error, prefix} = run(entries ++ [bad])
      assert error.code == :invalid_operation
      assert error.projection == "attributes"

      # The projection did not move and neither did the head (section 10.1.6).
      assert State.head(prefix) == State.head(good)
      assert canon(view!(prefix)) == canon(view!(good))
      assert canon(checkpoint!(prefix)) == canon(checkpoint!(good))
    end
  end

  # POSITIVE CONTROL for the property above. The property samples ONE rejected
  # shape per run, so a shape that silently became ACCEPTED would only redden
  # when the sampler drew it. This walks all of them every run, and pins the
  # section 33 reason atom for each -- an operation rejected for the wrong
  # reason is a different bug from one that is rejected.
  test "every listed operation is genuinely rejected, for the reason claimed" do
    state = init!(%{"a" => 1})

    for {reason, operation} <- @rejected do
      assert {:error, {^reason, _details}} = V1.apply(operation, ctx(), state),
             "expected #{reason} for #{inspect(operation)}, got #{inspect(V1.apply(operation, ctx(), state))}"
    end
  end

  # -- sections 20, 38.16, 42.4 -----------------------------------------------

  describe "created_at is not load-bearing" do
    property "shuffling created_at changes neither the view nor the checkpoint" do
      check all(
              history <- history(),
              stamps <- list_of(created_at(), length: length(history.operations) + 1),
              shuffled <- permutation(stamps)
            ) do
        original = run!(entries(history, stamps))
        reshuffled = run!(entries(history, shuffled))

        assert canon(view!(reshuffled)) == canon(view!(original))
        assert canon(checkpoint!(reshuffled)) == canon(checkpoint!(original))
      end
    end

    property "shuffling created_at changes no failure coordinate either" do
      check all(
              history <- history(),
              {_reason, operation} <- member_of(@rejected),
              stamps <- list_of(created_at(), length: length(history.operations) + 2),
              shuffled <- permutation(stamps)
            ) do
        first = failure(history, operation, stamps)
        second = failure(history, operation, shuffled)

        assert first == second
      end
    end
  end

  defp failure(history, operation, stamps) do
    entries = entries(history, stamps)
    seq = length(entries) + 1
    bad = entry(seq, operation_body(operation), Enum.at(stamps, seq - 1))

    assert {:error, %Error{} = error, prefix} = run(entries ++ [bad])

    %{
      "code" => Atom.to_string(error.code),
      "writer_seq" => error.writer_seq,
      "entry_id" => error.entry_id,
      "projection" => error.projection,
      "view" => canon(view!(prefix)),
      "checkpoint" => canon(checkpoint!(prefix))
    }
  end

  # -- section 42.3: independent epochs over one log --------------------------

  property "an epoch replacement is a complete snapshot, not a merge" do
    check all(
            history <- history(),
            base <- values()
          ) do
      entries = entries(history, stamps(history))
      seq = length(entries) + 1

      replacement =
        entry(
          seq,
          %{
            "type" => "commonplace.reducer.epoch",
            "version" => 1,
            "projection" => "attributes",
            "epoch_id" => @epoch_two,
            "parent_epoch_id" => @epoch,
            "reducer" => %{
              "id" => AttributeMap.reducer_id(),
              "version" => AttributeMap.reducer_version()
            },
            "base" => %{"values" => base}
          },
          "2026-08-22T00:00:00Z"
        )

      state = run!(entries ++ [replacement])

      assert canon(view!(state).value) == canon(base)
      assert view!(state).epoch_id == @epoch_two
    end
  end
end
