defmodule JcsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Validates the test-only RFC 8785 canonicalizer against the inherited
  canonical-JSON corpus (specification section 20: "the conformance suite
  SHOULD serialize checkpoints and views using RFC 8785 canonical JSON when
  comparing runtimes or runs").

  ## The counts are literals, deliberately

  `@discovered`, `@must_match`, and `@must_mismatch` below are the counts
  MEASURED once against the corpus and then WRITTEN DOWN. They are not derived
  by walking the directory, because a floor derived from the thing it checks is
  not a floor: `assert length(cases) >= length(cases)` passes just as happily
  against a corpus that has silently lost half its cases -- or all of them.

  A renamed, deleted, or unmounted case therefore fails the COUNT assertion,
  which reads "the corpus shrank". A wrong canonical byte fails the COMPARISON
  assertion, which reads "my code regressed". Those two want opposite responses
  (go find the missing case / go fix the canonicalizer), so they are two
  distinct assertions on purpose.

  ## The two doors must not redden together

  The per-case comparison tests are GENERATED from the corpus at compile time.
  A removed case therefore generates no test at all -- it does not fail one --
  so removing a case reddens the count floor and nothing else. Measured, not
  assumed: see the door-1 and door-2 runs recorded in the commit message.

  That generation is also exactly why the floor is load-bearing rather than
  decorative. With no floor, deleting the entire corpus would generate zero
  comparison tests and the suite would go green over nothing.

  **General rule, and the reason the floor's message names its door:** an
  anti-vacuity floor placed INSIDE a comparison test reddens on door 1 while
  wearing door 2's label, and a reader then debugs a canonicalizer that is
  fine. Keep the floor -- it is what makes the comparisons non-vacuous -- but
  make it say which door it is.

  The walk filters to DIRECTORIES. A stray `README.md` beside the case
  directories is not a case and must not be counted as one; if such a file were
  counted, the floor would go red and the reader would hunt a missing case that
  is not missing.
  """

  @corpus Path.expand("../../conformance/canonical-json", __DIR__)

  # Measured against conformance/canonical-json, then stated as literals.
  @discovered 19
  @must_match 18
  @must_mismatch 1

  # The one case whose expected.hex is deliberately NOT the canonical form. It
  # is the corpus's own positive control: an instrument that reports every case
  # as matching is blind, and this case is what proves it is not.
  @mismatch_case "999-deliberate-mismatch"

  defp case_dirs do
    @corpus
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort()
  end

  # File.read! and not File.read: a swallowed {:error, :enoent} defaulting to
  # "" is exactly how a harness stops reading its corpus while staying green.
  defp read_case(dir) do
    input = File.read!(Path.join(dir, "input.json"))
    hex = dir |> Path.join("expected.hex") |> File.read!() |> String.trim()
    {input, Base.decode16!(hex, case: :lower)}
  end

  test "the corpus is present at the recorded size" do
    dirs = case_dirs()

    assert length(dirs) == @discovered,
           "corpus floor: expected #{@discovered} cases, found #{length(dirs)}. " <>
             "Every case that RAN passed or failed on its own, so this is DOOR 1 " <>
             "(the corpus shrank), not door 2 (the canonicalizer regressed). " <>
             "Restore the missing case; do not investigate Jcs. Found: " <>
             inspect(Enum.map(dirs, &Path.basename/1))

    names = Enum.map(dirs, &Path.basename/1)

    assert @mismatch_case in names,
           "the deliberate-mismatch control is missing from the corpus"

    matching = Enum.reject(names, &String.starts_with?(&1, "9"))
    mismatching = Enum.filter(names, &String.starts_with?(&1, "9"))

    assert length(matching) == @must_match
    assert length(mismatching) == @must_mismatch
  end

  test "every case directory carries both files" do
    for dir <- case_dirs() do
      assert File.regular?(Path.join(dir, "input.json")), "#{dir}: no input.json"
      assert File.regular?(Path.join(dir, "expected.hex")), "#{dir}: no expected.hex"
    end
  end

  for dir <- Path.wildcard(Path.join(@corpus, "*")), File.dir?(dir) do
    name = Path.basename(dir)

    if String.starts_with?(name, "9") do
      test "#{name} MISMATCHES its expected bytes (the corpus's own control)" do
        {input, expected} = read_case(Path.join(@corpus, unquote(name)))
        actual = input |> Jason.decode!() |> Jcs.encode!()

        refute actual == expected,
               "#{unquote(name)} is the deliberate mismatch and must not match; " <>
                 "if it does, the corpus or the comparison is broken"
      end
    else
      test "#{name} canonicalizes to its expected bytes" do
        {input, expected} = read_case(Path.join(@corpus, unquote(name)))
        actual = input |> Jason.decode!() |> Jcs.encode!()

        assert actual == expected,
               "#{unquote(name)}\n  expected: #{inspect(expected, limit: :infinity)}\n" <>
                 "  actual:   #{inspect(actual, limit: :infinity)}"
      end
    end
  end

  describe "round-trip" do
    test "canonical output re-decodes to the same value" do
      value = %{"b" => [1, 2.5, nil], "a" => %{"z" => true}, "€" => "ok"}
      assert value |> Jcs.encode!() |> Jason.decode!() == value
    end

    test "encoding is idempotent" do
      value = %{"b" => 1, "a" => %{"c" => [1.0e30, 1.0e-7]}}
      once = Jcs.encode!(value)
      assert once |> Jason.decode!() |> Jcs.encode!() == once
    end
  end
end
