defmodule Commonplace.LogReducer.PluginTest do
  use ExUnit.Case, async: true

  alias Commonplace.LogReducer.Context
  alias Commonplace.LogReducer.Plugin
  alias Commonplace.LogReducer.Registry

  defp context(resources \\ %{}) do
    %Context{
      log_id: "log-1",
      writer_id: "writer-1",
      writer_seq: 1,
      entry_id: "entry-1",
      projection: "fixture",
      epoch_id: "epoch-1",
      reducer_id: "fixture.counter",
      reducer_version: 1,
      resources: resources
    }
  end

  describe "the behaviour module" do
    test "declares exactly the seven section 12 callbacks and no implementations" do
      declared = Plugin.behaviour_info(:callbacks) |> Enum.sort()

      assert declared ==
               Enum.sort(
                 reducer_id: 0,
                 reducer_version: 0,
                 init: 2,
                 apply: 3,
                 view: 1,
                 checkpoint: 1,
                 restore: 2
               )

      # No default implementations and no __using__ macro: a plugin must write
      # every callback itself.
      assert Plugin.behaviour_info(:optional_callbacks) == []
      refute function_exported?(Plugin, :__using__, 1)
      refute macro_exported?(Plugin, :__using__, 1)
    end

    test "the registry's required callbacks are the behaviour's callbacks" do
      assert Enum.sort(Registry.required_callbacks()) ==
               Enum.sort(Plugin.behaviour_info(:callbacks))
    end
  end

  describe "the context (section 13)" do
    test "defaults resources to the empty map" do
      assert %Context{}.resources == %{}
    end

    test "carries every section 13 field" do
      expected = [
        :log_id,
        :writer_id,
        :writer_seq,
        :entry_id,
        :projection,
        :epoch_id,
        :reducer_id,
        :reducer_version,
        :resources
      ]

      assert Enum.sort(Map.keys(Map.from_struct(%Context{}))) == Enum.sort(expected)
    end

    test "contains no ambient authority: every field of a live context is plain data" do
      ctx = context(%{"r" => %{"bytes" => "abc"}})

      for {field, value} <- Map.from_struct(ctx) do
        refute is_pid(value), "#{field} holds a pid"
        refute is_port(value), "#{field} holds a port"
        refute is_reference(value), "#{field} holds a reference"
        refute is_function(value), "#{field} holds a function"
      end
    end
  end

  describe "the fixture set" do
    test "is non-empty and every fixture exports all seven callbacks" do
      fixtures = FixturePlugin.all()

      # Assert non-emptiness FIRST: a loop over [] passes vacuously and is
      # indistinguishable from a real pass.
      assert length(fixtures) == 5, "expected five fixtures, got #{inspect(fixtures)}"

      for module <- fixtures, {fun, arity} <- Plugin.behaviour_info(:callbacks) do
        assert Code.ensure_loaded?(module)

        assert function_exported?(module, fun, arity),
               "#{inspect(module)} does not export #{fun}/#{arity}"
      end
    end

    test "every fixture declares the plugin behaviour" do
      fixtures = FixturePlugin.all()
      assert length(fixtures) > 0

      for module <- fixtures do
        behaviours =
          module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

        assert Plugin in behaviours, "#{inspect(module)} is not a @behaviour Plugin"
      end
    end

    test "fixture ids are distinct" do
      ids = Enum.map(FixturePlugin.all(), & &1.reducer_id())
      assert length(ids) > 0
      assert Enum.uniq(ids) == ids
    end

    test "Registry.build/1 accepts a registry of all five fixtures (section 12.1 identity)" do
      registry = FixturePlugin.registry()
      assert map_size(registry) == 5

      assert {:ok, built} = Registry.build(registry)

      for {{id, version}, module} <- registry do
        assert {:ok, ^module} = Registry.resolve(built, id, version)
      end
    end
  end

  describe "FixturePlugin.Counter" do
    test "round-trips init -> apply -> view -> checkpoint -> restore -> same view" do
      ctx = context()

      m = FixturePlugin.Counter

      assert {:ok, state} = m.init(%{"start" => 5}, ctx)
      assert {:ok, state} = m.apply(%{"type" => "inc", "by" => 3}, ctx, state)
      assert {:ok, state} = m.apply(%{"type" => "inc", "by" => -1}, ctx, state)
      assert {:ok, 7} = m.view(state)

      assert {:ok, %{"count" => 7} = cp} = m.checkpoint(state)
      assert {:ok, restored} = m.restore(cp, ctx)
      assert m.view(restored) == m.view(state)
    end

    test "validates its base and its operations (section 12.1)" do
      ctx = context()
      m = FixturePlugin.Counter

      assert {:error, {:invalid_base, _}} = m.init(%{}, ctx)
      assert {:error, {:invalid_base, _}} = m.init(%{"start" => "5"}, ctx)

      assert {:ok, 0} = m.init(%{"start" => 0}, ctx)
      assert {:error, {:invalid_operation, _}} = m.apply(%{"type" => "dec"}, ctx, 0)
      assert {:error, {:invalid_operation, _}} = m.apply(%{"type" => "inc"}, ctx, 0)
    end

    test "validates checkpoints before restoring them (section 12.1)" do
      ctx = context()
      m = FixturePlugin.Counter

      assert {:error, {:invalid_checkpoint, _}} = m.restore(%{}, ctx)
      assert {:error, {:invalid_checkpoint, _}} = m.restore(%{"count" => "7"}, ctx)
    end
  end

  describe "FixturePlugin.Passthrough" do
    test "records applied operations most recent first and round-trips" do
      ctx = context()
      m = FixturePlugin.Passthrough

      assert {:ok, state} = m.init(%{}, ctx)
      assert {:ok, state} = m.apply(%{"n" => 1}, ctx, state)
      assert {:ok, state} = m.apply(%{"n" => 2}, ctx, state)

      assert {:ok, [%{"n" => 2}, %{"n" => 1}]} = m.view(state)

      assert {:ok, cp} = m.checkpoint(state)
      assert cp == %{"applied" => [%{"n" => 2}, %{"n" => 1}]}
      assert {:ok, restored} = m.restore(cp, ctx)
      assert m.view(restored) == m.view(state)
    end

    test "refuses a non-object operation rather than ignoring it (section 12.1)" do
      ctx = context()
      m = FixturePlugin.Passthrough
      assert {:error, {:invalid_operation, _}} = m.apply("not-an-object", ctx, [])
      assert {:error, {:invalid_checkpoint, _}} = m.restore(%{"applied" => "nope"}, ctx)
    end
  end

  describe "the refusing fixtures" do
    # These exist to PRODUCE failures for tasks 6/7. A fixture that silently
    # succeeded would make those failure tests pass for the wrong reason, so
    # each refusal is asserted here at its source.

    test "Rejector initializes but refuses every operation (section 10.1.6)" do
      ctx = context()
      m = FixturePlugin.Rejector

      assert {:ok, state} = m.init(%{"anything" => true}, ctx)
      assert {:error, :always_refuses} = m.apply(%{"type" => "inc"}, ctx, state)
      assert {:error, :always_refuses} = m.apply(%{}, ctx, state)
      assert {:error, :always_refuses} = m.apply(%{"other" => 1}, ctx, nil)
    end

    test "BaseRejector refuses every base (section 9.1.5)" do
      ctx = context()
      m = FixturePlugin.BaseRejector

      assert {:error, :base_always_refused} = m.init(%{}, ctx)
      assert {:error, :base_always_refused} = m.init(%{"start" => 1}, ctx)
      assert {:error, :base_always_refused} = m.restore(%{}, ctx)
    end

    test "NeedsResource refuses init and apply when the resource is absent" do
      ctx = context(%{})
      m = FixturePlugin.NeedsResource

      assert {:error, {:missing_resource, "r"}} = m.init(%{}, ctx)
      assert {:error, {:missing_resource, "r"}} = m.apply(%{}, ctx, 0)

      # A different resource is not the required one.
      other = context(%{"s" => 1})
      assert {:error, {:missing_resource, "r"}} = m.init(%{}, other)
    end

    test "NeedsResource succeeds when the resource IS present (not simply broken)" do
      ctx = context(%{"r" => %{"value" => 1}})
      m = FixturePlugin.NeedsResource

      assert {:ok, 0} = m.init(%{}, ctx)
      assert {:ok, 1} = m.apply(%{"op" => "x"}, ctx, 0)
      assert {:ok, 1} = m.view(1)
      assert {:ok, cp} = m.checkpoint(1)
      assert cp == %{"applied" => 1}
      assert {:ok, 1} = m.restore(cp, ctx)
    end
  end
end
