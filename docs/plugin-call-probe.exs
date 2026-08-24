# plugin_call/4 against the foreign plugin (commonplace-merkle-crdt) at its HEAD
# 31e6dca, reducer_version 3. Run from that repository against its resolved
# dependency, as docs/42-10-integration-proof.exs is. Demonstrates the host
# reaching assemble/2 without the plugin state ever leaving the engine, and the
# three refusals. Valid only at the stated plugin commit: the operation format
# (commit "epoch_id", registry version 3) is the plugin's and moves with it.
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
  %{"type" => "commit", "id" => id, "parent_id" => parent, "epoch_id" => epoch,
    "update" => Base.encode64(u), "metadata" => %{"kind" => "edit"}, "merge_parents" => []}
end

entries = [
  entry.(1, nil, %{"type" => "commonplace.reducer.epoch", "version" => 1,
    "projection" => "content", "epoch_id" => epoch, "parent_epoch_id" => nil,
    "reducer" => %{"id" => "commonplace.merkle-crdt", "version" => 3},
    "base" => %{"version" => 1, "entries" => []}}),
  entry.(2, "e1", %{"type" => "app.unrelated", "note" => "engine must skip this"}),
  entry.(3, "e2", %{"type" => "commonplace.reducer.operation", "version" => 1,
    "projection" => "content", "epoch_id" => epoch, "operation" => commit.(i1, nil, u1)}),
  entry.(4, "e3", %{"type" => "commonplace.reducer.operation", "version" => 1,
    "projection" => "content", "epoch_id" => epoch, "operation" => commit.(i2, i1, u2)})
]

{:ok, reg} = Registry.build(%{{"commonplace.merkle-crdt", 3} => V1})
{:ok, st} = LogReducer.new(log, reg)
{:ok, st} = LogReducer.reduce(st, entries)
{:ok, v} = LogReducer.view(st, "content")
IO.puts("view              : #{inspect(v.value)}")

r = LogReducer.plugin_call(st, "content", :assemble, [i2])
IO.puts("assemble(i2)      : #{inspect(r, limit: 6, printable_limit: 40)}")
{:ok, at_i1} = LogReducer.plugin_call(st, "content", :assemble, [i1])
{:ok, at_i2} = LogReducer.plugin_call(st, "content", :assemble, [i2])
IO.puts("control i1 != i2  : #{at_i1 != at_i2}")
IO.puts("unknown commit    : #{inspect(LogReducer.plugin_call(st, "content", :assemble, ["nope"]))}")
IO.puts("apply/3 reserved  : #{inspect(LogReducer.plugin_call(st, "content", :apply, [nil, nil]))}")
IO.puts("checkpoint/1 resv : #{inspect(LogReducer.plugin_call(st, "content", :checkpoint, []))}")
IO.puts("no such fun       : #{inspect(LogReducer.plugin_call(st, "content", :assemble, []))}")
IO.puts("unknown projection: #{inspect(LogReducer.plugin_call(st, "nope", :assemble, [i2]))}")
IO.puts("state untouched   : #{match?({:ok, %{value: ^v}}, LogReducer.view(st, "content")) |> then(&(&1 or elem(LogReducer.view(st, "content"), 1).value == v.value))}")
