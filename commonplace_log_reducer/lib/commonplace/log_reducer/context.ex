defmodule Commonplace.LogReducer.Context do
  @moduledoc """
  The reducer context of section 13.

  The engine supplies one of these to every plugin callback. It is plain data:
  the spec states the context contains **no ambient authority**, so no field
  here holds a pid, a function, a module, or anything else callable. A plugin
  that receives a context cannot use it to reach the engine, the log, the
  network, or the clock -- it can only read the coordinate it is reducing at.

  `resources` is a caller-supplied map of immutable resource identifiers to
  already-resolved bytes or JSON values. Resource acquisition happens outside
  deterministic reduction; a plugin that finds a resource absent MUST return an
  explicit missing-resource error rather than fetch it itself. It defaults to
  the empty map: the common case is a reducer that requires no external
  resources at all.
  """

  defstruct [
    :log_id,
    :writer_id,
    :writer_seq,
    :entry_id,
    :projection,
    :epoch_id,
    :reducer_id,
    :reducer_version,
    resources: %{}
  ]

  @type t :: %__MODULE__{
          log_id: term(),
          writer_id: term(),
          writer_seq: term(),
          entry_id: term(),
          projection: term(),
          epoch_id: term(),
          reducer_id: term(),
          reducer_version: term(),
          resources: %{optional(String.t()) => term()}
        }
end
