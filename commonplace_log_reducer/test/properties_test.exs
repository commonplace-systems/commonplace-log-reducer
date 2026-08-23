defmodule Commonplace.LogReducer.PropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduledoc """
  The section 39 engine properties, over generated valid entry sequences.

  Section 39 names six:

    1. full replay equals checkpoint restoration plus suffix replay;
    2. splitting input into arbitrary batches does not change the result;
    3. unrelated entries do not change any projection view;
    4. projection A operations do not change projection B;
    5. deterministic replay produces byte-equivalent canonical views and
       checkpoints; and
    6. reduction never advances past a failing entry.

  A seventh is added here because sections 20, 38.16 and 42.4 all state it and
  nothing else in the suite proves it over arbitrary histories: re-running a
  history with `created_at` shuffled changes nothing -- not the views, not the
  checkpoint, and not the failure coordinate.

  ## Comparison is canonical JSON bytes

  Section 20 compares runs with RFC 8785 canonical JSON, so every comparison
  here goes through `canon/1` (`Conformance.json/1` then `Jcs.encode!/1`) and
  never through Elixir term equality. Term equality would let `1` and `1.0`, or
  two maps whose keys differ in type, compare as the BEAM happens to compare
  them rather than as the JSON a second implementation would see.

  ## The generator is the load-bearing part

  A property suite is only as good as its generator: one that emits sequences
  the engine rejects makes every property below vacuously true, and one that
  emits a single trivial case forever proves nothing while staying green. The
  `"generator health"` describe block states those risks as real tests -- the
  sequences are non-empty, they reach the length asked for, they actually
  reduce, and they vary -- so a generator that quietly degrades reddens on its
  own terms instead of silently hollowing out the six properties.

  ## What is deliberately NOT compared where

  Two comparisons are restricted, and both restrictions are load-bearing rather
  than convenient:

    * inserting unrelated entries shifts every later `writer_seq`, so the
      shared head and each projection's `epoch_head` legitimately move. What
      section 39 claims unchanged is the projection *value* and its active
      epoch, and that is what property 3 compares.
    * masking one projection's entries (property 4) *preserves* coordinates,
      because each masked body is replaced in place by an unrelated body rather
      than removed. Nothing shifts, so that comparison is over the full view,
      head included -- the stronger statement, available only because the
      masking keeps the chain identical.
  """

  alias Commonplace.LogReducer
  alias Commonplace.LogReducer.{Error, State}

  @log "0198d83c-eaf8-7c5d-b1e3-4387f1d8d9b8"
  @writer "0198d83d-54de-7c06-b574-ea1fb40d3a86"

  # -- generators -------------------------------------------------------------

  # A plan is a projection count, a plugin per projection, a step list, and one
  # `created_at` per entry. It is deliberately NOT a list of entries: the
  # chain (writer_seq, prev_entry_id) and the epoch parent chain are computed
  # in `entries/1` from the plan, so a generated plan cannot describe an
  # invalid chain at all. Validity is a property of the assembler, not
  # something the generator has to be lucky enough to hit.
  defp plan(step_count \\ integer(0..12)) do
    gen all(
          count <- integer(1..3),
          kinds <- list_of(member_of([:counter, :passthrough]), length: count),
          n <- step_count,
          steps <- list_of(step(count), length: n),
          stamps <- list_of(created_at(), length: count + n)
        ) do
      %{count: count, kinds: kinds, steps: steps, stamps: stamps}
    end
  end

  # A plan whose projection "p0" is guaranteed to have replaced its epoch, so
  # it has at least one RETIRED epoch ID. Both the duplicate-epoch and the
  # stale-epoch invalid entries of property 6 need one to exist.
  defp plan_with_replacement do
    gen all(
          plan <- plan(),
          base <- integer(-5..5),
          stamp <- created_at()
        ) do
      %{plan | steps: plan.steps ++ [{:epoch, 0, base}], stamps: plan.stamps ++ [stamp]}
    end
  end

  defp step(count) do
    one_of([
      tuple({constant(:op), integer(0..(count - 1)), integer(-5..5), tag()}),
      tuple({constant(:epoch), integer(0..(count - 1)), integer(-5..5)}),
      tuple({constant(:unrelated), tag()})
    ])
  end

  defp tag, do: string(:alphanumeric, min_length: 1, max_length: 4)

  # Randomized, and deliberately not ordered: `created_at` is advisory
  # (sections 6 and 20), so a generator that emitted increasing timestamps
  # would be quietly assuming the very thing the timestamp property exists to
  # refute.
  defp created_at do
    map(integer(0..999_999), fn n -> "2026-08-22T00:00:00.#{n}Z" end)
  end

  # A generated permutation of `list`, driven by a generated sort key.
  defp permutation(list) do
    gen all(keys <- list_of(integer(), length: length(list))) do
      keys
      |> Enum.zip(list)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))
    end
  end

  # -- assembly ---------------------------------------------------------------

  defp names(%{count: count}), do: Enum.map(0..(count - 1), &"p#{&1}")

  # Bodies, with the epoch parent chain computed. Returns the bodies and the
  # final per-projection epoch bookkeeping (`active` and every ID ever used),
  # which property 6 needs to build a duplicate or stale epoch reference.
  defp bodies(plan) do
    names = names(plan)

    initial =
      Enum.map(0..(plan.count - 1), fn i ->
        epoch_body(Enum.at(names, i), uuid(i, 0), nil, Enum.at(plan.kinds, i), 0)
      end)

    seen0 = Map.new(0..(plan.count - 1), fn i -> {i, {uuid(i, 0), 0}} end)

    {rest, seen} =
      Enum.map_reduce(plan.steps, seen0, fn step, seen ->
        case step do
          {:unrelated, tag} ->
            {%{"type" => "app.note", "tag" => tag}, seen}

          {:op, i, by, tag} ->
            {active, _n} = Map.fetch!(seen, i)
            body = operation_body(Enum.at(names, i), active, Enum.at(plan.kinds, i), by, tag)
            {body, seen}

          {:epoch, i, base} ->
            {active, n} = Map.fetch!(seen, i)
            id = uuid(i, n + 1)
            body = epoch_body(Enum.at(names, i), id, active, Enum.at(plan.kinds, i), base)
            {body, Map.put(seen, i, {id, n + 1})}
        end
      end)

    {initial ++ rest, seen}
  end

  defp epoch_body(name, epoch_id, parent, kind, base) do
    %{
      "type" => "commonplace.reducer.epoch",
      "version" => 1,
      "projection" => name,
      "epoch_id" => epoch_id,
      "parent_epoch_id" => parent,
      "reducer" => %{"id" => reducer_id(kind), "version" => 1},
      "base" => %{"start" => base}
    }
  end

  defp operation_body(name, epoch_id, kind, by, tag) do
    %{
      "type" => "commonplace.reducer.operation",
      "version" => 1,
      "projection" => name,
      "epoch_id" => epoch_id,
      "operation" => operation(kind, by, tag)
    }
  end

  # The operation shape is chosen from the projection's plugin at ASSEMBLY
  # time, not generated independently, so a generated plan can never address a
  # counter with a passthrough operation.
  defp operation(:counter, by, _tag), do: %{"type" => "inc", "by" => by}
  defp operation(:passthrough, _by, tag), do: %{"tag" => tag}

  defp reducer_id(:counter), do: "fixture.counter"
  defp reducer_id(:passthrough), do: "fixture.passthrough"

  defp uuid(projection, n) do
    "0198d900-0000-7000-8000-" <> String.pad_leading("#{projection}#{n}", 12, "0")
  end

  # Numbers bodies into a well-formed single-writer chain from writer_seq 1.
  defp chain(bodies, stamps) do
    bodies
    |> Enum.with_index(1)
    |> Enum.map(fn {body, seq} ->
      %{
        "log_id" => @log,
        "entry_id" => entry_id(seq),
        "writer_id" => @writer,
        "writer_seq" => seq,
        "prev_entry_id" => if(seq > 1, do: entry_id(seq - 1)),
        "created_at" => Enum.at(stamps, seq - 1, "2026-08-22T00:00:00.0Z"),
        "body" => body
      }
    end)
  end

  defp entry_id(seq), do: "0198d901-0000-7000-8000-" <> String.pad_leading("#{seq}", 12, "0")

  defp entries(plan) do
    {bodies, _seen} = bodies(plan)
    chain(bodies, plan.stamps)
  end

  # -- running ----------------------------------------------------------------

  defp fresh do
    {:ok, state} = LogReducer.new(@log, FixturePlugin.registry())
    state
  end

  defp run(entries), do: LogReducer.reduce(fresh(), entries)

  defp run!(entries) do
    {:ok, state} = run(entries)
    state
  end

  # RFC 8785 canonical bytes (section 20). Never term equality.
  defp canon(term), do: Jcs.encode!(Conformance.json(term))

  defp views!(state) do
    {:ok, views} = LogReducer.views(state)
    views
  end

  defp checkpoint!(state) do
    {:ok, checkpoint} = LogReducer.checkpoint(state)
    checkpoint
  end

  # A projection's value and active epoch, without any coordinate. This is what
  # survives an insertion that shifts every later writer_seq.
  defp contents(state) do
    Map.new(views!(state), fn {name, view} ->
      {name, %{"value" => view.value, "epoch_id" => view.epoch_id}}
    end)
  end

  # -- generator health -------------------------------------------------------

  describe "generator health" do
    # Stated as tests and not as comments, because a generator that emits
    # nothing, emits garbage, or emits one case forever makes every property
    # below pass while proving nothing.
    property "a plan produces a non-empty chain of exactly the length asked for" do
      check all(plan <- plan(constant(10))) do
        entries = entries(plan)

        assert entries != []
        assert length(entries) == plan.count + 10
        assert Enum.map(entries, & &1["writer_seq"]) == Enum.to_list(1..length(entries))
      end
    end

    property "every generated sequence actually reduces" do
      check all(plan <- plan()) do
        assert {:ok, state} = run(entries(plan))
        assert %{writer_seq: seq} = State.head(state)
        assert seq == length(entries(plan))
        assert {:ok, _views} = LogReducer.views(state)
        assert {:ok, _checkpoint} = LogReducer.checkpoint(state)
      end
    end

    property "a generated sequence initializes every projection it names" do
      check all(plan <- plan()) do
        state = run!(entries(plan))
        assert Enum.sort(Map.keys(views!(state))) == Enum.sort(names(plan))
      end
    end

    test "different seeds produce different entry sets" do
      generator = plan()

      :rand.seed(:exsss, {1, 2, 3})
      first = generator |> Enum.take(20) |> Enum.map(&entries/1)

      :rand.seed(:exsss, {9, 8, 7})
      second = generator |> Enum.take(20) |> Enum.map(&entries/1)

      refute first == second, "the generator ignores its seed"

      # And it varies WITHIN one sample too: 20 draws that are all identical
      # would satisfy the assertion above by accident of seeding alone.
      assert length(Enum.uniq(first)) > 1, "the generator emits one case forever"
    end

    test "the generated corpus reaches every step kind and both plugins" do
      :rand.seed(:exsss, {4, 5, 6})
      plans = plan() |> Enum.take(200)

      kinds =
        plans
        |> Enum.flat_map(& &1.steps)
        |> Enum.map(&elem(&1, 0))
        |> Enum.uniq()
        |> Enum.sort()

      assert kinds == [:epoch, :op, :unrelated]
      assert Enum.sort(Enum.uniq(Enum.flat_map(plans, & &1.kinds))) == [:counter, :passthrough]
    end
  end

  # -- section 39, property 1 -------------------------------------------------

  property "full replay equals checkpoint restoration plus suffix replay" do
    check all(
            plan <- plan(),
            split <- integer(0..30)
          ) do
      entries = entries(plan)

      # 1..length, not 0..length: `checkpoint/1` on a state with no head is
      # `invalid_checkpoint`/`:no_head` (section 19 -- a checkpoint names the
      # exact log head it was taken at, and a fresh engine has none). A split
      # at 0 is therefore not a legal checkpoint point rather than a property
      # violation.
      split = 1 + rem(split, length(entries))
      {prefix, suffix} = Enum.split(entries, split)

      full = run!(entries)

      registry = FixturePlugin.registry()
      {:ok, partial} = run(prefix)
      {:ok, checkpoint} = LogReducer.checkpoint(partial)
      {:ok, restored} = LogReducer.restore(checkpoint, registry)
      {:ok, resumed} = LogReducer.reduce(restored, suffix)

      assert canon(Conformance.ok_shape(resumed)) == canon(Conformance.ok_shape(full))
    end
  end

  # -- section 39, property 2 -------------------------------------------------

  property "splitting input into arbitrary batches does not change the result" do
    check all(
            plan <- plan(),
            sizes <- list_of(integer(1..5), min_length: 1, max_length: 8)
          ) do
      entries = entries(plan)
      full = run!(entries)

      batched =
        entries
        |> batches(sizes)
        |> Enum.reduce(fresh(), fn batch, state ->
          {:ok, next} = LogReducer.reduce(state, batch)
          next
        end)

      assert canon(Conformance.ok_shape(batched)) == canon(Conformance.ok_shape(full))
    end
  end

  # Chops `entries` into batches whose sizes cycle through `sizes`, including
  # a trailing empty batch, which a caller can legitimately hand the engine.
  defp batches([], _sizes), do: [[]]

  defp batches(entries, sizes) do
    {batch, rest} = Enum.split(entries, hd(sizes))
    [batch | batches(rest, tl(sizes) ++ [hd(sizes)])]
  end

  # -- section 39, property 3 -------------------------------------------------

  property "unrelated entries do not change any projection view" do
    check all(
            plan <- plan(),
            extras <- list_of(tag(), min_length: 1, max_length: 6),
            positions <- list_of(integer(0..40), length: length(extras))
          ) do
      {bodies, _seen} = bodies(plan)
      plain = chain(bodies, plan.stamps)

      noisy_bodies = insert_unrelated(bodies, extras, positions)

      noisy =
        chain(noisy_bodies, plan.stamps ++ Enum.map(extras, fn _ -> "2026-08-22T00:00:00Z" end))

      assert length(noisy) == length(plain) + length(extras)

      # Value and active epoch only: an insertion shifts every later
      # writer_seq, so the shared head and each epoch_head legitimately move.
      assert canon(contents(run!(noisy))) == canon(contents(run!(plain)))
    end
  end

  defp insert_unrelated(bodies, extras, positions) do
    Enum.zip(extras, positions)
    |> Enum.reduce(bodies, fn {tag, position}, acc ->
      at = rem(position, length(acc) + 1)
      List.insert_at(acc, at, %{"type" => "app.unrelated", "tag" => tag})
    end)
  end

  # -- section 39, property 4 -------------------------------------------------

  property "projection A operations do not change projection B" do
    check all(
            plan <- plan(),
            plan.count >= 2,
            victim <- integer(0..(plan.count - 1))
          ) do
      {bodies, _seen} = bodies(plan)
      name = "p#{victim}"

      # Each of the victim's bodies is REPLACED IN PLACE by an unrelated body,
      # never removed, so every coordinate in the chain is identical between
      # the two runs. That is what lets this comparison include the head.
      masked =
        Enum.map(bodies, fn body ->
          if body["projection"] == name,
            do: %{"type" => "app.masked", "was" => name},
            else: body
        end)

      full = run!(chain(bodies, plan.stamps))
      without = run!(chain(masked, plan.stamps))

      assert Enum.sort(Map.keys(views!(without))) == Enum.sort(names(plan) -- [name])
      assert canon(Map.drop(views!(full), [name])) == canon(views!(without))
    end
  end

  # -- section 39, property 5 -------------------------------------------------

  property "deterministic replay produces byte-equivalent canonical views and checkpoints" do
    check all(plan <- plan()) do
      entries = entries(plan)

      first = run!(entries)
      second = run!(entries)

      assert canon(views!(first)) == canon(views!(second))
      assert canon(checkpoint!(first)) == canon(checkpoint!(second))

      # And a checkpoint round-trip is the same run again (section 42.6).
      {:ok, restored} = LogReducer.restore(checkpoint!(first), FixturePlugin.registry())
      assert canon(views!(restored)) == canon(views!(first))
      assert canon(checkpoint!(restored)) == canon(checkpoint!(first))
    end
  end

  # -- section 39, property 6 -------------------------------------------------

  @invalid_kinds [
    :duplicate_epoch,
    :stale_epoch,
    :projection_not_initialized,
    :invalid_reducer_envelope,
    :writer_gap
  ]

  property "reduction never advances past a failing entry" do
    check all(
            plan <- plan_with_replacement(),
            kind <- member_of(@invalid_kinds),
            stamp <- created_at()
          ) do
      entries = entries(plan)
      good = run!(entries)
      bad = invalid_entry(kind, plan, entries, stamp)

      assert {:error, %Error{} = error, prefix} = run(entries ++ [bad])
      assert error.code == kind
      assert error.writer_seq == bad["writer_seq"]

      # The head is exactly the last GOOD coordinate, and no projection moved.
      assert State.head(prefix) == State.head(good)

      assert State.head(prefix) == %{
               writer_seq: length(entries),
               entry_id: entry_id(length(entries))
             }

      assert canon(views!(prefix)) == canon(views!(good))
      assert canon(checkpoint!(prefix)) == canon(checkpoint!(good))
    end
  end

  # POSITIVE CONTROL for the property above, and the reason it is a separate
  # test: the property picks ONE kind per run, so a kind that stopped being
  # invalid -- an entry the engine now accepts -- would only redden if the
  # sampler happened to draw it. This walks all five deterministically against
  # one fixed history, so "the invalid entry is genuinely invalid, with the
  # section 21 code claimed for it" is checked on every run.
  test "every invalid-entry kind genuinely fails, with its own section 21 code" do
    plan = fixed_plan()
    entries = entries(plan)
    good = run!(entries)

    for kind <- @invalid_kinds do
      bad = invalid_entry(kind, plan, entries, "2026-08-22T00:00:00Z")

      assert {:error, %Error{} = error, prefix} = run(entries ++ [bad])
      assert error.code == kind, "expected #{kind}, got #{error.code}"
      assert State.head(prefix) == State.head(good)
      assert canon(views!(prefix)) == canon(views!(good))
    end
  end

  # A hand-written plan in the shape the generator emits, including the epoch
  # replacement that gives "p0" a retired epoch ID.
  defp fixed_plan do
    %{
      count: 2,
      kinds: [:counter, :passthrough],
      steps: [{:op, 0, 3, "a"}, {:unrelated, "n"}, {:op, 1, 0, "b"}, {:epoch, 0, 7}],
      stamps: List.duplicate("2026-08-22T00:00:00Z", 6)
    }
  end

  # One entry that MUST fail, appended after a valid history. The epoch
  # bookkeeping comes from the assembler, so `retired` really is an ID that
  # projection p0 has used and replaced.
  defp invalid_entry(kind, plan, entries, stamp) do
    {_bodies, seen} = bodies(plan)
    {active, _n} = Map.fetch!(seen, 0)
    retired = uuid(0, 0)
    seq = length(entries) + 1

    body =
      case kind do
        :duplicate_epoch ->
          epoch_body("p0", retired, active, Enum.at(plan.kinds, 0), 0)

        :stale_epoch ->
          operation_body("p0", retired, Enum.at(plan.kinds, 0), 1, "x")

        :projection_not_initialized ->
          operation_body("zz", active, Enum.at(plan.kinds, 0), 1, "x")

        :invalid_reducer_envelope ->
          %{"type" => "commonplace.reducer.operation"}

        :writer_gap ->
          %{"type" => "app.note", "tag" => "gap"}
      end

    %{
      "log_id" => @log,
      "entry_id" => entry_id(seq),
      "writer_id" => @writer,
      "writer_seq" => if(kind == :writer_gap, do: seq + 1, else: seq),
      "prev_entry_id" => entry_id(seq - 1),
      "created_at" => stamp,
      "body" => body
    }
  end

  # -- sections 20, 38.16, 42.4 -----------------------------------------------

  describe "created_at is not load-bearing" do
    property "shuffling created_at changes neither the views nor the checkpoint" do
      check all(
              plan <- plan(),
              shuffled <- permutation(plan.stamps)
            ) do
        original = run!(entries(plan))
        reshuffled = run!(entries(%{plan | stamps: shuffled}))

        assert canon(Conformance.ok_shape(reshuffled)) == canon(Conformance.ok_shape(original))
      end
    end

    property "shuffling created_at changes no failure coordinate either" do
      check all(
              plan <- plan_with_replacement(),
              kind <- member_of(@invalid_kinds),
              stamp <- created_at(),
              other <- created_at(),
              shuffled <- permutation(plan.stamps)
            ) do
        entries = entries(plan)
        bad = invalid_entry(kind, plan, entries, stamp)

        reshuffled = entries(%{plan | stamps: shuffled})
        also_bad = invalid_entry(kind, plan, reshuffled, other)

        assert {:error, %Error{} = first, prefix} = run(entries ++ [bad])
        assert {:error, %Error{} = second, other_prefix} = run(reshuffled ++ [also_bad])

        assert coordinate(first) == coordinate(second)
        assert canon(views!(prefix)) == canon(views!(other_prefix))
        assert canon(checkpoint!(prefix)) == canon(checkpoint!(other_prefix))
      end
    end
  end

  defp coordinate(%Error{} = error) do
    %{
      "code" => Atom.to_string(error.code),
      "writer_seq" => error.writer_seq,
      "entry_id" => error.entry_id,
      "projection" => error.projection
    }
  end
end
