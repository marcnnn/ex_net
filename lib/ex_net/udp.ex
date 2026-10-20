defmodule ExNet.UDP do
  @moduledoc """
  UDP datagrams with the IPv4 pseudo-header checksum.

  `encode/4` computes the length and, unless `checksum: false`, the checksum
  (a computed 0 is sent as 0xFFFF). A received checksum of 0 means "none" and
  is accepted. `decode/3` verifies the checksum only when both addresses are
  given.

      iex> src = {10, 0, 0, 1}
      iex> dst = {239, 69, 1, 1}
      iex> bin = ExNet.UDP.encode(%ExNet.UDP{src_port: 5004, dst_port: 5004, payload: "rtp"}, src, dst)
      iex> {:ok, d} = ExNet.UDP.decode(bin, src, dst)
      iex> {d.dst_port, d.payload, d.checksum_present}
      {5004, "rtp", true}
  """
  alias ExNet.{Checksum, IPv4, Packets}

  defstruct [:src_port, :dst_port, payload: <<>>, checksum_present: true]

  @protocol 17
  def protocol, do: @protocol

  def encode(%__MODULE__{} = u, src_ip, dst_ip, opts \\ []) do
    len = 8 + byte_size(u.payload)
    if len > 0xFFFF, do: raise(ArgumentError, "UDP datagram longer than 65535 bytes")
    fields = %{src_port: u.src_port, dst_port: u.dst_port, length: len, checksum: 0}
    bin = Packets.encode_header(:udp, fields) <> u.payload

    if Keyword.get(opts, :checksum, u.checksum_present) do
      sum =
        case Checksum.checksum(bin, pseudo(src_ip, dst_ip, len)) do
          0 -> 0xFFFF
          s -> s
        end

      <<h::binary-size(6), _::16, rest::binary>> = bin
      <<h::binary, sum::16, rest::binary>>
    else
      bin
    end
  end

  def decode(bin, src_ip \\ nil, dst_ip \\ nil)

  def decode(bin, src_ip, dst_ip) when is_binary(bin) do
    with {:ok, h} <- Packets.header(:udp, bin),
         :ok <- check_len(h.length, byte_size(bin)),
         dgram = binary_part(bin, 0, h.length),
         :ok <- check_sum(dgram, h.checksum, src_ip, dst_ip) do
      {:ok,
       %__MODULE__{
         src_port: h.src_port,
         dst_port: h.dst_port,
         payload: binary_part(dgram, 8, h.length - 8),
         checksum_present: h.checksum != 0
       }}
    end
  end

  def decode(_, _, _), do: {:error, :not_binary}

  defp check_len(len, _) when len < 8, do: {:error, :bad_length}
  defp check_len(len, size) when len > size, do: {:error, :truncated}
  defp check_len(_, _), do: :ok

  defp check_sum(_, 0, _, _), do: :ok
  defp check_sum(_, _, nil, _), do: :ok
  defp check_sum(_, _, _, nil), do: :ok

  defp check_sum(d, _, s, t),
    do: if(Checksum.valid?(d, pseudo(s, t, byte_size(d))), do: :ok, else: {:error, :bad_checksum})

  # Pseudo-header sum: addresses, zero + protocol, UDP length
  defp pseudo(src, dst, len),
    do: Checksum.sum(<<IPv4.ip_int(src)::32, IPv4.ip_int(dst)::32, 0, @protocol, len::16>>)
end
