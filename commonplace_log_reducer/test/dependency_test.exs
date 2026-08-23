defmodule Commonplace.LogReducer.DependencyTest do
  use ExUnit.Case, async: true

  @lib Path.expand("../lib", __DIR__)
  @mixfile Path.expand("../mix.exs", __DIR__)

  # KNOWN FALSE POSITIVE, and the sanctioned response is to REWORD, not to weaken.
  #
  # This is a substring scan, so it cannot tell a code reference from prose. A
  # moduledoc that legitimately quotes the spec (which says "commonplace-
  # attribute-map version 1 requires no external resources") trips it. That
  # happened once, in context.ex, and rewording was correct.
  #
  # Do NOT respond by narrowing the forbidden list, skipping comments, or
  # excluding a file. The gate's whole value is that the engine cannot name a
  # plugin, and every carve-out is a hole shaped like the next real violation.
  # Paraphrase the prose instead -- the cost is a sentence.
  test "the engine names no reducer plugin, with a positive control" do
    paths = Path.wildcard(Path.join(@lib, "**/*.ex"))
    assert paths != [], "positive control: found no engine sources to scan"

    source = Enum.map_join(paths, "\n", &File.read!/1)
    assert source =~ "LogReducer", "positive control: scanned sources are not the engine"

    for forbidden <- ["AttributeMap", "MerkleCRDT", "attribute-map", "merkle-crdt"] do
      refute source =~ forbidden
    end
  end

  # SECONDARY TRIPWIRE, not the boundary's enforcement.
  #
  # A real path dep on the plugin creates a cycle that aborts mix before ExUnit
  # loads ("another project with the same name was already defined"), so this
  # assertion cannot fire in the case it was nominally written for. The BUILD
  # GRAPH is what enforces the plugin boundary (spec §37.1). What this test
  # catches is the plugin named in mix.exs in some non-cycle form: a comment, a
  # string, an optional:/only: entry, or a dep named without a path.
  #
  # Do not read a green here as "the boundary is test-enforced" and collapse the
  # two projects into one -- that would delete the enforcement and keep the test
  # that appears to provide it.
  test "mix.exs names no plugin in any non-cycle form, with a positive control" do
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
