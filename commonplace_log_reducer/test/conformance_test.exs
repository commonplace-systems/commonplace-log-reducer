defmodule ConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Runs `conformance/reducer-engine`, the shared language-neutral corpus of
  specification section 38, against this engine.

  ## The counts are literals, deliberately

  `@discovered`, `@must_match`, and `@must_mismatch` were MEASURED once against
  the corpus and then WRITTEN DOWN. They are not derived by walking the
  directory, because a floor derived from the thing it checks is not a floor:
  `assert length(cases) >= length(cases)` passes just as happily against a
  corpus that has silently lost half its cases -- or all of them.

  ## Two doors, and they must not redden together

  A renamed, deleted, or unmounted case fails the COUNT assertion, which reads
  "the corpus shrank". A wrong byte in an `expected.json` fails a COMPARISON
  assertion, which reads "the implementation regressed". Those want opposite
  responses -- go find the missing case, versus go fix the engine -- so they
  are separate tests on purpose, and the floor's message names its own door.

  An anti-vacuity floor placed INSIDE a comparison test reddens on door 1 while
  wearing door 2's label, and a reader then debugs an engine that is fine. The
  floor stays in its own test. It is what makes the comparisons non-vacuous:
  the per-case tests are GENERATED from the corpus at compile time, so a
  deleted case generates no test at all rather than failing one, and with no
  floor an empty corpus would be a green suite over nothing.

  The walk filters to DIRECTORIES. A stray `README.md` is not a case.

  ## What this corpus does NOT prove

  See `conformance/README.md`: every plugin exercised here shares an author
  with the engine, so section 42.10 -- an independently written plugin
  implementing the same behaviour without changing the core API -- is NOT
  validated by a green run.
  """

  @corpus Path.expand("../../conformance/reducer-engine", __DIR__)

  # Measured against conformance/reducer-engine, then stated as literals.
  @discovered 20
  @must_match 19
  @must_mismatch 1

  # The 16 section 38 engine cases occupy 001..017: case 16 ("changing
  # created_at alone does not change reducer semantics") is a PAIR of inputs,
  # so it needs two directories.
  @created_at_pair {"016-created-at-alone-changes-nothing-a",
                    "017-created-at-alone-changes-nothing-b"}

  # Beyond section 38: commonplace-log entry version 2 persists a durable
  # `operation_id` as a top-level ENTRY field. The engine reads only its six
  # required keys, so the field must change nothing. A pair, like case 16.
  @operation_id_pair {"018-operation-id-alone-changes-nothing-a",
                      "019-operation-id-alone-changes-nothing-b"}

  # Corpus fixture keys -> modules. The corpus never names an Elixir module
  # (section 11); this table is the only place the mapping exists, and it is
  # trusted code configuration (section 22).
  @plugins %{
    "counter" => FixturePlugin.Counter,
    "passthrough" => FixturePlugin.Passthrough,
    "rejector" => FixturePlugin.Rejector,
    "base-rejector" => FixturePlugin.BaseRejector,
    "needs-resource" => FixturePlugin.NeedsResource
  }

  test "DOOR 1: the corpus is present at the recorded size" do
    dirs = Conformance.case_dirs(@corpus)

    assert length(dirs) == @discovered,
           "corpus floor: expected #{@discovered} cases, found #{length(dirs)}. " <>
             "Every case that RAN passed or failed on its own, so this is DOOR 1 " <>
             "(the corpus shrank), not door 2 (the engine regressed). Restore the " <>
             "missing case; do not investigate Commonplace.LogReducer. Found: " <>
             inspect(Enum.map(dirs, &Path.basename/1))

    names = Enum.map(dirs, &Path.basename/1)

    matching = Enum.reject(names, &String.starts_with?(&1, "9"))
    mismatching = Enum.filter(names, &String.starts_with?(&1, "9"))

    assert length(matching) == @must_match,
           "DOOR 1: expected #{@must_match} pass-gate cases, found #{length(matching)}"

    assert length(mismatching) == @must_mismatch,
           "DOOR 1: expected #{@must_mismatch} deliberate-mismatch (9xx) control, " <>
             "found #{length(mismatching)}. Without it, an instrument that reports " <>
             "every case as matching would look healthy."

    {pair_a, pair_b} = @created_at_pair

    assert pair_a in names and pair_b in names,
           "DOOR 1: the created_at pair is incomplete: #{inspect(@created_at_pair)}"

    {op_a, op_b} = @operation_id_pair

    assert op_a in names and op_b in names,
           "DOOR 1: the operation_id pair is incomplete: #{inspect(@operation_id_pair)}"
  end

  test "every case directory carries both files" do
    for dir <- Conformance.case_dirs(@corpus) do
      assert File.regular?(Path.join(dir, "input.json")), "#{dir}: no input.json"
      assert File.regular?(Path.join(dir, "expected.json")), "#{dir}: no expected.json"
    end
  end

  test "every vector states a complete input and a complete expectation" do
    for dir <- Conformance.case_dirs(@corpus) do
      {input, expected} = Conformance.read_case(dir)
      name = Path.basename(dir)

      for field <- ["log_id", "registry", "entries"] do
        assert Map.has_key?(input, field), "#{name}: input.json has no #{field}"
      end

      assert input["entries"] != [], "#{name}: input.json has no entries"

      case expected do
        %{"ok" => ok} ->
          for field <- ["head", "projections", "views", "checkpoint"] do
            assert Map.has_key?(ok, field), "#{name}: expected ok has no #{field}"
          end

        %{"error" => error} ->
          for field <- ["code", "writer_seq", "entry_id", "head"] do
            assert Map.has_key?(error, field), "#{name}: expected error has no #{field}"
          end

        other ->
          flunk("#{name}: expected.json is neither ok nor error: #{inspect(Map.keys(other))}")
      end
    end
  end

  for dir <- Conformance.case_dirs(Path.expand("../../conformance/reducer-engine", __DIR__)) do
    name = Path.basename(dir)

    if String.starts_with?(name, "9") do
      test "#{name} MISMATCHES its expectation (the corpus's own control)" do
        {input, expected} = Conformance.read_case(Path.join(@corpus, unquote(name)))
        actual = Conformance.actual(expected, Conformance.run(input, @plugins))

        refute Conformance.canonical(actual) == Conformance.canonical(expected),
               "#{unquote(name)} is the deliberate mismatch and must not match; " <>
                 "if it does, the corpus or the comparison is broken"
      end
    else
      test "#{name} reduces to its expectation" do
        {input, expected} = Conformance.read_case(Path.join(@corpus, unquote(name)))
        result = Conformance.run(input, @plugins)
        actual = Conformance.actual(expected, result)

        assert Conformance.canonical(actual) == Conformance.canonical(expected),
               "DOOR 2 (#{unquote(name)}): the engine regressed, or the vector is " <>
                 "wrong.\n  expected: #{Conformance.canonical(expected)}\n" <>
                 "  actual:   #{Conformance.canonical(actual)}"

        # Section 42.6/42.7, asserted on every succeeding case rather than only
        # the two that are named for it: a checkpoint that cannot be restored
        # into the same views is a checkpoint that will be discovered broken on
        # the next restart, not on the next test run.
        with {:ok, state} <- result do
          restored = Conformance.round_trip(state, input, @plugins)

          assert Conformance.canonical(Conformance.ok_shape(restored)) ==
                   Conformance.canonical(Conformance.ok_shape(state)),
                 "DOOR 2 (#{unquote(name)}): checkpoint round-trip changed the state"
        end

        if split_at = input["split_at"] do
          split = Conformance.split_run(input, @plugins, split_at)
          split_actual = Conformance.actual(expected, split)

          assert Conformance.canonical(split_actual) == Conformance.canonical(expected),
                 "DOOR 2 (#{unquote(name)}): checkpoint at #{split_at} plus suffix " <>
                   "did not equal full replay"
        end
      end
    end
  end

  test "changing created_at alone changes nothing (section 38 case 16)" do
    {name_a, name_b} = @created_at_pair
    {input_a, expected_a} = Conformance.read_case(Path.join(@corpus, name_a))
    {input_b, expected_b} = Conformance.read_case(Path.join(@corpus, name_b))

    created_a = Enum.map(input_a["entries"], & &1["created_at"])
    created_b = Enum.map(input_b["entries"], & &1["created_at"])

    refute created_a == created_b,
           "positive control: the pair must actually differ in created_at, or this " <>
             "test proves nothing"

    strip = fn input ->
      update_in(input["entries"], fn entries ->
        Enum.map(entries, &Map.delete(&1, "created_at"))
      end)
    end

    assert Conformance.canonical(strip.(input_a)) == Conformance.canonical(strip.(input_b)),
           "the pair must be identical apart from created_at"

    assert Conformance.canonical(expected_a) == Conformance.canonical(expected_b),
           "the pair must state the same expectation"

    actual_a = Conformance.actual(expected_a, Conformance.run(input_a, @plugins))
    actual_b = Conformance.actual(expected_b, Conformance.run(input_b, @plugins))

    assert Conformance.canonical(actual_a) == Conformance.canonical(actual_b),
           "created_at is advisory (sections 6, 20) and must not reach any result"
  end

  test "operation_id alone changes nothing (entry version 2)" do
    {name_a, name_b} = @operation_id_pair
    {input_a, expected_a} = Conformance.read_case(Path.join(@corpus, name_a))
    {input_b, expected_b} = Conformance.read_case(Path.join(@corpus, name_b))

    ids_a = Enum.map(input_a["entries"], & &1["operation_id"])
    ids_b = Enum.map(input_b["entries"], & &1["operation_id"])

    refute ids_a == ids_b,
           "positive control: the pair must actually differ in operation_id, or this " <>
             "test proves nothing"

    assert Enum.all?(input_a["entries"], &(&1["version"] == 2 and is_binary(&1["operation_id"]))),
           "side a must be all entry version 2, each carrying operation_id (required in v2)"

    # Side b is a MIXED lane: version-2 entries beside one version-1 entry that
    # has no operation_id. That is the honest "absent" case -- in v2 the field
    # is required (jes, 2026-08-25T19:48Z), so absent-in-v2 is malformed at
    # the log's gate, not a shape this corpus may call valid.
    versions_b = Enum.map(input_b["entries"], & &1["version"])

    assert 1 in versions_b and 2 in versions_b,
           "side b must mix entry versions 1 and 2, or absent-vs-present is not exercised"

    assert Enum.all?(input_b["entries"], fn e ->
             case e["version"] do
               2 -> is_binary(e["operation_id"])
               1 -> not Map.has_key?(e, "operation_id")
             end
           end),
           "side b: every v2 entry carries operation_id and every v1 entry lacks it"

    strip = fn input ->
      update_in(input["entries"], fn entries ->
        Enum.map(entries, &Map.drop(&1, ["operation_id", "version"]))
      end)
    end

    assert Conformance.canonical(strip.(input_a)) == Conformance.canonical(strip.(input_b)),
           "the pair must be identical apart from operation_id and entry version"

    assert Conformance.canonical(expected_a) == Conformance.canonical(expected_b),
           "the pair must state the same expectation"

    actual_a = Conformance.actual(expected_a, Conformance.run(input_a, @plugins))
    actual_b = Conformance.actual(expected_b, Conformance.run(input_b, @plugins))

    assert Conformance.canonical(actual_a) == Conformance.canonical(actual_b),
           "operation_id is the host's (commonplace-log Amendment 2) and must not reach any result"

    refute inspect(actual_a) =~ "operation_id",
           "operation_id leaked into a view or checkpoint"
  end
end
