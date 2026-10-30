defmodule ExNet.Packets do
  @moduledoc """
  Fixed-layout headers as `ExHdl.Protocol` packets, so the same definitions
  drive the BEAM codecs and the AXI4-Stream parsers later.

  Variable parts (VLAN stacks, IPv4 options, checksums, lengths) are handled
  by the codecs in `ExNet.Ethernet`, `ExNet.IPv4`, `ExNet.UDP`, `ExNet.IGMP`
  and `ExNet.ARP`, which slice the header bytes and call `header/2`.

      iex> bin = ExNet.Packets.encode_eth2(%{dst: 1, src: 2, ethertype: 0x0800}, [])
      iex> ExNet.Packets.header(:eth2, bin)
      {:ok, %{dst: 1, src: 2, ethertype: 0x0800}}
  """
  use ExHdl.Protocol

  defpacket :eth2, bus_width: 16 do
    header(<<dst::48, src::48, ethertype::16>>)
    payload(:data, type: :u8)
  end

  # 802.1Q / 802.1ad tag after the TPID: TCI, then the next EtherType
  defpacket :vlan_tag, bus_width: 32 do
    header(<<pcp::3, dei::1, vid::12, ethertype::16>>)
    payload(:data, type: :u8)
  end

  # IPv4 header without options (IHL = 5)
  defpacket :ipv4, bus_width: 32 do
    header(
      <<version::4, ihl::4, dscp::6, ecn::2, total_length::16, id::16, reserved::1, df::1, mf::1,
        frag_offset::13, ttl::8, protocol::8, checksum::16, src::32, dst::32>>
      when version == 4
    )

    payload(:data, type: :u8)
  end

  defpacket :udp, bus_width: 32 do
    header(<<src_port::16, dst_port::16, length::16, checksum::16>>)
    payload(:data, type: :u8)
  end

  # IGMPv1/v2 message, also the first 8 bytes of a v3 query
  defpacket :igmp, bus_width: 32 do
    header(<<type::8, max_resp::8, checksum::16, group::32>>)
    payload(:data, type: :u8)
  end

  defpacket :arp, bus_width: 32 do
    header(
      <<htype::16, ptype::16, hlen::8, plen::8, oper::16, sha::48, spa::32, tha::48, tpa::32>>
      when htype == 1 and ptype == 0x0800 and hlen == 6 and plen == 4
    )

    payload(:data, type: :u8)
  end

  @doc """
  Decodes the fixed header of packet `name` from the front of `bin`.
  Returns `{:ok, header}` (fields as integers) or `{:error, reason}`; the payload is not touched.
  """
  def header(name, bin) when is_atom(name) and is_binary(bin) do
    bytes = ExHdl.Protocol.Spec.header_bytes(apply(__MODULE__, name, []))

    case bin do
      <<h::binary-size(bytes), _::binary>> ->
        case apply(__MODULE__, :"decode_#{name}", [h]) do
          {:ok, header, []} -> {:ok, header}
          {:error, _} = e -> e
        end

      _ ->
        {:error, :truncated_header}
    end
  end

  @doc "Encodes just the header of packet `name`."
  def encode_header(name, fields), do: apply(__MODULE__, :"encode_#{name}", [fields, []])
end
