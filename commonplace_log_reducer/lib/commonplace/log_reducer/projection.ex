defmodule Commonplace.LogReducer.Projection do
  @moduledoc """
  One projection's slot in the engine state (section 14).

  A projection records the epoch that is currently active for it, every epoch
  ID it has ever seen (so a replayed epoch ID is `duplicate_epoch` rather than
  a silent reinstall), the resolved reducer identity and module, the plugin's
  opaque state, and the log coordinate at which the active epoch was installed.

  ## A projection epoch is not a log branch (section 40)

  An epoch is a *reset point for one projection's interpretation of one log*.
  It replaces the reducer identity and the base state a projection reduces
  from, at a stated coordinate in the one input log. It does not fork history,
  create a second lane of entries, or make any earlier entry unreachable: the
  log is still a single ordered single-writer sequence, and every entry before
  and after the epoch entry is still in it, in the same order.

  `parent_epoch_id` therefore chains epochs *within* a projection; it is not a
  branch point. Two projections in the same engine state can be on entirely
  different epochs (`epoch_id`) while sharing one head, because they are two
  readings of one history, not two histories. A durable branch of the log
  itself would be a different log id, which this engine rejects with
  `log_mismatch`.

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
