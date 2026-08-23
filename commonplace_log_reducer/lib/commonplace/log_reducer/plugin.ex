defmodule Commonplace.LogReducer.Plugin do
  @moduledoc """
  The reducer plugin behaviour of section 12.

  A plugin is the only place where projection-specific meaning lives. The
  engine knows epochs, ordering, and heads; it never knows what a base or an
  operation means. Everything in this module is a declaration: there are no
  default implementations and no `__using__` macro, so a plugin cannot
  accidentally inherit behaviour it did not write.

  Section 12.1 constrains conforming implementations. A plugin:

    * MUST return the exact reducer ID and version under which it is
      registered (`Commonplace.LogReducer.Registry.build/1` enforces this);
    * MUST validate every epoch base it initializes;
    * MUST validate every addressed operation;
    * MUST produce the same result for the same state, operation, context, and
      resources;
    * MUST NOT use wall-clock time, randomness, process identity, global
      mutable state, or network results as implicit reducer input;
    * MUST NOT silently ignore an operation addressed to it;
    * MUST return JSON-compatible views;
    * MUST return JSON-object checkpoints; and
    * MUST validate checkpoints before restoring them.

  Plugin state may be any immutable Elixir term. Only views and checkpoints
  cross the plugin boundary as durable or user-facing representations.

  A plugin that needs an external resource MUST return an explicit
  missing-resource error rather than fetch it (section 13); resource
  acquisition happens outside deterministic reduction.

  Note for implementers: `apply/3` collides with `Kernel.apply/3`. A plugin
  module must `import Kernel, except: [apply: 3]` before defining it.
  """

  @type json ::
          nil
          | boolean()
          | number()
          | String.t()
          | [json()]
          | %{optional(String.t()) => json()}

  @type state :: term()
  @type context :: Commonplace.LogReducer.Context.t()

  @callback reducer_id() :: String.t()
  @callback reducer_version() :: pos_integer()

  @callback init(base :: map(), context()) ::
              {:ok, state()} | {:error, term()}

  @callback apply(operation :: map(), context(), state()) ::
              {:ok, state()} | {:error, term()}

  @callback view(state()) ::
              {:ok, json()} | {:error, term()}

  @callback checkpoint(state()) ::
              {:ok, map()} | {:error, term()}

  @callback restore(checkpoint :: map(), context()) ::
              {:ok, state()} | {:error, term()}
end
