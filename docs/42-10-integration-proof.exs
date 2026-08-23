# §42.10 INTEGRATION PROOF -- run a real log through the engine with the
# second, independently-authored plugin registered.
alias Commonplace.LogReducer
alias Commonplace.LogReducer.Registry
alias CommonplaceMerkleCrdt.V1
alias Yelixer.{Doc, Encoding}
alias Yelixer.Types.Text

log = "0198d83c-eaf8-7c5d-b1e3-4387f1d8d9b8"
writer = "0198d83d-54de-7c06-b574-ea1fb40d3a86"
epoch = "0198d83a-0a1f-7ba0-aa24-21f9130f883d"

upd = fn client, text -> Doc.new(client_id: client) |> Text.insert("t", 0, text) |> Encoding.encode_update() end
cid = fn u, p -> :crypto.hash(:sha256, [u, p || ""]) |> Base.encode16(case: :lower) end

entry = fn seq, prev, body ->
  %{"log_id" => log, "entry_id" => "e#{seq}", "writer_id" => writer,
    "writer_seq" => seq, "prev_entry_id" => prev,
    "created_at" => "2026-08-23T00:00:0#{seq}Z", "body" => body}
end

u1 = upd.(100, "hello"); i1 = cid.(u1, nil)
u2 = upd.(200, "world"); i2 = cid.(u2, i1)

commit = fn id, parent, u ->
  %{"type" => "commit", "id" => id, "parent_id" => parent,
    "update" => Base.encode64(u), "metadata" => %{"kind" => "edit"}, "merge_parents" => []}
end

entries = [
  entry.(1, nil, %{"type" => "commonplace.reducer.epoch", "version" => 1,
    "projection" => "content", "epoch_id" => epoch, "parent_epoch_id" => nil,
    "reducer" => %{"id" => "commonplace.merkle-crdt", "version" => 1},
    "base" => %{"version" => 1, "applied" => []}}),
  entry.(2, "e1", %{"type" => "app.unrelated", "note" => "engine must skip this"}),
  entry.(3, "e2", %{"type" => "commonplace.reducer.operation", "version" => 1,
    "projection" => "content", "epoch_id" => epoch, "operation" => commit.(i1, nil, u1)}),
  entry.(4, "e3", %{"type" => "commonplace.reducer.operation", "version" => 1,
    "projection" => "content", "epoch_id" => epoch, "operation" => commit.(i2, i1, u2)})
]

{:ok, reg} = Registry.build(%{{"commonplace.merkle-crdt", 1} => V1})
IO.puts("registry built (identity check passed): OK")

{:ok, st} = LogReducer.new(log, reg)
{:ok, st} = LogReducer.reduce(st, entries)

{:ok, v} = LogReducer.view(st, "content")
IO.puts("view          : #{inspect(v.value)}")
IO.puts("head          : #{inspect(v.head)}")
IO.puts("epoch         : #{v.epoch_id}")

{:ok, cp} = LogReducer.checkpoint(st)
{:ok, st2} = LogReducer.restore(cp, reg)
{:ok, v2} = LogReducer.view(st2, "content")
IO.puts("restore view  : #{inspect(v2.value)}  identical: #{v2.value == v.value}")

# checkpoint + suffix == full replay (§42.7)
{:ok, mid} = LogReducer.new(log, reg)
{:ok, mid} = LogReducer.reduce(mid, Enum.take(entries, 3))
{:ok, mcp} = LogReducer.checkpoint(mid)
{:ok, res} = LogReducer.restore(mcp, reg)
{:ok, res} = LogReducer.reduce(res, Enum.drop(entries, 3))
{:ok, vr} = LogReducer.view(res, "content")
IO.puts("cp+suffix     : #{inspect(vr.value)}  == full replay: #{vr.value == v.value}")
IO.puts("cp bytes eq   : #{Jason.encode!(LogReducer.checkpoint(res) |> elem(1)) == Jason.encode!(cp)}")

# the plugin's snapshot refusal, surfacing through the engine
bad = entry.(5, "e4", %{"type" => "commonplace.reducer.operation", "version" => 1,
  "projection" => "content", "epoch_id" => epoch,
  "operation" => %{commit.("deadbeef", i2, u1) | "metadata" => %{"kind" => "snapshot"}}})
case LogReducer.reduce(st, [bad]) do
  {:error, err, prefix} ->
    IO.puts("snapshot ref  : code=#{err.code} seq=#{err.writer_seq} reason=#{inspect(err.details[:reason])}")
    IO.puts("prefix head   : #{inspect(prefix.head_seq)} (unchanged: #{prefix.head_seq == 4})")
  other -> IO.puts("UNEXPECTED: #{inspect(other)}")
end
