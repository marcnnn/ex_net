defmodule ExNet.TapTest do
  @moduledoc """
  ExNet.Tap against a real TAP interface with the kernel on the other side.
  Needs an interface that the BEAM's user may open, with 10.0.0.1/24 and up, and
  `EX_NET_TAP=<name>`. `test/interop/tap_container_test.exs` provides it in a
  rootless container; on a host, see the README ("TAP interface").

  The BEAM plays 10.0.0.2 (MAC 02:00:00:00:00:02): it answers ARP requests and ICMP
  echo requests of the kernel with the ExNet codecs.
  """
  use ExUnit.Case, async: false

  alias ExNet.{ARP, Checksum, Ethernet, IGMP, IPv4, Netif, Tap}

  @moduletag :tap
  @moduletag timeout: 120_000
  @moduletag skip:
               if(System.get_env("EX_NET_TAP"), do: false, else: "set EX_NET_TAP=<tap interface>")

  @mac <<2, 0, 0, 0, 0, 2>>
  @ip {10, 0, 0, 2}

  setup do
    ifname = System.get_env("EX_NET_TAP")
    {:ok, tap} = Tap.open(ifname)
    on_exit(fn -> Tap.close(tap) end)
    {:ok, ifname: ifname, tap: tap}
  end

  # frames of the BEAM's own host, answering what the kernel asks for; returns what was seen
  defp serve(tap, ms, seen \\ []) do
    receive do
      {:ex_net_tap, ^tap, frame} ->
        reply(tap, frame)
        serve(tap, ms, [frame | seen])
    after
      ms -> Enum.reverse(seen)
    end
  end

  defp reply(tap, frame) do
    with {:ok, eth} <- Ethernet.decode(frame) do
      case eth do
        %{ethertype: 0x0806} -> arp(tap, eth)
        %{ethertype: 0x0800} -> icmp(tap, eth)
        _ -> :ok
      end
    end
  end

  defp arp(tap, eth) do
    with {:ok, %ARP{op: :request, tpa: @ip} = req} <- ARP.decode(eth.payload) do
      rep = %ARP{op: :reply, sha: @mac, spa: @ip, tha: req.sha, tpa: req.spa}

      Tap.write(
        tap,
        Ethernet.encode(%Ethernet{
          dst: req.sha,
          src: @mac,
          ethertype: 0x0806,
          payload: ARP.encode(rep)
        })
      )
    end
  end

  defp icmp(tap, eth) do
    with {:ok, %IPv4{protocol: 1, dst: @ip} = ip} <- IPv4.decode(eth.payload),
         <<8, 0, _::16, rest::binary>> <- ip.payload do
      body = <<0, 0, 0::16, rest::binary>>
      <<a::binary-size(2), _::16, b::binary>> = body
      echo = <<a::binary, Checksum.checksum(body)::16, b::binary>>
      out = %{ip | src: @ip, dst: ip.src, payload: echo, id: 0}

      Tap.write(
        tap,
        Ethernet.encode(%Ethernet{
          dst: eth.src,
          src: @mac,
          ethertype: 0x0800,
          payload: IPv4.encode(out)
        })
      )
    end
  end

  test "interface helpers see the TAP", %{ifname: ifname} do
    assert {:ok, <<_, _::40>> = mac} = Netif.mac(ifname)
    refute Ethernet.multicast_mac?(mac)
    assert Netif.mtu(ifname) == {:ok, 1500}
    assert Netif.up?(ifname)
    assert {:ok, [{{10, 0, 0, 1}, {255, 255, 255, 0}}]} = Netif.ipv4_addresses(ifname)
  end

  test "a second open is refused while the first is open, and works after close", %{
    ifname: ifname,
    tap: tap
  } do
    assert Tap.open(ifname) == {:error, :ebusy}
    :ok = Tap.close(tap)
    assert Tap.open("nonexist0") == {:error, :enoent}
    assert {:ok, again} = retry(fn -> Tap.open(ifname) end)
    Tap.close(again)
  end

  defp retry(fun, n \\ 20) do
    case fun.() do
      {:error, :ebusy} when n > 0 ->
        Process.sleep(50)
        retry(fun, n - 1)

      other ->
        other
    end
  end

  test "ping from the kernel: ARP and ICMP echo are answered from the BEAM", %{tap: tap} do
    task =
      Task.async(fn ->
        System.cmd("ping", ["-c", "3", "-i", "0.3", "-W", "3", "10.0.0.2"],
          stderr_to_stdout: true
        )
      end)

    seen = serve(tap, 2500)
    {out, status} = Task.await(task, 30_000)
    assert status == 0, out
    assert out =~ "3 received"

    decoded = for f <- seen, {:ok, e} <- [Ethernet.decode(f)], do: e

    reqs =
      for %{ethertype: 0x0806} = e <- decoded,
          {:ok, %ARP{op: :request, tpa: @ip}} <- [ARP.decode(e.payload)],
          do: e

    assert [first | _] = reqs
    assert first.dst == Ethernet.broadcast()

    echoes =
      for %{ethertype: 0x0800} = e <- decoded,
          {:ok, %IPv4{protocol: 1, dst: @ip}} <- [IPv4.decode(e.payload)],
          do: e

    assert length(echoes) >= 3
    assert Enum.all?(echoes, &(&1.dst == @mac))
  end

  test "a join from the kernel: helpers, hash and the IGMP frame", %{ifname: ifname, tap: tap} do
    group = {239, 69, 7, 9}
    gmac = Ethernet.multicast_mac(group)
    {:ok, before_hash} = ExNet.Multicast.mc_hash_of(ifname)
    refute group in elem(Netif.joined_groups(ifname), 1)
    refute gmac in elem(Netif.multicast_macs(ifname), 1)

    {:ok, sock} = :gen_udp.open(0, [:binary, add_membership: {group, {10, 0, 0, 1}}])
    assert group in elem(Netif.joined_groups(ifname), 1)
    assert {:ok, macs} = Netif.multicast_macs(ifname)
    assert gmac in macs
    {:ok, hash} = ExNet.Multicast.mc_hash_of(ifname)
    assert Bitwise.band(hash, Bitwise.bsl(1, ExNet.Multicast.hash(gmac))) != 0
    assert Bitwise.band(hash, before_hash) == before_hash

    seen = serve(tap, 1500)
    groups = igmp_groups(seen)
    assert group in groups

    # the ownership rule: the kernel's records for a hardware-owned group are removed
    frames = for f <- seen, igmp?(f), do: f
    joins = for f <- frames, group in igmp_groups([f]), do: f
    assert joins != []
    assert Enum.all?(joins, &(ExNet.IGMP.Filter.filter(&1, [group]) == :drop))

    :gen_udp.close(sock)
    seen = serve(tap, 1500)
    refute group in elem(Netif.joined_groups(ifname), 1)
    assert group in igmp_groups(seen)
  end

  test "a link-layer multicast address added with ip maddr shows up", %{ifname: ifname} do
    mac = <<1, 0, 0x5E, 9, 9, 9>>
    {_, 0} = System.cmd("ip", ["maddr", "add", Ethernet.format_mac(mac), "dev", ifname])
    assert mac in elem(Netif.multicast_macs(ifname), 1)
    {:ok, hash} = ExNet.Multicast.mc_hash_of(ifname)
    assert Bitwise.band(hash, Bitwise.bsl(1, ExNet.Multicast.hash(mac))) != 0
    {_, 0} = System.cmd("ip", ["maddr", "del", Ethernet.format_mac(mac), "dev", ifname])
    refute mac in elem(Netif.multicast_macs(ifname), 1)
  end

  test "owner death stops the Tap", %{ifname: ifname, tap: tap} do
    :ok = Tap.close(tap)
    me = self()

    owner =
      spawn(fn ->
        {:ok, t} = retry(fn -> Tap.open(ifname) end)
        send(me, {:tap, t})
        Process.sleep(:infinity)
      end)

    assert_receive {:tap, t}, 5000
    ref = Process.monitor(t)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^t, :normal}, 5000
  end

  defp igmp?(frame) do
    with {:ok, %{ethertype: 0x0800, payload: p}} <- Ethernet.decode(frame),
         {:ok, %IPv4{protocol: 2}} <- IPv4.decode(p) do
      true
    else
      _ -> false
    end
  end

  # groups named by the IGMP frames among `frames` (v2 reports and leaves, v3 records)
  defp igmp_groups(frames) do
    for f <- frames, igmp?(f), reduce: [] do
      acc ->
        {:ok, eth} = Ethernet.decode(f)
        {:ok, ip} = IPv4.decode(eth.payload)

        case IGMP.decode(ip.payload) do
          {:ok, %IGMP.ReportV3{records: rs}} -> Enum.map(rs, & &1.group) ++ acc
          {:ok, %{group: g}} -> [g | acc]
          _ -> acc
        end
    end
  end
end
