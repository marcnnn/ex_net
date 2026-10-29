defmodule ExNet.Multicast do
  @moduledoc """
  The 6-bit multicast hash of NIC receive filters and the 64-bit `mc_hash`
  register built from a list of multicast MAC addresses.

      hash(mac) = crc32_le(mac) >> 26        (the top 6 bits of the register)
      mc_hash   = OR of (1 << hash(mac))     (bit 0 is the least significant)

  `crc32_le` is the Linux `ether_crc_le(6, mac)`: the reflected CRC-32
  (polynomial 0xEDB88320, `ExNet.CRC32`), register initialised to
  0xFFFFFFFF, bytes in transmission order with the least significant bit
  first, and no final complement. That is `ExNet.CRC32.init/0` followed by
  `step_bytes/2`, without `final/1`. The result is the CRC-32 of the usual
  Ethernet FCS before its final inversion: with Python,
  `zlib.crc32(mac) ^ 0xFFFFFFFF`. Taking the top 6 bits of that 32 bit value
  is what `ether_crc_le(ETH_ALEN, addr) >> 26` does in drivers that keep a
  64 entry hash table in two 32 bit registers (bit `n` of the table is bit
  `n mod 32` of register `n div 32`; `mc_hash` is the same table as one
  64 bit value). Drivers that hash with the big endian `ether_crc` use a
  different table; the card uses the little endian one.

  Example, for 01:00:5e:00:00:01 (224.0.0.1): `crc32_le` is 0xD9B4C5FE, the
  top 6 bits are 0b110110 = 54, so `mc_hash/1` of that single address is
  `1 <<< 54`.

      iex> ExNet.Multicast.hash(<<1, 0, 0x5E, 0, 0, 1>>)
      54
      iex> ExNet.Multicast.mc_hash([<<1, 0, 0x5E, 0, 0, 1>>]) == Bitwise.bsl(1, 54)
      true
  """
  import Bitwise

  @doc "The register of `ether_crc_le(6, mac)` (32 bit, no final complement)."
  @spec crc32_le(<<_::48>>) :: non_neg_integer
  def crc32_le(<<_::48>> = mac), do: ExNet.CRC32.init() |> ExNet.CRC32.step_bytes(mac)

  @doc "The 6-bit hash `crc32_le(mac) >> 26` (0..63)."
  @spec hash(<<_::48>>) :: 0..63
  def hash(<<_::48>> = mac), do: crc32_le(mac) >>> 26

  @doc """
  The 64-bit `mc_hash` for a list of multicast MACs: bit `hash(mac)` set for
  every address. An empty list gives 0 (no multicast passes).
  """
  @spec mc_hash([<<_::48>>]) :: non_neg_integer
  def mc_hash(macs), do: Enum.reduce(macs, 0, fn mac, acc -> acc ||| 1 <<< hash(mac) end)

  @doc """
  `mc_hash/1` of the multicast list the kernel keeps for an interface
  (`ExNet.Netif.multicast_macs/1`).
  """
  @spec mc_hash_of(String.t()) :: {:ok, non_neg_integer} | {:error, atom}
  def mc_hash_of(ifname) do
    with {:ok, macs} <- ExNet.Netif.multicast_macs(ifname), do: {:ok, mc_hash(macs)}
  end
end
