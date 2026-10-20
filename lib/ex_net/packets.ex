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
    header do
      field(:dst, 48)
      field(:src, 48)
      field(:ethertype, 16)
    end

    payload(:data, type: :u8)
  end

  # 802.1Q / 802.1ad tag after the TPID: TCI, then the next EtherType
  defpacket :vlan_tag, bus_width: 32 do
    header do
      field(:pcp, 3)
      field(:dei, 1)
      field(:vid, 12)
      field(:ethertype, 16)
    end

    payload(:data, type: :u8)
  end

  # IPv4 header without options (IHL = 5)
  defpacket :ipv4, bus_width: 32 do
    header do
      field(:version, 4, assert: 4)
      field(:ihl, 4)
      field(:dscp, 6)
      field(:ecn, 2)
      field(:total_length, 16)
      field(:id, 16)
      field(:reserved, 1)
      field(:df, 1)
      field(:mf, 1)
      field(:frag_offset, 13)
      field(:ttl, 8)
      field(:protocol, 8)
      field(:checksum, 16)
      field(:src, 32)
      field(:dst, 32)
    end

    payload(:data, type: :u8)
  end

  defpacket :udp, bus_width: 32 do
    header do
      field(:src_port, 16)
      field(:dst_port, 16)
      field(:length, 16)
      field(:checksum, 16)
    end

    payload(:data, type: :u8)
  end

  # IGMPv1/v2 message, also the first 8 bytes of a v3 query
  defpacket :igmp, bus_width: 32 do
    header do
      field(:type, 8)
      field(:max_resp, 8)
      field(:checksum, 16)
      field(:group, 32)
    end

    payload(:data, type: :u8)
  end

  defpacket :arp, bus_width: 32 do
    header do
      field(:htype, 16, assert: 1)
      field(:ptype, 16, assert: 0x0800)
      field(:hlen, 8, assert: 6)
      field(:plen, 8, assert: 4)
      field(:oper, 16)
      field(:sha, 48)
      field(:spa, 32)
      field(:tha, 48)
      field(:tpa, 32)
    end

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
