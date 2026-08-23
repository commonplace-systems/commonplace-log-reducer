defmodule Commonplace.LogReducer.RegistryTest do
  use ExUnit.Case, async: true

  alias Commonplace.LogReducer.Error
  alias Commonplace.LogReducer.Registry

  defmodule Conforming do
    import Kernel, except: [apply: 3]

    def reducer_id, do: "test.conforming"
    def reducer_version, do: 1
    def init(_base, _context), do: {:ok, %{}}
    def apply(_operation, _context, state), do: {:ok, state}
    def view(_state), do: {:ok, %{}}
    def checkpoint(_state), do: {:ok, %{}}
    def restore(_checkpoint, _context), do: {:ok, %{}}
  end

  defmodule ConformingV2 do
    import Kernel, except: [apply: 3]

    def reducer_id, do: "test.conforming"
    def reducer_version, do: 2
    def init(_base, _context), do: {:ok, %{}}
    def apply(_operation, _context, state), do: {:ok, state}
    def view(_state), do: {:ok, %{}}
    def checkpoint(_state), do: {:ok, %{}}
    def restore(_checkpoint, _context), do: {:ok, %{}}
  end

  defmodule NotAPlugin do
    import Kernel, except: [apply: 3]

    def reducer_id, do: "test.not-a-plugin"
    def reducer_version, do: 1
  end

  defmodule LiesAboutId do
    import Kernel, except: [apply: 3]

    def reducer_id, do: "test.some-other-id"
    def reducer_version, do: 1
    def init(_base, _context), do: {:ok, %{}}
    def apply(_operation, _context, state), do: {:ok, state}
    def view(_state), do: {:ok, %{}}
    def checkpoint(_state), do: {:ok, %{}}
    def restore(_checkpoint, _context), do: {:ok, %{}}
  end

  defmodule LiesAboutVersion do
    import Kernel, except: [apply: 3]

    def reducer_id, do: "test.lies-about-version"
    def reducer_version, do: 7
    def init(_base, _context), do: {:ok, %{}}
    def apply(_operation, _context, state), do: {:ok, state}
    def view(_state), do: {:ok, %{}}
    def checkpoint(_state), do: {:ok, %{}}
    def restore(_checkpoint, _context), do: {:ok, %{}}
  end

  defp registry! do
    {:ok, registry} =
      Registry.build(%{
        {"test.conforming", 1} => Conforming,
        {"test.conforming", 2} => ConformingV2
      })

    registry
  end

  test "resolves a registered {id, version} to its module" do
    registry = registry!()

    assert {:ok, Conforming} = Registry.resolve(registry, "test.conforming", 1)
    assert {:ok, ConformingV2} = Registry.resolve(registry, "test.conforming", 2)
  end

  test "an unregistered id yields unknown_reducer" do
    registry = registry!()

    assert {:error, %Error{code: :unknown_reducer} = err} =
             Registry.resolve(registry, "test.never-registered", 1)

    Emitted.record(err)
    assert err.details.reducer_id == "test.never-registered"
    assert err.details.reducer_version == 1
  end

  test "a registered id at an unregistered version yields unknown_reducer, never a fallback" do
    registry = registry!()

    assert {:error, %Error{code: :unknown_reducer} = err} =
             Registry.resolve(registry, "test.conforming", 3)

    Emitted.record(err)
    assert err.details.reducer_version == 3
  end

  test "resolution never converts a string to an atom" do
    registry = registry!()
    name = "definitely.not.a.reducer.zzz"

    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    assert {:error, %Error{code: :unknown_reducer} = err} = Registry.resolve(registry, name, 1)
    Emitted.record(err)
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  test "a module that does not implement the behaviour is rejected at build time" do
    assert {:error, {:invalid_registry, [reason]}} =
             Registry.build(%{{"test.not-a-plugin", 1} => NotAPlugin})

    assert {{"test.not-a-plugin", 1}, {:missing_callbacks, missing}} = reason
    assert Enum.sort(missing) == Enum.sort(init: 2, apply: 3, view: 1, checkpoint: 1, restore: 2)
  end

  test "a plugin whose reducer_id/0 disagrees with its registry key is rejected at build" do
    assert {:error, {:invalid_registry, [reason]}} =
             Registry.build(%{{"test.lies-about-id", 1} => LiesAboutId})

    assert {{"test.lies-about-id", 1},
            {:reducer_id_mismatch, %{registered: "test.lies-about-id", reported: _}}} = reason
  end

  test "a plugin whose reducer_version/0 disagrees with its registry key is rejected at build" do
    assert {:error, {:invalid_registry, [reason]}} =
             Registry.build(%{{"test.lies-about-version", 1} => LiesAboutVersion})

    assert {{"test.lies-about-version", 1},
            {:reducer_version_mismatch, %{registered: 1, reported: 7}}} = reason
  end

  test "malformed registry keys are rejected at build time" do
    assert {:error, {:invalid_registry, [{"test.conforming", :not_a_reducer_key}]}} =
             Registry.build(%{"test.conforming" => Conforming})

    assert {:error, {:invalid_registry, [{{"test.conforming", 0}, :not_a_reducer_key}]}} =
             Registry.build(%{{"test.conforming", 0} => Conforming})
  end

  test "a non-map registry is rejected" do
    assert {:error, {:invalid_registry, :not_a_map}} = Registry.build([])
  end

  test "an empty registry builds and resolves nothing" do
    assert {:ok, registry} = Registry.build(%{})

    assert {:error, %Error{code: :unknown_reducer}} =
             Registry.resolve(registry, "test.conforming", 1)
  end
end
