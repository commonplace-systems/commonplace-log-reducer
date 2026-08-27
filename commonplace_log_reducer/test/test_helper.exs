# The §21 code-reachability gate (Task 12).
#
# `Commonplace.LogReducer.Error` declares fifteen codes. A declared code that
# no test can actually provoke is a documented behaviour with no
# implementation -- and reading the declaration list proves only that someone
# typed it. Every assertion in these suites that observes an error passes it
# through `Emitted.record/1`, which drops the code into this table; after the
# suite we check the set is complete.
#
# The table is created here, in the process that owns the whole run, because
# an ETS table dies with its owner and every other candidate owner (a test
# process, an `on_exit` process) exits before the check would read it.
:ets.new(:emitted_codes, [:named_table, :public, :set])

# ---------------------------------------------------------------------------
# Why after_suite and not a test
# ---------------------------------------------------------------------------
#
# ExUnit randomizes order, so a "runs last" test does not. As an ordinary test
# this check would read a partly-filled table on most seeds and fail
# nondeterministically -- a gate that goes red on correct behaviour, which is
# worse than no gate at all.
#
# ## Why it is gated to full runs
#
# `mix test test/error_test.exs` legitimately emits a handful of codes. Firing
# there would be a false red on correct behaviour and would train the reader
# to ignore it. The gate therefore runs only when the suite that just ran was
# the whole suite, measured by test count against a recorded floor -- the same
# anti-vacuity idiom as `conformance/check.sh`. If you add tests, this floor
# only ever needs raising; if you remove enough tests to drop under it, the
# gate goes quiet, so the floor is stated rather than derived from the run.
#
# ## Why a failing suite skips it
#
# A red suite explains itself. A missing code after failures is a downstream
# symptom of the failures, and reporting it would bury the real cause.
full_suite_floor = 200

ExUnit.after_suite(fn %{total: total, failures: failures} = results ->
  # ExUnit's `total` COUNTS EXCLUDED AND SKIPPED TESTS. Measured 2026-08-27:
  # one excluded arm left `226 tests, 0 failures, 1 excluded` and this gate
  # certified a full run that had not happened. The floor must be compared
  # against what actually EXECUTED, which is total minus the two.
  # ARM DEMONSTRATED 2026-08-27: one @moduletag across engine_test and
  # conformance_test, excluded -> "183 of 237 tests executed, under the
  # 200-test floor". Before this subtraction the same run reported the total,
  # 237, cleared the floor, and certified "all 15 codes emitted by an
  # assertion in this run" with 54 arms never executed.
  # ⚠️ The first induction attempt UNDER-APPLIED and looked like a demo:
  # `exclude: [module: A, module: B, ...]` is a keyword list with duplicate
  # keys, so only ONE module was excluded (25 tests, executed 201, still over
  # the floor). Use one tag across several modules.
  executed = total - Map.get(results, :excluded, 0) - Map.get(results, :skipped, 0)
  expected = MapSet.new(Commonplace.LogReducer.Error.codes())
  emitted = :emitted_codes |> :ets.tab2list() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
  missing = MapSet.difference(expected, emitted) |> Enum.sort()

  cond do
    failures > 0 ->
      IO.puts("\n[§21 reachability] skipped: the suite is red, and that explains itself.")

    executed < full_suite_floor ->
      IO.puts(
        "\n[§21 reachability] skipped: #{executed} of #{total} tests executed, under the " <>
          "#{full_suite_floor}-test " <>
          "floor for a full run. A filtered run legitimately emits fewer than " <>
          "#{MapSet.size(expected)} codes."
      )

    missing == [] ->
      IO.puts(
        "\n[§21 reachability] OK: all #{MapSet.size(expected)} §21 codes were emitted by " <>
          "an assertion in this run."
      )

      IO.puts("""

      SELECTOR -- what this green run does NOT mean:
        Every §21 code is REACHABLE, not that every code is reached for every
        reason the specification allows, nor that the code a given entry gets
        is the right one -- that is what the per-code tests and the
        conformance corpus argue, case by case.

        §42.10 (the plugin boundary) is NOT argued by this suite. It has been
        demonstrated once, by one foreign plugin in an integration run
        (docs/42-10-PLUGIN-BOUNDARY.md). That is a boundary demonstration, not
        plugin GENERALITY: one more independent implementer is a strictly
        stronger test, and no suite written in this repository can supply one.
      """)

    true ->
      IO.puts(
        :stderr,
        "\n[§21 reachability] FAILED: #{length(missing)} declared §21 code(s) were never " <>
          "emitted by any assertion in this run:\n" <>
          Enum.map_join(missing, "\n", &"  * #{&1}") <>
          "\n\nEach is declared in Commonplace.LogReducer.Error but no test observed it. " <>
          "Either the code is unreachable, or nothing asserts on it."
      )

      # after_suite cannot fail the run by returning; the exit status is ours
      # to set, and a gate whose result does not change what happens next is
      # decoration.
      System.at_exit(fn _ -> exit({:shutdown, 1}) end)
  end

  results
end)

ExUnit.start()
