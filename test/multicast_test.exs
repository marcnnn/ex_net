defmodule ExNet.MulticastTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias ExNet.{Ethernet, Multicast}

  doctest ExNet.Multicast

  # crc32_le = zlib.crc32(mac) ^ 0xFFFFFFFF (Python), hash = crc32_le >> 26
  @known [
    {"01:00:5e:00:00:01", 0xD9B4C5FE, 54},
    {"01:00:5e:7f:00:01", 0x8619EA93, 33},
    {"33:33:00:00:00:01", 0x5D55D99F, 23},
    {"ff:ff:ff:ff:ff:ff", 0xBE2612FF, 47},
    {"01:00:5e:45:01:02", 0x2FF7EA2E, 11}
  ]

  test "ether_crc_le known values" do
    for {mac, crc, hash} <- @known do
      assert Multicast.crc32_le(Ethernet.mac(mac)) == crc
      assert Multicast.hash(Ethernet.mac(mac)) == hash
    end
  end

  test "crc32_le is the Ethernet CRC-32 without its final complement" do
    mac = Ethernet.mac("01:00:5e:45:01:02")
    assert bxor(Multicast.crc32_le(mac), 0xFFFFFFFF) == ExNet.CRC32.crc32(mac)
  end

  test "mc_hash sets bit hash(mac) of a 64 bit value" do
    macs = for {m, _, _} <- @known, do: Ethernet.mac(m)
    assert Multicast.mc_hash([]) == 0

    assert Multicast.mc_hash(macs) ==
             for(h <- [54, 33, 23, 47, 11], reduce: 0, do: (acc -> acc ||| 1 <<< h))

    assert Multicast.mc_hash(macs ++ macs) == Multicast.mc_hash(macs)
    assert Multicast.mc_hash(macs) < 1 <<< 64
  end

  test "hash is always 0..63 and mc_hash is the union" do
    for i <- 0..255 do
      mac = <<1, 0, 0x5E, 0, 0, i>>
      assert Multicast.hash(mac) in 0..63
      assert Multicast.mc_hash([mac]) == 1 <<< Multicast.hash(mac)
    end
  end
end
