defmodule ExNet.Gen do
  @moduledoc false
  import StreamData
  alias ExNet.{Ethernet, IPv4, UDP}

  def mac, do: binary(length: 6)
  def ip, do: tuple({integer(0..255), integer(0..255), integer(0..255), integer(0..255)})
  def mcast_ip, do: tuple({integer(224..239), integer(0..255), integer(0..255), integer(0..255)})

  def tags do
    one = fn tpid ->
      fixed_map(%{
        tpid: constant(tpid),
        pcp: integer(0..7),
        dei: integer(0..1),
        vid: integer(0..4095)
      })
    end

    one_of([
      constant([]),
      map(one.(0x8100), &[&1]),
      map(one.(0x88A8), &[&1]),
      map({one.(0x88A8), one.(0x8100)}, fn {a, b} -> [a, b] end),
      map({one.(0x8100), one.(0x8100)}, fn {a, b} -> [a, b] end)
    ])
  end

  def ethertype,
    do: filter(integer(0x0600..0xFFFF), &(&1 not in [0x8100, 0x88A8]))

  def eth_frame do
    fixed_map(%{
      dst: mac(),
      src: mac(),
      tags: tags(),
      ethertype: ethertype(),
      payload: binary(max_length: 100)
    })
    |> map(&struct!(Ethernet, &1))
  end

  def ipv4 do
    fixed_map(%{
      src: ip(),
      dst: ip(),
      protocol: integer(0..255),
      dscp: integer(0..63),
      ecn: integer(0..3),
      id: integer(0..65535),
      df: boolean(),
      mf: boolean(),
      frag_offset: integer(0..8191),
      ttl: integer(0..255),
      options: map(list_of(binary(length: 4), max_length: 10), &IO.iodata_to_binary/1),
      payload: binary(max_length: 80)
    })
    |> map(&struct!(IPv4, Map.put(&1, :fragment, &1.mf or &1.frag_offset != 0)))
  end

  def udp(src \\ {10, 0, 0, 1}, dst \\ {239, 1, 2, 3}) do
    fixed_map(%{
      src_port: integer(0..65535),
      dst_port: integer(0..65535),
      payload: binary(max_length: 80)
    })
    |> map(&struct!(UDP, &1))
    |> map(&{&1, src, dst})
  end

  @doc "Random cycles of a GMII-like interface."
  def cycles(max \\ 200),
    do: list_of(tuple({integer(0..255), boolean(), boolean()}), max_length: max)
end

defmodule ExNet.Frames do
  @moduledoc false
  alias ExNet.{Ethernet, IPv4, UDP}

  @src_mac <<2, 0, 0, 0, 0, 1>>

  @doc "Ethernet/IPv4/UDP frame without FCS."
  def udp_frame(opts \\ []) do
    src = Keyword.get(opts, :src_ip, {10, 0, 0, 1})
    dst = Keyword.get(opts, :dst_ip, {239, 69, 1, 1})
    sport = Keyword.get(opts, :src_port, 4000)
    dport = Keyword.get(opts, :dst_port, 5004)
    payload = Keyword.get(opts, :payload, "payload")
    udp = UDP.encode(%UDP{src_port: sport, dst_port: dport, payload: payload}, src, dst)

    ip =
      IPv4.encode(%IPv4{
        src: src,
        dst: dst,
        protocol: 17,
        options: Keyword.get(opts, :options, <<>>),
        mf: Keyword.get(opts, :mf, false),
        frag_offset: Keyword.get(opts, :frag_offset, 0),
        payload: udp
      })

    Ethernet.encode(%Ethernet{
      dst: Keyword.get(opts, :dst_mac, Ethernet.multicast_mac(dst)),
      src: @src_mac,
      tags: Keyword.get(opts, :tags, []),
      ethertype: 0x0800,
      payload: ip
    })
  end
end
