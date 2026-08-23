defmodule Emitted do
  @moduledoc """
  Records which §21 error codes an assertion actually observed.

  Task 12 asserts every declared code is genuinely emitted by some test, not
  merely declared in the struct. A code that is declared but unproducible is a
  documented behaviour with no implementation.

  Introduced alongside the code declarations so tasks 3/6/7/9 can use it as
  they are written rather than being retrofitted later -- the retrofit is the
  version that quietly never happens.

  ## Why the table name is a parameter

  `record/2` takes the table so its own tests never touch the live
  `:emitted_codes` table. An earlier version hardcoded the name, and testing
  the table-absent branch meant deleting the real table mid-suite; once Task 12
  creates that table in `test_helper.exs`, that would silently no-op the
  recorder for every test that followed and leave the reachability gate red
  with an empty code set -- the exact failure this module exists to prevent.

  The obvious repair (recreate the table in `on_exit`) does not work and is
  worth recording: an ETS table is owned by the process that created it, and
  `on_exit` runs in a separate process that then exits, taking the table with
  it. Measured, not assumed -- a sentinel row inserted in `test_helper.exs` was
  still gone after the suite. Parameterising the name sidesteps the ownership
  problem entirely rather than fighting it.
  """

  @default_table :emitted_codes

  @doc "Record `err`'s code if `table` exists. Returns `err` unchanged, always."
  def record(err, table \\ @default_table)

  def record(%{code: code} = err, table) do
    if :ets.whereis(table) != :undefined, do: :ets.insert(table, {code})
    err
  end

  def record(other, _table), do: other

  @doc "The table Task 12's reachability gate accumulates into."
  def default_table, do: @default_table
end
