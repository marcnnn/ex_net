defmodule ExNet.Interop.KernelTrafficTest do
  @moduledoc """
  The reverse direction: packets produced by the Linux kernel (ARP, IGMPv3,
  UDP, 802.1Q and 802.1ad tagged) are captured with tcpdump on a veth pair in
  the `ex-interop-nettools` container and decoded with ex_net.
  """
  use ExUnit.Case, async: false

  alias ExNet.{ARP, Ethernet, IGMP, IPv4, Pcap, UDP}

  @moduletag :interop
  @moduletag timeout: 120_000

  setup_all do
    Interop.Podman.require_image!("nettools")
    dir = Interop.Tshark.tmp_dir()
    script = Path.join(__DIR__, "support/kernel_traffic.sh")

    {out, status} =
      Interop.Podman.run([
        "--cap-add=NET_ADMIN,NET_RAW",
        "-v",
        "#{script}:/kernel_traffic.sh:ro,z",
        "-v",
        "#{dir}:/out:z",
        Interop.Podman.image("nettools"),
        "sh",
        "/kernel_traffic.sh"
      ])

    assert status == 0, out
    {:ok, frames} = dir |> Path.join("cap.pcap") |> File.read!() |> Pcap.decode()

    eth =
      frames
      |> Enum.map(&Ethernet.decode/1)
      |> Enum.flat_map(fn
        {:ok, f} -> [f]
        _ -> []
      end)

    %{eth: eth, dir: dir, frames: frames}
  end

  test "every frame of the capture is classified, none fail to decode", %{
    eth: eth,
    frames: frames
  } do
    assert length(frames) > 8
    # the kernel also speaks IPv6 on the veth (NS, RS, MLD); those are ignored here
    assert Enum.all?(eth, &(&1.ethertype in [0x0800, 0x0806, 0x86DD]))
    assert length(eth) == length(frames)
  end

  test "ARP requests, plain and tagged", %{eth: eth} do
    arps = for %{ethertype: 0x0806} = f <- eth, do: f
    assert length(arps) >= 3

    decoded =
      for f <- arps do
        assert {:ok, a} = ARP.decode(f.payload)
        {f.tags, a}
      end

    assert Enum.all?(decoded, fn {_, a} -> a.op == :request end)
    assert Enum.all?(arps, &(&1.dst == Ethernet.broadcast()))

    vids = for {tags, _} <- decoded, do: Enum.map(tags, &{&1.tpid, &1.vid})
    assert [] in vids
    assert [{0x8100, 20}] in vids
    assert [{0x88A8, 30}] in vids

    {_, a} = Enum.find(decoded, fn {t, _} -> t == [] end)
    assert {a.spa, a.tpa} == {{10, 9, 0, 2}, {10, 9, 0, 77}}
  end

  test "UDP multicast with verified IPv4 and UDP checksums", %{eth: eth} do
    udps =
      for %{ethertype: 0x0800} = f <- eth,
          {:ok, ip} <- [IPv4.decode(f.payload)],
          ip.protocol == 17,
          do: {f, ip}

    assert length(udps) == 3

    for {f, ip} <- udps do
      assert {:ok, u} = UDP.decode(ip.payload, ip.src, ip.dst)
      assert u.checksum_present
      assert u.dst_port == 5004
      assert ip.dst == {239, 69, 1, 1}
      assert ip.ttl == 4
      assert f.dst == Ethernet.multicast_mac({239, 69, 1, 1})
      assert u.payload =~ ~r/^interop 10\.\d+\.0\.2\n$/
    end

    tags = for {f, _} <- udps, do: Enum.map(f.tags, &{&1.tpid, &1.vid})
    assert Enum.sort(tags) == Enum.sort([[], [{0x8100, 20}], [{0x88A8, 30}]])
  end

  test "IGMPv3 join and leave reports", %{eth: eth} do
    reports =
      for %{ethertype: 0x0800} = f <- eth,
          {:ok, ip} <- [IPv4.decode(f.payload)],
          ip.protocol == IGMP.protocol(),
          do: {f, ip}

    assert reports != []

    msgs =
      for {f, ip} <- reports do
        assert ip.dst == IGMP.v3_reports()
        assert ip.ttl == 1
        assert f.dst == Ethernet.multicast_mac(IGMP.v3_reports())
        assert {:ok, m} = IGMP.decode(ip.payload)
        m
      end

    records = for %IGMP.ReportV3{records: rs} <- msgs, r <- rs, do: r
    mine = Enum.filter(records, &(&1.group == {239, 69, 1, 5}))
    assert mine != []
    # join: change_to_exclude {} or mode_is_exclude {}; leave: change_to_include {}
    types = Enum.map(mine, & &1.type)
    assert Enum.any?(types, &(&1 in [:change_to_exclude, :mode_is_exclude]))
    assert :change_to_include in types
    assert Enum.all?(mine, &(&1.sources == []))
  end
end
