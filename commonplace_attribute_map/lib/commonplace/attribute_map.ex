defmodule Commonplace.AttributeMap do
  @moduledoc """
  commonplace-attribute-map: the smallest useful reducer plugin for
  commonplace-log-reducer.

  This module is a thin facade over the current protocol version. It exists so
  a host can register the plugin without hard-coding the version-specific
  module name, and so the durable identity of section 23 has one place to be
  read from:

      {:ok, registry} = Commonplace.LogReducer.Registry.build(
        Commonplace.AttributeMap.registry_entries()
      )

  There is no state, no process, and no persistence here. All reducer
  behaviour lives in `Commonplace.AttributeMap.V1`; see that module and
  `Commonplace.AttributeMap.Validation`.

  Note that `default_projection/0` is a *default*, not a constraint. The
  projection name is chosen by whoever writes the epoch entry (spec section 7);
  this reducer never inspects it.
  """

  alias Commonplace.AttributeMap.V1

  @doc "The durable reducer ID (section 23)."
  @spec reducer_id() :: String.t()
  def reducer_id, do: V1.reducer_id()

  @doc "The current reducer protocol version (section 23)."
  @spec reducer_version() :: pos_integer()
  def reducer_version, do: V1.reducer_version()

  @doc "The conventional projection name for this reducer (section 23)."
  @spec default_projection() :: String.t()
  def default_projection, do: "attributes"

  @doc "The plugin module implementing the current protocol version."
  @spec plugin() :: module()
  def plugin, do: V1

  @doc """
  Registry entries for every protocol version this package implements, ready
  to merge into a host's `Commonplace.LogReducer.Registry.build/1` map.
  """
  @spec registry_entries() :: %{{String.t(), pos_integer()} => module()}
  def registry_entries, do: %{{V1.reducer_id(), V1.reducer_version()} => V1}
end
