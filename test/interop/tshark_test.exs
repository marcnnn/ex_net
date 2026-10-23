defmodule ExNet.Interop.TsharkTest do
  @moduledoc """
  Frames built by ex_net, dissected by Wireshark's tshark (in the
  `ex-interop-tshark` container, see containers/build.sh). Every packet must be
  free of malformed markers and expert warnings, with IPv4/UDP/IGMP checksums
  verified by Wireshark, and the decoded fields must equal what went in.
  """
  use ExUnit.Case, async: true

  alias ExNet.{ARP, Ethernet, IGMP, IPv4, UDP}
  alias Interop.Tshark

  import Bitwise, only: [bxor: 2]

  @moduletag :interop
  @moduletag timeout: 120_000

  @me <<2, 0, 0, 0, 0, 1>>
  @router_alert <<0x94, 4, 0, 0>>

  defp udp_frame(opts) do
    src = Keyword.get(opts, :src, {10, 0, 0, 1})
    dst = Keyword.get(opts, :dst, {239, 69, 1, 1})
    payload = Keyword.get(opts, :payload, "payload")
    udp = UDP.encode(%UDP{src_port: 4000, dst_port: 5004, payload: payload}, src, dst)

    ip =
      IPv4.encode(%IPv4{
        src: src,
        dst: dst,
        protocol: 17,
        dscp: Keyword.get(opts, :dscp, 0),
        ecn: Keyword.get(opts, :ecn, 0),
        id: Keyword.get(opts, :id, 0),
        ttl: Keyword.get(opts, :ttl, 64),
        df: Keyword.get(opts, :df, false),
        options: Keyword.get(opts, :options, <<>>),
        payload: udp
      })

    Ethernet.encode(%Ethernet{
      dst: Ethernet.multicast_mac(dst),
      src: @me,
      tags: Keyword.get(opts, :tags, []),
      ethertype: 0x0800,
      payload: ip
    })
  end

  defp igmp_frame(msg, dst) do
    ip =
      IPv4.encode(%IPv4{
        src: {10, 0, 0, 1},
        dst: dst,
        protocol: 2,
        ttl: 1,
        dscp: 48,
        options: @router_alert,
        payload: IGMP.encode(msg)
      })

    Ethernet.encode(%Ethernet{
      dst: Ethernet.multicast_mac(dst),
      src: @me,
      ethertype: 0x0800,
      payload: ip
    })
  end

  test "ethernet, vlan, ipv4 and udp fields and checksums" do
    s_tag = %{tpid: 0x88A8, pcp: 3, dei: 1, vid: 7}
    c_tag = %{tpid: 0x8100, pcp: 5, dei: 0, vid: 20}

    cases = [
      {udp_frame([]), %{"eth.dst" => "01:00:5e:45:01:01", "eth.type" => "0x0800"}},
      {udp_frame(tags: [c_tag]),
       %{"vlan.id" => "20", "vlan.priority" => "5", "vlan.dei" => "0", "vlan.etype" => "0x0800"}},
      {udp_frame(tags: [s_tag, c_tag]),
       %{
         "ieee8021ad.id" => "7",
         "ieee8021ad.priority" => "3",
         "ieee8021ad.dei" => "1",
         "vlan.id" => "20",
         "vlan.priority" => "5"
       }},
      {udp_frame(options: @router_alert, dscp: 46, ecn: 2, id: 0xBEEF, ttl: 1, df: true),
       %{
         "ip.hdr_len" => "24",
         "ip.dsfield.dscp" => "46",
         "ip.dsfield.ecn" => "2",
         "ip.id" => "0xbeef",
         "ip.ttl" => "1",
         "ip.flags.df" => "1"
       }},
      {udp_frame(payload: String.duplicate("x", 1000), dst: {224, 0, 1, 129}),
       %{"ip.dst" => "224.0.1.129", "eth.dst" => "01:00:5e:00:01:81", "udp.length" => "1008"}}
    ]

    pkts = Tshark.dissect(Enum.map(cases, &elem(&1, 0)))
    assert length(pkts) == length(cases)
    Tshark.assert_clean(pkts)

    for {pkt, {_, expect}} <- Enum.zip(pkts, cases) do
      assert Tshark.get(pkt, "ip.src") == "10.0.0.1"
      assert Tshark.get(pkt, "udp.srcport") == "4000"
      assert Tshark.get(pkt, "udp.dstport") == "5004"
      assert Tshark.get(pkt, "ip.proto") == "17"
      # Wireshark checksum status: 1 good, 2 unverified, 0 bad
      assert Tshark.get(pkt, "ip.checksum.status") == "1"
      assert Tshark.get(pkt, "udp.checksum.status") == "1"

      for {k, v} <- expect,
          do: assert(Tshark.get(pkt, k) == v, "#{k}: #{inspect(pkt[k])} != #{v}")
    end
  end

  test "udp checksum is verified with a corrupted payload as bad (negative control)" do
    frame = udp_frame([])
    n = byte_size(frame) - 1
    <<head::binary-size(n), last>> = frame
    [pkt] = Tshark.dissect([<<head::binary, bxor(last, 1)>>])
    assert Tshark.get(pkt, "udp.checksum.status") == "0"
  end

  test "arp request and reply" do
    mk = fn op, tha, dst ->
      Ethernet.encode(%Ethernet{
        dst: dst,
        src: @me,
        ethertype: 0x0806,
        payload:
          ARP.encode(%ARP{op: op, sha: @me, spa: {10, 0, 0, 1}, tha: tha, tpa: {10, 0, 0, 2}})
      })
    end

    pkts =
      Tshark.dissect([
        mk.(:request, <<0::48>>, Ethernet.broadcast()),
        mk.(:reply, <<2, 0, 0, 0, 0, 2>>, <<2, 0, 0, 0, 0, 2>>)
      ])

    Tshark.assert_clean(pkts)
    assert Enum.map(pkts, &Tshark.get(&1, "arp.opcode")) == ["1", "2"]

    for p <- pkts do
      assert Tshark.get(p, "arp.src.proto_ipv4") == "10.0.0.1"
      assert Tshark.get(p, "arp.dst.proto_ipv4") == "10.0.0.2"
      assert Tshark.get(p, "arp.src.hw_mac") == "02:00:00:00:00:01"
    end

    assert Tshark.get(Enum.at(pkts, 1), "arp.dst.hw_mac") == "02:00:00:00:00:02"
  end

  test "igmp v1, v2, v3 queries, reports and leave" do
    g = {239, 69, 1, 1}

    msgs = [
      {%IGMP.Report{version: 1, group: g}, g},
      {%IGMP.Report{version: 2, group: g}, g},
      {%IGMP.Leave{group: g}, IGMP.all_routers()},
      {%IGMP.Query{version: 2, max_resp: 100, group: {0, 0, 0, 0}}, IGMP.all_hosts()},
      {%IGMP.Query{
         version: 3,
         max_resp: 100,
         group: g,
         qrv: 2,
         qqic: 125,
         sources: [{10, 0, 0, 5}]
       }, g},
      {%IGMP.ReportV3{
         records: [
           %IGMP.Record{type: :change_to_exclude, group: g, sources: []},
           %IGMP.Record{
             type: :allow_new_sources,
             group: {239, 69, 1, 2},
             sources: [{10, 0, 0, 5}, {10, 0, 0, 6}]
           }
         ]
       }, IGMP.v3_reports()}
    ]

    pkts = Tshark.dissect(Enum.map(msgs, fn {m, dst} -> igmp_frame(m, dst) end))
    Tshark.assert_clean(pkts)

    for p <- pkts, do: assert(Tshark.get(p, "igmp.checksum.status") == "1")
    types = Enum.map(pkts, &Tshark.get(&1, "igmp.type"))
    assert types == ["0x12", "0x16", "0x17", "0x11", "0x11", "0x22"]

    for {p, {%{group: grp}, _}} <- Enum.zip(Enum.take(pkts, 3), msgs) do
      assert Tshark.get(p, "igmp.maddr") == ip(grp)
    end

    q3 = Enum.at(pkts, 4)
    assert Tshark.get(q3, "igmp.maddr") == "239.69.1.1"
    assert Tshark.get(q3, "igmp.num_src") == "1"
    assert Tshark.get(q3, "igmp.saddr") == "10.0.0.5"
    assert Tshark.get(q3, "igmp.qrv") == "2"

    r3 = Enum.at(pkts, 5)
    assert Tshark.get(r3, "igmp.num_grp_recs") == "2"
    assert Tshark.all(r3, "igmp.record_type") == ["4", "5"]
    assert Tshark.all(r3, "igmp.maddr") == ["239.69.1.1", "239.69.1.2"]
    assert Tshark.all(r3, "igmp.saddr") == ["10.0.0.5", "10.0.0.6"]
  end

  defp ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
end
