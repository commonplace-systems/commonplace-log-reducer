defmodule FixturePlugin do
  @moduledoc """
  A set of minimal, deterministic plugins used to exercise the engine without
  any real reducer.

  The engine (section 16) must be testable with no dependency on
  commonplace-attribute-map -- the package boundary of section 37.1 is a build
  graph fact, not a convention -- so these fixtures stand in for a real plugin.
  Three of them exist specifically to *fail*: `Rejector` refuses every
  operation (section 10.1.6, stop at the failing entry), `BaseRejector` refuses
  every base (section 9.1.5), and `NeedsResource` demands a resource that the
  context may not carry (section 13, the `missing_resource` code).

  Every fixture obeys section 12.1: it reports the exact ID and version it is
  registered under, validates its bases, operations, and checkpoints, and uses
  no wall-clock time, randomness, process identity, or I/O.
  """

  @doc "Every fixture module, for callers that want to iterate the set."
  def all do
    [
      FixturePlugin.Counter,
      FixturePlugin.Passthrough,
      FixturePlugin.Rejector,
      FixturePlugin.BaseRejector,
      FixturePlugin.NeedsResource
    ]
  end

  @doc "A registry map (section 11 shape) covering every fixture."
  def registry do
    Map.new(all(), fn module -> {{module.reducer_id(), module.reducer_version()}, module} end)
  end
end

defmodule FixturePlugin.Counter do
  @moduledoc """
  State is a single integer.

  Base is `%{"start" => integer}`; the only operation is
  `%{"type" => "inc", "by" => integer}`. The view is the integer itself and the
  checkpoint is `%{"count" => integer}`.
  """

  @behaviour Commonplace.LogReducer.Plugin

  import Kernel, except: [apply: 3]

  @impl true
  def reducer_id, do: "fixture.counter"

  @impl true
  def reducer_version, do: 1

  @impl true
  def init(%{"start" => start}, _context) when is_integer(start), do: {:ok, start}
  def init(base, _context), do: {:error, {:invalid_base, base}}

  @impl true
  def apply(%{"type" => "inc", "by" => by}, _context, state) when is_integer(by),
    do: {:ok, state + by}

  def apply(operation, _context, _state), do: {:error, {:invalid_operation, operation}}

  @impl true
  def view(state) when is_integer(state), do: {:ok, state}

  @doc """
  A plugin-defined operation over the state that is *not* an engine callback:
  what `Commonplace.LogReducer.plugin_call/4` exists to reach. Returns the
  count plus `n`, never the state itself.
  """
  def plus(state, n) when is_integer(state) and is_integer(n), do: {:ok, state + n}

  @impl true
  def checkpoint(state) when is_integer(state), do: {:ok, %{"count" => state}}

  @impl true
  def restore(%{"count" => count}, _context) when is_integer(count), do: {:ok, count}
  def restore(checkpoint, _context), do: {:error, {:invalid_checkpoint, checkpoint}}
end

defmodule FixturePlugin.Passthrough do
  @moduledoc """
  State is the list of operations applied so far, **most recent first**.

  Any JSON object is accepted as an operation; a non-object is refused, because
  section 12.1 forbids silently ignoring an addressed operation. The base must
  be an object and its content is ignored. The view is the list; the checkpoint
  is `%{"applied" => list}`.
  """

  @behaviour Commonplace.LogReducer.Plugin

  import Kernel, except: [apply: 3]

  @impl true
  def reducer_id, do: "fixture.passthrough"

  @impl true
  def reducer_version, do: 1

  @impl true
  def init(base, _context) when is_map(base), do: {:ok, []}
  def init(base, _context), do: {:error, {:invalid_base, base}}

  @impl true
  def apply(operation, _context, state) when is_map(operation) and is_list(state),
    do: {:ok, [operation | state]}

  def apply(operation, _context, _state), do: {:error, {:invalid_operation, operation}}

  @impl true
  def view(state) when is_list(state), do: {:ok, state}

  @impl true
  def checkpoint(state) when is_list(state), do: {:ok, %{"applied" => state}}

  @impl true
  def restore(%{"applied" => applied}, _context) when is_list(applied), do: {:ok, applied}
  def restore(checkpoint, _context), do: {:error, {:invalid_checkpoint, checkpoint}}
end

defmodule FixturePlugin.Rejector do
  @moduledoc """
  Initializes from any object base, then refuses every operation.

  Exists to drive section 10.1.6: the engine must stop at the failing entry and
  leave the head where it was.
  """

  @behaviour Commonplace.LogReducer.Plugin

  import Kernel, except: [apply: 3]

  @impl true
  def reducer_id, do: "fixture.rejector"

  @impl true
  def reducer_version, do: 1

  @impl true
  def init(base, _context) when is_map(base), do: {:ok, nil}
  def init(base, _context), do: {:error, {:invalid_base, base}}

  @impl true
  def apply(_operation, _context, _state), do: {:error, :always_refuses}

  @impl true
  def view(nil), do: {:ok, nil}

  @impl true
  def checkpoint(nil), do: {:ok, %{}}

  @impl true
  def restore(checkpoint, _context) when is_map(checkpoint), do: {:ok, nil}
  def restore(checkpoint, _context), do: {:error, {:invalid_checkpoint, checkpoint}}
end

defmodule FixturePlugin.BaseRejector do
  @moduledoc """
  Refuses every epoch base.

  Exists to drive section 9.1.5: a base the plugin rejects is
  `invalid_epoch_base`, and the projection must not become initialized.
  """

  @behaviour Commonplace.LogReducer.Plugin

  import Kernel, except: [apply: 3]

  @impl true
  def reducer_id, do: "fixture.base_rejector"

  @impl true
  def reducer_version, do: 1

  @impl true
  def init(_base, _context), do: {:error, :base_always_refused}

  @impl true
  def apply(_operation, _context, _state), do: {:error, :base_always_refused}

  @impl true
  def view(nil), do: {:ok, nil}

  @impl true
  def checkpoint(nil), do: {:ok, %{}}

  @impl true
  def restore(_checkpoint, _context), do: {:error, :base_always_refused}
end

defmodule FixturePlugin.NeedsResource do
  @moduledoc """
  Requires the immutable resource `"r"` in `context.resources`.

  Without it, `init/2` and `apply/3` return `{:error, {:missing_resource, "r"}}`
  -- never a fetch, per section 13 -- which the engine maps to the
  `missing_resource` code. With it, both succeed, so "correctly demands a
  resource" is distinguishable from "broken".

  `restore/2` does not require the resource: restoring a checkpoint is not
  reduction, and the engine may rehydrate before a caller supplies resources.

  State is the count of successfully applied operations.
  """

  @behaviour Commonplace.LogReducer.Plugin

  import Kernel, except: [apply: 3]

  @resource "r"

  @impl true
  def reducer_id, do: "fixture.needs_resource"

  @impl true
  def reducer_version, do: 1

  @impl true
  def init(base, context) do
    with :ok <- require_resource(context) do
      if is_map(base), do: {:ok, 0}, else: {:error, {:invalid_base, base}}
    end
  end

  @impl true
  def apply(operation, context, state) do
    with :ok <- require_resource(context) do
      if is_map(operation),
        do: {:ok, state + 1},
        else: {:error, {:invalid_operation, operation}}
    end
  end

  @impl true
  def view(state) when is_integer(state), do: {:ok, state}

  @impl true
  def checkpoint(state) when is_integer(state), do: {:ok, %{"applied" => state}}

  @impl true
  def restore(%{"applied" => applied}, _context) when is_integer(applied), do: {:ok, applied}
  def restore(checkpoint, _context), do: {:error, {:invalid_checkpoint, checkpoint}}

  defp require_resource(%Commonplace.LogReducer.Context{resources: resources}) do
    if Map.has_key?(resources, @resource),
      do: :ok,
      else: {:error, {:missing_resource, @resource}}
  end
end
