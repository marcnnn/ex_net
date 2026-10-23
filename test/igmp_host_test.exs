defmodule ExNet.IGMP.HostTest do
  use ExUnit.Case, async: true

  alias ExNet.{Ethernet, IGMP, IPv4}
  alias ExNet.IGMP.{Host, Leave, Query, Record, Report, ReportV3}

  doctest Host

  @g1 {239, 69, 1, 1}
  @g2 {239, 69, 1, 2}

  defp host(v, opts \\ []),
    do: Host.new([mac: <<2, 0, 0, 0, 0, 1>>, ip: {10, 0, 0, 5}, version: v] ++ opts)

  defp msgs(frames), do: for(f <- frames, do: elem(Host.decode_frame(f), 1))

  # runs ticks every ms up to `until`, collecting the frames
  defp run(h, until) do
    Enum.reduce((h.now + 1)..until//1, {h, []}, fn t, {h, acc} ->
      {h, fs} = Host.step(h, {:tick, t})
      {h, acc ++ Enum.map(fs, &{t, &1})}
    end)
  end

  test "frame headers: TTL 1, Router Alert, multicast MAC, destination per version" do
    {_, [f2]} = Host.step(host(2), {:join, @g1})
    {_, [f3]} = Host.step(host(3), {:join, @g1})

    for {f, dst} <- [{f2, @g1}, {f3, IGMP.v3_reports()}] do
      {:ok, eth} = Ethernet.decode(f)
      {:ok, ip} = IPv4.decode(eth.payload)
      assert eth.dst == Ethernet.multicast_mac(dst)
      assert {ip.ttl, ip.dst, ip.protocol, ip.options} == {1, dst, 2, <<0x94, 4, 0, 0>>}
    end

    assert [%ReportV3{records: [%Record{type: :change_to_exclude, group: @g1, sources: []}]}] =
             msgs([f3])
  end

  test "VLAN tag" do
    {_, [f]} = Host.step(host(3, vlan: 100), {:join, @g1})
    {:ok, eth} = Ethernet.decode(f)
    assert [%{vid: 100, pcp: 6}] = eth.tags
  end

  for v <- [2, 3] do
    test "v#{v}: join is sent robustness times within the unsolicited interval" do
      h = host(unquote(v), robustness: 3)
      {h, first} = Host.step(h, {:join, @g1})
      {_h, later} = run(h, 2500)
      assert length(first) == 1
      assert length(later) == 2
      assert Enum.all?(later, fn {t, _} -> t <= 2000 end)
    end
  end

  test "v2 leave goes to all routers" do
    h = host(2)
    {h, _} = Host.step(h, {:join, @g1})
    {_, [f]} = Host.step(h, {:leave, @g1})
    assert msgs([f]) == [%Leave{group: @g1}]
    {:ok, eth} = Ethernet.decode(f)
    {:ok, ip} = IPv4.decode(eth.payload)
    assert ip.dst == IGMP.all_routers()
  end

  test "v3 general query: one report with every group, within max response" do
    h = host(3)
    {h, _} = Host.step(h, {:join, @g1})
    {h, _} = Host.step(h, {:join, @g2})
    {h, _} = run(h, 3000)
    {h, []} = Host.step(h, {:query, %Query{version: 3, max_resp: 50}})
    {_, out} = run(h, 10_000)

    assert [{t, f}] = out
    assert t <= 3000 + 5000

    assert [%ReportV3{records: rs}] = msgs([f])
    assert Enum.map(rs, &{&1.type, &1.group}) == [mode_is_exclude: @g1, mode_is_exclude: @g2]
  end

  test "v2: group query answered, suppressed by another host's report" do
    h = host(2)
    {h, _} = Host.step(h, {:join, @g1})
    {h, _} = run(h, 3000)
    q = %Query{version: 2, max_resp: 100, group: @g1}
    {h1, []} = Host.step(h, {:query, q})
    {_, out} = run(h1, 14_000)
    assert msgs(Enum.map(out, &elem(&1, 1))) == [%Report{version: 2, group: @g1}]

    {h2, []} = Host.step(h1, {:report, @g1})
    assert {_, []} = run(h2, 14_000)
  end

  test "v3 host falls back to v2 on a v2 query" do
    h = host(3)
    {h, _} = Host.step(h, {:join, @g1})
    {h, _} = run(h, 3000)
    {h, []} = Host.step(h, {:query, %Query{version: 2, max_resp: 100}})
    assert Host.mode(h) == 2
    {_, out} = run(h, 14_000)
    assert msgs(Enum.map(out, &elem(&1, 1))) == [%Report{version: 2, group: @g1}]
  end

  test "no groups, no answer; deterministic with a seed" do
    assert {_, []} = Host.step(host(3), {:query, %Query{}})
    a = host(3, seed: 7) |> Host.step({:join, @g1}) |> elem(0) |> run(3000)
    b = host(3, seed: 7) |> Host.step({:join, @g1}) |> elem(0) |> run(3000)
    assert a == b
  end
end
