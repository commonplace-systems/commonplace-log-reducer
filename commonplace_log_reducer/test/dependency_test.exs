defmodule Commonplace.LogReducer.DependencyTest do
  use ExUnit.Case, async: true

  @lib Path.expand("../lib", __DIR__)
  @mixfile Path.expand("../mix.exs", __DIR__)

  test "the engine names no reducer plugin, with a positive control" do
    paths = Path.wildcard(Path.join(@lib, "**/*.ex"))
    assert paths != [], "positive control: found no engine sources to scan"

    source = Enum.map_join(paths, "\n", &File.read!/1)
    assert source =~ "LogReducer", "positive control: scanned sources are not the engine"

    for forbidden <- ["AttributeMap", "MerkleCRDT", "attribute-map", "merkle-crdt"] do
      refute source =~ forbidden
    end
  end

  test "mix.exs declares no plugin dependency, with a positive control" do
    source = File.read!(@mixfile)
    assert source =~ ":commonplace_log_reducer"
    refute source =~ ":commonplace_attribute_map"
  end

  test "the engine performs no I/O and loads no code dynamically" do
    paths = Path.wildcard(Path.join(@lib, "**/*.ex"))
    assert paths != [], "positive control: found no engine sources to scan"

    source = Enum.map_join(paths, "\n", &File.read!/1)
    assert source =~ "LogReducer", "positive control: scanned sources are not the engine"

    for forbidden <- [
          "String.to_atom",
          "String.to_existing_atom",
          "Module.concat",
          "List.to_atom",
          ":erlang.binary_to_atom",
          ":erlang.binary_to_existing_atom",
          ":httpc",
          "File.read",
          "Code.eval",
          "Code.compile",
          "Code.require_file",
          "Code.load_file",
          ":os.timestamp",
          "DateTime.utc_now",
          ":rand."
        ] do
      refute source =~ forbidden, "engine must not contain #{forbidden} (§11, §12.1, §22)"
    end
  end
end
