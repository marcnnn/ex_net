defmodule ExNet.Interop.IgmpRtlTest do
  @moduledoc """
  Frames sent by `ExNet.RTL.Igmp` (BEAM simulation of the generated design), dissected by
  Wireshark's tshark: no malformed markers or expert warnings, IPv4 and IGMP checksums verified by
  Wireshark, Router Alert, TTL 1, CS6, multicast MAC, and the decoded messages equal the ones the
  scenario must produce.
  """
  use ExUnit.Case, async: true

  alias ExNet.{IgmpBench, IGMP}
  alias ExNet.IGMP.Query
  alias Interop.Tshark

  @moduletag :interop
  @moduletag timeout: 300_000

  @g1 {239, 69, 1, 1}
  @g2 {239, 69, 1, 2}
  @g3 {239, 69, 1, 3}

  # a frame as the MAC puts it on the wire (padded to 60 bytes, no FCS)
  defp wire(f) when byte_size(f) < 60, do: f <> :binary.copy(<<0>>, 60 - byte_size(f))
  defp wire(f), do: f

  defp ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp check_common(pkts) do
    Tshark.assert_clean(pkts)

    for p <- pkts do
      assert Tshark.get(p, "ip.checksum.status") == "1"
      assert Tshark.get(p, "igmp.checksum.status") == "1"
      assert Tshark.get(p, "ip.ttl") == "1"
      assert Tshark.get(p, "ip.dsfield.dscp") == "48"
      assert Tshark.get(p, "ip.hdr_len") == "24"
      assert Tshark.get(p, "ip.options.routeralert") == "94:04:00:00"
      assert Tshark.get(p, "eth.src") == "02:00:00:00:00:42"
      assert Tshark.get(p, "ip.src") == "10.1.2.3"
    end
  end

  test "v3 joins, general query response and leave" do
    joins = for {g, i} <- Enum.with_index([@g1, @g2, @g3]), do: {5 + i, {:join, g}}
    qf = IgmpBench.query_frame(%Query{version: 3, max_resp: 2})
    script = joins ++ [{600, {:rx, qf}}, {5000, {:leave, @g2}}]
    r = IgmpBench.run(script, 5000 + 400, cfg: IgmpBench.cfg(robustness: 1))
    pkts = Tshark.dissect(Enum.map(r.frames, &wire(elem(&1, 1))))
    assert length(pkts) == 5
    check_common(pkts)

    for p <- pkts do
      assert Tshark.get(p, "ip.dst") == "224.0.0.22"
      assert Tshark.get(p, "eth.dst") == "01:00:5e:00:00:16"
      assert Tshark.get(p, "igmp.type") == "0x22"
    end

    # the three joins go out in the order of the table scan
    {joins3, [resp, leave]} = Enum.split(pkts, 3)
    [j1, j2, j3] = Enum.sort_by(joins3, &Tshark.get(&1, "igmp.maddr"))
    assert Tshark.get(j1, "igmp.maddr") == ip(@g1)
    assert Tshark.get(j2, "igmp.maddr") == ip(@g2)
    assert Tshark.get(j3, "igmp.maddr") == ip(@g3)
    for j <- [j1, j2, j3], do: assert(Tshark.get(j, "igmp.record_type") == "4")
    assert Tshark.get(resp, "igmp.num_grp_recs") == "3"
    assert Tshark.all(resp, "igmp.record_type") == ["2", "2", "2"]
    assert Enum.sort(Tshark.all(resp, "igmp.maddr")) == [ip(@g1), ip(@g2), ip(@g3)]
    assert Tshark.get(leave, "igmp.record_type") == "3"
    assert Tshark.get(leave, "igmp.maddr") == ip(@g2)
  end

  test "v2 report and leave" do
    script = [{5, {:join, @g1}}, {2000, {:leave, @g1}}]
    r = IgmpBench.run(script, 3000, cfg: IgmpBench.cfg(robustness: 1, v2_only: 1))
    pkts = Tshark.dissect(Enum.map(r.frames, &wire(elem(&1, 1))))
    assert length(pkts) == 2
    check_common(pkts)
    [rep, leave] = pkts
    assert Tshark.get(rep, "igmp.type") == "0x16"
    assert Tshark.get(rep, "ip.dst") == ip(@g1)
    assert Tshark.get(rep, "eth.dst") == "01:00:5e:45:01:01"
    assert Tshark.get(leave, "igmp.type") == "0x17"
    assert Tshark.get(leave, "ip.dst") == "224.0.0.2"
    assert Tshark.get(leave, "eth.dst") == "01:00:5e:00:00:02"
    assert Tshark.get(leave, "igmp.maddr") == ip(@g1)
  end

  test "802.1Q tagged report" do
    r =
      IgmpBench.run([{5, {:join, @g1}}], 600,
        vlan: 100,
        cfg: IgmpBench.cfg(robustness: 1, vlan: 100)
      )

    pkts = Tshark.dissect(Enum.map(r.frames, &wire(elem(&1, 1))))
    assert length(pkts) == 1
    check_common(pkts)
    [p] = pkts
    assert Tshark.get(p, "vlan.id") == "100"
    assert Tshark.get(p, "vlan.priority") == "6"
    assert Tshark.get(p, "vlan.etype") == "0x0800"
    assert Tshark.get(p, "igmp.record_type") == "4"
  end

  test "the frames equal the encoder's IGMP messages" do
    r = IgmpBench.run([{5, {:join, @g1}}], 600, cfg: IgmpBench.cfg(robustness: 1))
    [{_, f}] = r.frames
    assert {:ok, %IGMP.ReportV3{}} = IGMP.Host.decode_frame(f)
  end
end
