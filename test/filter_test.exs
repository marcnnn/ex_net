defmodule ExNet.FilterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExNet.{ARP, Ethernet, Filter, Frames, Gen}

  doctest ExNet.Filter

  @aes67 {239, 69, 1, 1}
  @host_mac <<2, 0, 0, 0, 0, 0x99>>

  defp table do
    Filter.new(default: :drop)
    |> Filter.add(%{dst_mac: @host_mac}, :host)
    |> Filter.add(%{ip_dst: @aes67, udp_dst_port: 5004}, {:stream, 0})
    |> Filter.add(%{ip_dst: @aes67, udp_dst_port: 6000..6009}, {:stream, 1})
    |> Filter.add(%{ethertype: 0x88F7}, :host)
    |> Filter.add(%{ethertype: 0x0806, multicast: true}, :host)
    |> Filter.add(%{ip_dst: {224, 0, 0, 251}, udp_dst_port: 5353}, :host)
    |> Filter.add(%{multicast: true, ip_proto: 17}, :drop)
  end

  test "stream steering by group and runtime-configured port" do
    f = table()
    assert Filter.classify(f, Frames.udp_frame()) == {:stream, 0}
    assert Filter.classify(f, Frames.udp_frame(dst_port: 6004)) == {:stream, 1}
    assert Filter.classify(f, Frames.udp_frame(dst_port: 6010)) == :drop
    assert Filter.classify(f, Frames.udp_frame(dst_port: 5005)) == :drop
    assert Filter.classify(f, Frames.udp_frame(dst_ip: {239, 69, 1, 2})) == :drop
  end

  test "VLAN tags and IPv4 options do not move the match (CRIT-01)" do
    f = table()
    one = [%{tpid: 0x8100, pcp: 5, dei: 0, vid: 20}]
    two = [%{tpid: 0x88A8, pcp: 0, dei: 0, vid: 7}, %{tpid: 0x8100, pcp: 5, dei: 0, vid: 20}]
    opts = <<0x94, 4, 0, 0, 1, 1, 1, 1>>

    for tags <- [[], one, two], options <- [<<>>, opts] do
      frame = Frames.udp_frame(tags: tags, options: options)
      assert Filter.classify(f, frame) == {:stream, 0}, inspect({tags, options})
      assert Filter.key(frame).vlan == tags |> List.first() |> then(&(&1 && &1.vid))
    end
  end

  test "VLAN rules" do
    f =
      Filter.new()
      |> Filter.add(%{vlan: 20}, :host)
      |> Filter.add(%{ethertype: 0x0800}, {:stream, 2})

    assert Filter.classify(f, Frames.udp_frame(tags: [%{tpid: 0x8100, pcp: 0, dei: 0, vid: 20}])) ==
             :host

    assert Filter.classify(f, Frames.udp_frame(tags: [%{tpid: 0x8100, pcp: 0, dei: 0, vid: 21}])) ==
             {:stream, 2}

    assert Filter.classify(f, Frames.udp_frame()) == {:stream, 2}
  end

  test "fragments never match UDP port rules" do
    f = table()
    assert Filter.classify(f, Frames.udp_frame(mf: true)) == :drop
    assert Filter.classify(f, Frames.udp_frame(frag_offset: 10)) == :drop

    assert %{fragment: true, udp_dst_port: nil, ip_dst: @aes67} =
             Filter.key(Frames.udp_frame(mf: true))
  end

  test "first match wins, rule index reported, default applies" do
    f = table()
    assert {{:stream, 0}, 1} = Filter.classify_rule(f, Frames.udp_frame(), true)
    assert {:drop, nil} = Filter.classify_rule(f, Frames.udp_frame(), false)
    assert {:drop, 6} = Filter.classify_rule(f, Frames.udp_frame(dst_port: 1), true)
    assert Filter.classify(Filter.new(default: :host), <<1, 2, 3>>) == :host
  end

  test "dst mac exact, masked, multicast" do
    unicast = Frames.udp_frame(dst_mac: @host_mac, dst_ip: {10, 0, 0, 9})
    f = table()
    assert Filter.classify(f, unicast) == :host

    m =
      Filter.new()
      |> Filter.add(%{dst_mac: {<<1, 0, 0x5E, 0, 0, 0>>, <<255, 255, 255, 0, 0, 0>>}}, :host)

    assert Filter.classify(m, Frames.udp_frame()) == :host
    assert Filter.classify(m, unicast) == :drop

    bcast = %Ethernet{
      dst: Ethernet.broadcast(),
      src: <<2, 0, 0, 0, 0, 1>>,
      ethertype: 0x0806,
      payload: arp()
    }

    assert Filter.classify(f, Ethernet.encode(bcast)) == :host
    ucast_arp = %{bcast | dst: @host_mac}
    assert Filter.classify(f, Ethernet.encode(ucast_arp)) == :host
    other = %{bcast | dst: <<2, 0, 0, 0, 0, 5>>}
    assert Filter.classify(f, Ethernet.encode(other)) == :drop
  end

  test "ptp over ethernet and mdns reach the host, other multicast udp is dropped" do
    f = table()

    ptp = %Ethernet{
      dst: Ethernet.mac("01:1b:19:00:00:00"),
      src: <<2, 0, 0, 0, 0, 1>>,
      ethertype: 0x88F7,
      payload: <<0::200>>
    }

    assert Filter.classify(f, Ethernet.encode(ptp)) == :host
    mdns = Frames.udp_frame(dst_ip: {224, 0, 0, 251}, dst_port: 5353)
    assert Filter.classify(f, mdns) == :host
    ssdp = Frames.udp_frame(dst_ip: {239, 255, 255, 250}, dst_port: 1900)
    assert Filter.classify(f, ssdp) == :drop
  end

  test "bad IP header checksum yields no IP fields" do
    <<pre::binary-size(14), ip::binary>> = Frames.udp_frame()
    <<a::binary-size(10), ck::16, rest::binary>> = ip
    bad = <<pre::binary, a::binary, Bitwise.bxor(ck, 1)::16, rest::binary>>
    assert %{ip_dst: nil, udp_dst_port: nil, ethertype: 0x0800} = Filter.key(bad)
    assert Filter.classify(table(), bad) == :drop
  end

  test "bad action is rejected" do
    assert_raise ArgumentError, fn -> Filter.add(Filter.new(), %{vlan: 1}, :nowhere) end
    assert_raise ArgumentError, fn -> Filter.add(Filter.new(), %{vlan: 1}, {:stream, -1}) end
  end

  property "random frames never raise and always yield a valid action" do
    f = table()

    check all(bin <- binary(max_length: 120), fcs_ok <- boolean()) do
      assert Filter.classify(f, bin, fcs_ok) in [:drop, :host, {:stream, 0}, {:stream, 1}]
    end
  end

  property "keys of valid frames agree with the layered decoders" do
    check all(f <- Gen.eth_frame()) do
      key = Filter.key(Ethernet.encode(f))
      assert key.dst_mac == f.dst
      assert key.ethertype == f.ethertype
      assert key.vlan == f.tags |> List.first() |> then(&(&1 && &1.vid))
    end
  end

  defp arp,
    do:
      ARP.encode(%ARP{
        op: :request,
        sha: <<2, 0, 0, 0, 0, 1>>,
        spa: {10, 0, 0, 1},
        tha: <<0::48>>,
        tpa: {10, 0, 0, 2}
      })
end
