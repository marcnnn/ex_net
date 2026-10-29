defmodule ExNet.IGMP.FilterTest do
  use ExUnit.Case, async: true
  alias ExNet.{Checksum, Ethernet, IGMP, IPv4}
  alias ExNet.IGMP.Filter

  doctest ExNet.IGMP.Filter

  @src <<2, 0, 0, 0, 0, 1>>
  @owned MapSet.new([{239, 69, 1, 1}, {239, 69, 1, 2}])

  defp frame(igmp, dst, tags \\ []) do
    ip = %IPv4{
      src: {10, 0, 0, 5},
      dst: dst,
      protocol: 2,
      ttl: 1,
      dscp: 48,
      options: <<148, 4, 0, 0>>,
      payload: IGMP.encode(igmp)
    }

    Ethernet.encode(%Ethernet{
      dst: Ethernet.multicast_mac(dst),
      src: @src,
      tags: tags,
      ethertype: 0x0800,
      payload: IPv4.encode(ip)
    })
  end

  defp rec(g, type \\ :change_to_exclude, sources \\ []),
    do: %IGMP.Record{type: type, group: g, sources: sources}

  defp v3(recs), do: frame(%IGMP.ReportV3{records: recs}, {224, 0, 0, 22})

  defp parse(frame) do
    {:ok, eth} = Ethernet.decode(frame)
    {:ok, ip} = IPv4.decode(eth.payload)
    assert Checksum.valid?(binary_part(eth.payload, 0, 4 * 6))
    {:ok, msg} = IGMP.decode(ip.payload)
    {eth, ip, msg}
  end

  test "v3: owned records are removed, the rest and the headers stay" do
    f =
      v3([
        rec({239, 69, 1, 1}),
        rec({239, 9, 9, 9}, :change_to_include, [{10, 0, 0, 1}]),
        rec({239, 69, 1, 2})
      ])

    out = Filter.filter(f, @owned)
    {eth, ip, msg} = parse(out)

    assert [
             %IGMP.Record{
               group: {239, 9, 9, 9},
               type: :change_to_include,
               sources: [{10, 0, 0, 1}]
             }
           ] =
             msg.records

    assert eth.src == @src and eth.dst == Ethernet.multicast_mac({224, 0, 0, 22})
    assert ip.ttl == 1 and ip.dscp == 48 and ip.options == <<148, 4, 0, 0>>
    assert byte_size(out) < byte_size(f)
  end

  test "v3: a VLAN tag is kept" do
    tags = [%{tpid: 0x8100, pcp: 6, dei: 0, vid: 20}]

    f =
      frame(
        %IGMP.ReportV3{records: [rec({239, 69, 1, 1}), rec({239, 1, 1, 1})]},
        {224, 0, 0, 22},
        tags
      )

    {eth, _ip, msg} = f |> Filter.filter(@owned) |> parse()
    assert eth.tags == tags
    assert [%{group: {239, 1, 1, 1}}] = msg.records
  end

  test "v3: nothing owned leaves the frame byte for byte, all owned drops it" do
    f = v3([rec({239, 1, 1, 1})])
    assert Filter.filter(f, @owned) == f
    assert Filter.filter(v3([rec({239, 69, 1, 1}), rec({239, 69, 1, 2})]), @owned) == :drop
    assert Filter.filter(v3([rec({239, 69, 1, 1})]), []) == v3([rec({239, 69, 1, 1})])
  end

  test "v2 report and leave of an owned group are dropped, others pass" do
    for g <- [{239, 69, 1, 1}, {239, 1, 1, 1}] do
      rep = frame(%IGMP.Report{version: 2, group: g}, g)
      leave = frame(%IGMP.Leave{group: g}, {224, 0, 0, 2})
      v1 = frame(%IGMP.Report{version: 1, group: g}, g)
      expect = fn f -> if g == {239, 69, 1, 1}, do: :drop, else: f end
      assert Filter.filter(rep, @owned) == expect.(rep)
      assert Filter.filter(leave, @owned) == expect.(leave)
      assert Filter.filter(v1, @owned) == expect.(v1)
    end
  end

  test "queries, other protocols and garbage pass unchanged" do
    q = frame(%IGMP.Query{version: 3, group: {239, 69, 1, 1}}, {239, 69, 1, 1})
    assert Filter.filter(q, @owned) == q

    arp =
      Ethernet.encode(%Ethernet{
        dst: Ethernet.broadcast(),
        src: @src,
        ethertype: 0x0806,
        payload: <<0::224>>
      })

    assert Filter.filter(arp, @owned) == arp
    assert Filter.filter(<<1, 2, 3>>, @owned) == <<1, 2, 3>>
  end

  test "random record sets: output holds exactly the not owned records" do
    groups = for i <- 1..6, do: {239, 69, 1, i}

    for mask <- 0..63 do
      recs =
        for {g, i} <- Enum.with_index(groups),
            Bitwise.band(mask, Bitwise.bsl(1, i)) != 0,
            do: rec(g)

      keep = Enum.reject(recs, &MapSet.member?(@owned, &1.group))

      case {recs, Filter.filter(v3(recs), @owned)} do
        {[], out} -> assert out == v3([])
        {_, :drop} -> assert keep == []
        {_, out} -> assert {_, _, %{records: ^keep}} = parse(out)
      end
    end
  end
end
