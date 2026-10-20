defmodule ExNet.Ethernet do
  @moduledoc """
  Ethernet II frames with up to two VLAN tags (802.1ad outer, 802.1Q inner).

  Frames exclude preamble and FCS (see `ExNet.MAC` for those). MAC addresses
  are 6-byte binaries, tags are `%{tpid: 0x8100 | 0x88A8, pcp:, dei:, vid:}`.

      iex> alias ExNet.Ethernet
      iex> f = %Ethernet{dst: Ethernet.multicast_mac({239, 69, 1, 2}), src: <<2, 0, 0, 0, 0, 1>>,
      ...>   tags: [%{tpid: 0x8100, pcp: 5, dei: 0, vid: 100}], ethertype: 0x0800, payload: "x"}
      iex> bin = Ethernet.encode(f)
      iex> {:ok, ^f} = Ethernet.decode(bin)
      iex> Ethernet.format_mac(f.dst)
      "01:00:5e:45:01:02"
  """
  alias ExNet.Packets

  @tpid_s 0x88A8
  @tpid_c 0x8100

  defstruct [:dst, :src, :ethertype, tags: [], payload: <<>>]

  @type mac :: <<_::48>>
  @type tag :: %{tpid: 0x8100 | 0x88A8, pcp: 0..7, dei: 0..1, vid: 0..4095}
  @type t :: %__MODULE__{
          dst: mac,
          src: mac,
          ethertype: 0..0xFFFF,
          tags: [tag],
          payload: binary
        }

  @doc "Encodes a frame (no padding, no FCS)."
  @spec encode(t) :: binary
  def encode(%__MODULE__{} = f) do
    tags = Enum.map(f.tags, & &1.tpid) ++ [f.ethertype]
    [first | rest] = tags

    head =
      Packets.encode_header(:eth2, %{
        dst: :binary.decode_unsigned(f.dst),
        src: :binary.decode_unsigned(f.src),
        ethertype: first
      })

    tag_bins =
      f.tags
      |> Enum.zip(rest)
      |> Enum.map(fn {t, next} ->
        Packets.encode_header(:vlan_tag, %{pcp: t.pcp, dei: t.dei, vid: t.vid, ethertype: next})
      end)

    IO.iodata_to_binary([head, tag_bins, f.payload])
  end

  @doc "Decodes a frame; never raises."
  @spec decode(binary) :: {:ok, t} | {:error, atom}
  def decode(bin) when is_binary(bin) do
    with {:ok, h} <- Packets.header(:eth2, bin),
         {:ok, tags, ethertype, payload} <-
           tags(h.ethertype, [], binary_part(bin, 14, byte_size(bin) - 14)) do
      if ethertype < 0x0600 do
        {:error, :llc_frame}
      else
        {:ok,
         %__MODULE__{
           dst: <<h.dst::48>>,
           src: <<h.src::48>>,
           ethertype: ethertype,
           tags: Enum.reverse(tags),
           payload: payload
         }}
      end
    end
  end

  def decode(_), do: {:error, :not_binary}

  defp tags(tpid, acc, bin) when tpid in [@tpid_s, @tpid_c] do
    cond do
      length(acc) == 2 -> {:error, :too_many_tags}
      tpid == @tpid_s and acc != [] -> {:error, :bad_tag_order}
      true -> tag(tpid, acc, bin)
    end
  end

  defp tags(type, acc, bin), do: {:ok, acc, type, bin}

  defp tag(tpid, acc, bin) do
    with {:ok, t} <- Packets.header(:vlan_tag, bin) do
      tag = %{tpid: tpid, pcp: t.pcp, dei: t.dei, vid: t.vid}
      tags(t.ethertype, [tag | acc], binary_part(bin, 4, byte_size(bin) - 4))
    end
  end

  @doc "Header length in bytes for a given number of tags."
  def header_size(ntags), do: 14 + 4 * ntags

  @doc """
  Multicast MAC for an IPv4 group (RFC 1112): `01:00:5e` plus the low 23 bits.

      iex> ExNet.Ethernet.multicast_mac({239, 129, 3, 4})
      <<1, 0, 0x5E, 1, 3, 4>>
  """
  def multicast_mac({a, b, c, d})
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
      do: <<1, 0, 0x5E, 0::1, Bitwise.band(b, 0x7F)::7, c, d>>

  @doc "True for 224.0.0.0/4."
  def multicast_ip?({a, _, _, _}), do: a in 224..239

  @doc "True if the group bit (I/G) of the MAC is set."
  def multicast_mac?(<<_::7, 1::1, _::40>>), do: true
  def multicast_mac?(_), do: false

  @doc "Parses `\"aa:bb:cc:dd:ee:ff\"`; raises on malformed input."
  def mac(str) do
    for p <- String.split(str, ":"), into: <<>>, do: <<String.to_integer(p, 16)>>
  end

  @doc "Formats a MAC as lower-case colon hex."
  def format_mac(<<_::48>> = m),
    do:
      m
      |> :binary.bin_to_list()
      |> Enum.map_join(":", &String.pad_leading(Integer.to_string(&1, 16), 2, "0"))
      |> String.downcase()

  @doc "Broadcast address."
  def broadcast, do: <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
end
