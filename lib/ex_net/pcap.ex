defmodule ExNet.Pcap do
  @moduledoc """
  Classic pcap (little-endian, microsecond, linktype Ethernet) writer and
  reader, to hand test frames to `tshark` or Wireshark.

      iex> bin = ExNet.Pcap.encode([<<1, 2, 3>>, <<4, 5>>])
      iex> ExNet.Pcap.decode(bin)
      {:ok, [<<1, 2, 3>>, <<4, 5>>]}
  """

  def encode(frames, opts \\ []) do
    ts = Keyword.get(opts, :timestamp, 1_700_000_000)

    recs =
      for {f, i} <- Enum.with_index(frames), into: <<>> do
        n = byte_size(f)
        <<ts::little-32, i::little-32, n::little-32, n::little-32, f::binary>>
      end

    <<0xA1B2C3D4::little-32, 2::little-16, 4::little-16, 0::little-32, 0::little-32,
      65535::little-32, 1::little-32, recs::binary>>
  end

  def decode(<<0xA1B2C3D4::little-32, _::binary-size(16), 1::little-32, rest::binary>>),
    do: records(rest, [])

  def decode(_), do: {:error, :bad_pcap}

  defp records(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp records(<<_::64, n::little-32, _::32, f::binary-size(n), rest::binary>>, acc),
    do: records(rest, [f | acc])

  defp records(_, _), do: {:error, :truncated}

  def write!(path, frames, opts \\ []), do: File.write!(path, encode(frames, opts))
end
