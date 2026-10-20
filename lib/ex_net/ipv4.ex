defmodule ExNet.IPv4 do
  @moduledoc """
  IPv4 packets with options and fragment flags.

  `encode/1` computes IHL, total length and header checksum. `decode/2`
  validates version, IHL, lengths and checksum, and trims link-layer padding
  (frames padded to 60 bytes carry trailing zeros). Fragments are decoded but
  flagged: `fragment: true` if MF is set or the offset is non-zero, so
  upper-layer parsing can be skipped.

      iex> p = %ExNet.IPv4{src: {10, 0, 0, 1}, dst: {239, 1, 1, 1}, protocol: 17, payload: "hi"}
      iex> {:ok, d} = ExNet.IPv4.decode(ExNet.IPv4.encode(p) <> <<0, 0, 0>>)
      iex> {d.payload, d.fragment, d.ttl}
      {"hi", false, 64}
  """
  alias ExNet.{Checksum, Packets}

  defstruct [
    :src,
    :dst,
    :protocol,
    dscp: 0,
    ecn: 0,
    id: 0,
    df: false,
    mf: false,
    frag_offset: 0,
    ttl: 64,
    options: <<>>,
    payload: <<>>,
    fragment: false
  ]

  @type ip :: {0..255, 0..255, 0..255, 0..255}

  @doc "Encodes a packet. Options are zero-padded to a multiple of 4 bytes (max 40)."
  def encode(%__MODULE__{} = p) do
    opts = pad4(p.options)
    ihl = 5 + div(byte_size(opts), 4)
    total = ihl * 4 + byte_size(p.payload)
    if ihl > 15, do: raise(ArgumentError, "IPv4 options longer than 40 bytes")
    if total > 0xFFFF, do: raise(ArgumentError, "IPv4 packet longer than 65535 bytes")

    fields = %{
      ihl: ihl,
      dscp: p.dscp,
      ecn: p.ecn,
      total_length: total,
      id: p.id,
      reserved: 0,
      df: b(p.df),
      mf: b(p.mf),
      frag_offset: p.frag_offset,
      ttl: p.ttl,
      protocol: p.protocol,
      checksum: 0,
      src: ip_int(p.src),
      dst: ip_int(p.dst)
    }

    head = Packets.encode_header(:ipv4, fields) <> opts
    sum = Checksum.checksum(head)
    <<a::binary-size(10), _::16, rest::binary>> = head
    <<a::binary, sum::16, rest::binary, p.payload::binary>>
  end

  @doc "Decodes a packet; `verify_checksum: false` skips the header checksum test."
  def decode(bin, opts \\ [])

  def decode(bin, opts) when is_binary(bin) do
    with {:ok, h} <- Packets.header(:ipv4, bin),
         :ok <- check_ihl(h.ihl, byte_size(bin)),
         hlen = h.ihl * 4,
         :ok <- check_len(h.total_length, hlen, byte_size(bin)),
         head = binary_part(bin, 0, hlen),
         :ok <- check_sum(head, Keyword.get(opts, :verify_checksum, true)) do
      {:ok,
       %__MODULE__{
         src: ip_tuple(h.src),
         dst: ip_tuple(h.dst),
         protocol: h.protocol,
         dscp: h.dscp,
         ecn: h.ecn,
         id: h.id,
         df: h.df == 1,
         mf: h.mf == 1,
         frag_offset: h.frag_offset,
         ttl: h.ttl,
         options: binary_part(head, 20, hlen - 20),
         payload: binary_part(bin, hlen, h.total_length - hlen),
         fragment: h.mf == 1 or h.frag_offset != 0
       }}
    else
      {:error, {:assert_failed, :version, _}} -> {:error, :bad_version}
      {:error, _} = e -> e
    end
  end

  def decode(_, _), do: {:error, :not_binary}

  defp check_ihl(ihl, _) when ihl < 5, do: {:error, :bad_ihl}
  defp check_ihl(ihl, size) when ihl * 4 > size, do: {:error, :truncated_header}
  defp check_ihl(_, _), do: :ok

  defp check_len(total, hlen, _) when total < hlen, do: {:error, :bad_length}
  defp check_len(total, _, size) when total > size, do: {:error, :truncated}
  defp check_len(_, _, _), do: :ok

  defp check_sum(_, false), do: :ok

  defp check_sum(head, true),
    do: if(Checksum.valid?(head), do: :ok, else: {:error, :bad_checksum})

  defp pad4(o), do: o <> :binary.copy(<<0>>, rem(4 - rem(byte_size(o), 4), 4))
  defp b(true), do: 1
  defp b(false), do: 0
  defp b(n) when n in [0, 1], do: n

  @doc "Address tuple to 32-bit integer."
  def ip_int({a, b, c, d}), do: Bitwise.bsl(a, 24) + Bitwise.bsl(b, 16) + Bitwise.bsl(c, 8) + d
  @doc "32-bit integer to address tuple."
  def ip_tuple(n),
    do:
      {Bitwise.band(Bitwise.bsr(n, 24), 255), Bitwise.band(Bitwise.bsr(n, 16), 255),
       Bitwise.band(Bitwise.bsr(n, 8), 255), Bitwise.band(n, 255)}
end
