defmodule Commonplace.LogReducer.Projection do
  @moduledoc """
  One projection's slot in the engine state (section 14).

  A projection records the epoch that is currently active for it, every epoch
  ID it has ever seen (so a replayed epoch ID is `duplicate_epoch` rather than
  a silent reinstall), the resolved reducer identity and module, the plugin's
  opaque state, and the log coordinate at which the active epoch was installed.

  This module is data only. Installing an epoch and applying operations belong
  to the engine; nothing here calls a plugin.
  """

  @enforce_keys [
    :epoch_id,
    :reducer_id,
    :reducer_version,
    :module,
    :state,
    :epoch_entry_id,
    :epoch_writer_seq
  ]

  defstruct [
    :epoch_id,
    :reducer_id,
    :reducer_version,
    :module,
    :state,
    :epoch_entry_id,
    :epoch_writer_seq,
    seen_epoch_ids: MapSet.new()
  ]

  @type t :: %__MODULE__{
          epoch_id: String.t(),
          seen_epoch_ids: MapSet.t(String.t()),
          reducer_id: String.t(),
          reducer_version: pos_integer(),
          module: module(),
          state: term(),
          epoch_entry_id: String.t(),
          epoch_writer_seq: pos_integer()
        }
end
