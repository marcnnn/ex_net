defmodule ExNet.TsharkTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias ExNet.{ARP, Ethernet, Frames, IGMP, Pcap}

  # checksum.status: 1 = good (Wireshark enum: 0 bad, 1 good, 2 unverified)
  # not run in CI without tshark; the field names are from memory
  defp dissect(dir, frames, fields) do
    path = Path.join(dir, "t.pcap")
    Pcap.write!(path, frames)

    args =
      ["-r", path, "-T", "fields", "-E", "separator=/t"] ++ Enum.flat_map(fields, &["-e", &1])

    {out, 0} = System.cmd("tshark", args, stderr_to_stdout: false)
    out |> String.split("\n", trim: true) |> Enum.map(&String.split(&1, "\t"))
  end

  @tag :tshark
  test "ethernet, vlan, ipv4 with options and udp checksums are accepted", %{tmp_dir: dir} do
    tags = [%{tpid: 0x88A8, pcp: 0, dei: 0, vid: 7}, %{tpid: 0x8100, pcp: 5, dei: 0, vid: 20}]

    frames = [
      Frames.udp_frame(),
      Frames.udp_frame(tags: tags),
      Frames.udp_frame(options: <<1, 1, 1, 1>>, payload: String.duplicate("x", 101))
    ]

    rows =
      dissect(dir, frames, ["ip.dst", "udp.dstport", "ip.checksum.status", "udp.checksum.status"])

    assert length(rows) == 3

    for row <- rows do
      assert [dst, "5004", ip_ok, udp_ok] = row
      assert dst == "239.69.1.1"
      assert ip_ok == "1"
      assert udp_ok == "1"
    end
  end

  @tag :tshark
  test "igmp and arp are dissected", %{tmp_dir: dir} do
    me = <<2, 0, 0, 0, 0, 1>>

    arp = %Ethernet{
      dst: Ethernet.broadcast(),
      src: me,
      ethertype: 0x0806,
      payload:
        ARP.encode(%ARP{
          op: :request,
          sha: me,
          spa: {10, 0, 0, 1},
          tha: <<0::48>>,
          tpa: {10, 0, 0, 2}
        })
    }

    group = {239, 69, 1, 1}
    igmp = IGMP.encode(%IGMP.Report{version: 2, group: group})

    ip =
      ExNet.IPv4.encode(%ExNet.IPv4{
        src: {10, 0, 0, 1},
        dst: group,
        protocol: 2,
        ttl: 1,
        options: <<0x94, 4, 0, 0>>,
        payload: igmp
      })

    igmp_frame = %Ethernet{
      dst: Ethernet.multicast_mac(group),
      src: me,
      ethertype: 0x0800,
      payload: ip
    }

    assert [[spa, tpa], [grp, ck]] =
             dissect(dir, [Ethernet.encode(arp), Ethernet.encode(igmp_frame)], [
               "arp.src.proto_ipv4",
               "arp.dst.proto_ipv4",
               "igmp.maddr",
               "igmp.checksum.status"
             ])
             |> Enum.map(&Enum.take(&1, 2))

    assert {spa, tpa} == {"10.0.0.1", "10.0.0.2"}
    assert {grp, ck} == {"239.69.1.1", "1"}
  end

  # tcpdump -vv verifies IPv4 and UDP checksums and prints "bad" on failure
  @tag :tcpdump
  test "tcpdump accepts headers, checksums and IGMP", %{tmp_dir: dir} do
    me = <<2, 0, 0, 0, 0, 1>>
    group = {239, 69, 1, 1}
    tags = [%{tpid: 0x88A8, pcp: 0, dei: 0, vid: 7}, %{tpid: 0x8100, pcp: 5, dei: 0, vid: 20}]

    igmp = fn m ->
      ip =
        ExNet.IPv4.encode(%ExNet.IPv4{
          src: {10, 0, 0, 1},
          dst: group,
          protocol: 2,
          ttl: 1,
          options: <<0x94, 4, 0, 0>>,
          payload: IGMP.encode(m)
        })

      Ethernet.encode(%Ethernet{
        dst: Ethernet.multicast_mac(group),
        src: me,
        ethertype: 0x0800,
        payload: ip
      })
    end

    frames = [
      Frames.udp_frame(),
      Frames.udp_frame(tags: tags),
      Frames.udp_frame(options: <<1, 1, 1, 1>>, payload: String.duplicate("x", 101)),
      igmp.(%IGMP.Report{version: 2, group: group}),
      igmp.(%IGMP.ReportV3{
        records: [%IGMP.Record{type: :change_to_exclude, group: group, sources: []}]
      })
    ]

    path = Path.join(dir, "t.pcap")
    Pcap.write!(path, frames)
    {out, 0} = System.cmd("tcpdump", ["-r", path, "-e", "-vv", "-n"], stderr_to_stdout: true)
    refute out =~ ~r/bad|truncated|incorrect/i
    assert length(Regex.scan(~r/udp sum ok/, out)) == 3
    assert out =~ "vlan 7, p 0, ethertype 802.1Q (0x8100), vlan 20, p 5"
    assert out =~ "igmp v2 report 239.69.1.1"
    assert out =~ "igmp v3 report, 1 group record(s)"
    assert out =~ "options (NOP,NOP,NOP,NOP)"
  end
end
