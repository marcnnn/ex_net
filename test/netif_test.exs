defmodule ExNet.NetifTest do
  use ExUnit.Case, async: true
  alias ExNet.Netif

  doctest ExNet.Netif

  test "the loopback interface" do
    assert Netif.exists?("lo")
    assert Netif.mac("lo") == {:ok, <<0::48>>}
    assert {:ok, mtu} = Netif.mtu("lo")
    assert mtu >= 1500
    assert {:ok, [{{127, 0, 0, 1}, {255, 0, 0, 0}} | _]} = Netif.ipv4_addresses("lo")
    assert {:ok, groups} = Netif.joined_groups("lo")
    assert {224, 0, 0, 1} in groups
    assert {:ok, macs} = Netif.multicast_macs("lo")
    assert Enum.all?(macs, &ExNet.Ethernet.multicast_mac?/1) or macs == []
  end

  test "unknown interfaces and bad names" do
    refute Netif.exists?("nonexist0")
    refute Netif.up?("nonexist0")
    assert Netif.mac("nonexist0") == {:error, :enoent}
    assert Netif.mtu("nonexist0") == {:error, :enoent}
    assert Netif.ipv4_addresses("nonexist0") == {:error, :enoent}
    assert Netif.joined_groups("nonexist0") == {:error, :enoent}
    assert Netif.multicast_macs("nonexist0") == {:error, :enoent}
    assert Netif.mac("../lo") == {:error, :einval}
    assert Netif.mtu("") == {:error, :einval}
  end

  test "parse_igmp picks the lines of one interface" do
    text =
      "Idx\tDevice    : Count Querier\tGroup    Users Timer\tReporter\n" <>
        "1\tlo        :     1      V3\n\t\t\t\t010000E0     1 0:00000000\t\t0\n" <>
        "2\teth0      :     2      V2\n\t\t\t\t0A0145EF     1 0:00000000\t\t0\n" <>
        "\t\t\t\t010000E0     1 0:00000000\t\t0\n"

    assert Netif.parse_igmp(text, "eth0") == [{239, 69, 1, 10}, {224, 0, 0, 1}]
    assert Netif.parse_igmp(text, "lo") == [{224, 0, 0, 1}]
    assert Netif.parse_igmp(text, "tap0") == []
  end
end
