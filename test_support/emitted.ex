defmodule Emitted do
  @moduledoc """
  Records which §21 error codes an assertion actually observed.

  Task 12 asserts every declared code is genuinely emitted by some test, not
  merely declared in the struct. A code that is declared but unproducible is a
  documented behaviour with no implementation.

  Introduced here, in the same task that declares the codes, so tasks 3/6/7/9
  can use it as they are written rather than being retrofitted later -- the
  retrofit is the version that quietly never happens.
  """
  def record(%{code: code} = err) do
    if :ets.whereis(:emitted_codes) != :undefined,
      do: :ets.insert(:emitted_codes, {code})

    err
  end

  def record(other), do: other
end
