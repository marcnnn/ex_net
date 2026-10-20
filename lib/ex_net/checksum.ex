defmodule ExNet.Checksum do
  @moduledoc """
  Internet checksum (RFC 1071), shared by IPv4, UDP and IGMP.

      iex> ExNet.Checksum.checksum(<<0x45, 0, 0, 0x73, 0, 0, 0x40, 0, 0x40, 0x11, 0, 0, 0xC0, 0xA8, 0, 1, 0xC0, 0xA8, 0, 0xC7>>)
      0xB861
  """
  import Bitwise

  @doc "Folded 16-bit one's complement sum; odd lengths are padded with a zero byte."
  def sum(bin, acc \\ 0)
  def sum(<<w::16, rest::binary>>, acc), do: sum(rest, acc + w)
  def sum(<<b>>, acc), do: fold(acc + (b <<< 8))
  def sum(<<>>, acc), do: fold(acc)

  @doc "The checksum field value for `bin` (whose checksum field must be zero)."
  def checksum(bin, acc \\ 0), do: bxor(sum(bin, acc), 0xFFFF)

  @doc "True if `bin` (checksum field included) sums to 0xFFFF."
  def valid?(bin, acc \\ 0), do: sum(bin, acc) == 0xFFFF

  defp fold(s) when s > 0xFFFF, do: fold((s &&& 0xFFFF) + (s >>> 16))
  defp fold(s), do: s
end
