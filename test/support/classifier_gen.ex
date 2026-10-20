defmodule ExNet.ClassifierGen do
  @moduledoc false
  # Frame, rule and stimulus generators plus the BEAM-model expectations for the RX classifier tests.
  import StreamData
  import Bitwise
  alias ExNet.{Ethernet, Filter, Gen, IPv4, Packets, UDP}

  @window_bytes 96

  # -- frames ---------------------------------------------------------------------------

  @doc "Random frames: UDP/IPv4 (tags, options, fragments), plain Ethernet, garbage; some mutated, truncated or padded."
  def frame do
    frequency([
      {5, udp_frame()},
      {1, map(Gen.eth_frame(), &Ethernet.encode/1)},
      {1, binary(min_length: 1, max_length: 100)}
    ])
    |> bind(fn f -> map(mutation(byte_size(f)), &mutate(f, &1)) end)
    |> bind(fn f -> map(boolean(), fn pad -> if pad, do: pad60(f), else: f end) end)
    |> filter(&model_exact?/1, 200)
  end

  defp pad60(f) when byte_size(f) < 60, do: f <> :binary.copy(<<0>>, 60 - byte_size(f))
  defp pad60(f), do: f

  # frames longer than the capture window with an IP total length beyond the frame are
  # the documented deviation (the model calls them truncated)
  defp model_exact?(f) do
    byte_size(f) <= @window_bytes or
      case Ethernet.decode(f) do
        {:ok, %{ethertype: 0x0800, payload: p}} -> IPv4.decode(p) != {:error, :truncated}
        _ -> true
      end
  end

  def udp_frame do
    fixed_map(%{
      tags: Gen.tags(),
      ip: Gen.ipv4(),
      udp: Gen.udp(),
      dst: member_of([{239, 69, 1, 1}, {239, 69, 1, 2}, {10, 0, 0, 9}, {1, 2, 3, 4}]),
      src: member_of([{10, 0, 0, 1}, {192, 168, 1, 7}]),
      dport: one_of([member_of([5004, 5005, 319]), integer(0..65535)]),
      proto: member_of([17, 17, 17, 17, 17, 17, 17, 17, 6, 1]),
      frag: member_of(List.duplicate({false, 0}, 8) ++ [{true, 0}, {false, 100}]),
      etype: member_of(List.duplicate(0x0800, 10) ++ [0x0806, 0x86DD]),
      dmac: one_of([constant(:mc), constant(:bc), map(Gen.mac(), &{:rand, &1})])
    })
    |> map(fn s ->
      {udp, _, _} = s.udp
      udp = %{udp | dst_port: s.dport}
      ub = UDP.encode(udp, s.src, s.dst)
      {mf, off} = s.frag

      ip =
        IPv4.encode(%{
          s.ip
          | src: s.src,
            dst: s.dst,
            protocol: s.proto,
            mf: mf,
            frag_offset: off,
            payload: ub
        })

      mac =
        case s.dmac do
          :mc -> Ethernet.multicast_mac(s.dst)
          :bc -> Ethernet.broadcast()
          {:rand, m} -> m
        end

      Ethernet.encode(%Ethernet{
        dst: mac,
        src: <<2, 0, 0, 0, 0, 1>>,
        tags: s.tags,
        ethertype: s.etype,
        payload: ip
      })
    end)
  end

  defp mutation(size) do
    lim = min(size, @window_bytes)

    frequency([
      {12, constant(:none)},
      {3, map({integer(0..(lim - 1)), integer(1..255)}, fn {i, x} -> {:flip, i, x} end)},
      {2, map(integer(1..lim), &{:cut, &1})}
    ])
  end

  defp mutate(f, :none), do: f

  defp mutate(f, {:flip, i, x}) do
    <<a::binary-size(i), b, rest::binary>> = f
    <<a::binary, bxor(b, x), rest::binary>>
  end

  defp mutate(f, {:cut, n}), do: binary_part(f, 0, n)

  # -- stimulus -------------------------------------------------------------------------

  @doc "Input beats of a frame (64-bit, lane 0 = first byte)."
  def beats(frame, bad \\ false) do
    chunks = frame |> :binary.bin_to_list() |> Enum.chunk_every(8)
    last = length(chunks) - 1

    for {ch, i} <- Enum.with_index(chunks) do
      d = ch |> Enum.with_index() |> Enum.reduce(0, fn {x, k}, a -> a ||| x <<< (8 * k) end)

      %{
        s_tdata: d,
        s_tkeep: (1 <<< length(ch)) - 1,
        s_tlast: b(i == last),
        s_tuser: if(i == last and bad, do: 1, else: 0),
        s_tvalid: 1
      }
    end
  end

  defp b(true), do: 1
  defp b(false), do: 0

  @doc """
  Events for `frames` (`{frame, bad, gap}`) after programming `filter`; returns
  `{events, starts}`, `starts` the event index of each frame's first beat. A frame is
  followed by at least `gap` idle cycles and enough to reach a period of 4 cycles.
  """
  def stimulus(filter, frames, n, sb, tail \\ 24) do
    cfg = for {a, d} <- program(filter, n, sb), do: %{cfg_we: 1, cfg_addr: a, cfg_data: d}
    pre = cfg ++ List.duplicate(%{}, 3)

    {rev, starts, _} =
      Enum.reduce(frames, {Enum.reverse(pre), [], length(pre)}, fn {f, bad, gap},
                                                                   {acc, st, pos} ->
        bs = beats(f, bad)
        idle = max(gap, 4 - length(bs))
        evs = bs ++ List.duplicate(%{}, idle)
        {Enum.reverse(evs, acc), [pos | st], pos + length(evs)}
      end)

    {Enum.reverse(rev) ++ List.duplicate(%{}, tail), Enum.reverse(starts)}
  end

  # -- table programming -------------------------------------------------------------------

  @doc "`{cfg_addr, cfg_data}` writes for the rules and default of `filter` (entry words 1..7 before word 0)."
  def program(%Filter{rules: rules, default: default}, n, sb) do
    rules = Enum.take(rules, n)

    entries =
      for {{m, action}, i} <- Enum.with_index(rules) do
        {w0, rest} = entry_words(m, action, sb)
        for({w, d} <- rest, do: {i * 8 + w, d}) ++ [{i * 8, w0}]
      end

    {kind, st} = action_bits(default)
    List.flatten(entries) ++ [{n * 8, kind <<< 1 ||| st <<< 8}]
  end

  defp action_bits(:drop), do: {0, 0}
  defp action_bits(:host), do: {1, 0}
  defp action_bits({:stream, k}), do: {2, k}

  defp entry_words(m, action, _sb) do
    {kind, st} = action_bits(action)
    flags = ExNet.RTL.Classifier.flag_bits()

    {mac, mask} =
      case m[:dst_mac] do
        nil -> {0, 0}
        {v, mk} -> {:binary.decode_unsigned(v), :binary.decode_unsigned(mk)}
        v -> {:binary.decode_unsigned(v), 0xFFFF_FFFF_FFFF}
      end

    {plo, phi} =
      case m[:udp_dst_port] do
        nil -> {0, 0}
        %Range{first: a, last: z} -> {a, z}
        p -> {p, p}
      end

    en = %{
      mac: Map.has_key?(m, :dst_mac),
      mc: Map.has_key?(m, :multicast),
      mcv: m[:multicast] == true,
      vlan: Map.has_key?(m, :vlan),
      et: Map.has_key?(m, :ethertype),
      proto: Map.has_key?(m, :ip_proto),
      ip: Map.has_key?(m, :ip_dst),
      port: Map.has_key?(m, :udp_dst_port)
    }

    w0 =
      Enum.reduce(flags, 1 ||| kind <<< 1 ||| st <<< 8, fn {k, bit}, a ->
        if en[k], do: a ||| 1 <<< bit, else: a
      end)

    ip = if m[:ip_dst], do: IPv4.ip_int(m[:ip_dst]), else: 0

    {w0,
     [
       {1, mac &&& 0xFFFF_FFFF},
       {2, mac >>> 32 ||| (m[:vlan] || 0) <<< 16},
       {3, mask &&& 0xFFFF_FFFF},
       {4, mask >>> 32 ||| (m[:ethertype] || 0) <<< 16},
       {5, ip},
       {6, plo ||| phi <<< 16},
       {7, m[:ip_proto] || 0}
     ]}
  end

  # -- rules ----------------------------------------------------------------------------

  @doc "Filters whose rules are derived from the keys of `frames` (so they hit) plus random fields."
  def filter(frames, max_rules \\ 8) do
    {list_of(rule(frames), max_length: max_rules), action()}
    |> map(fn {rules, default} ->
      Enum.reduce(rules, Filter.new(default: default), fn {m, a}, f -> Filter.add(f, m, a) end)
    end)
  end

  def action,
    do: one_of([constant(:drop), constant(:host), map(integer(0..15), &{:stream, &1})])

  defp rule(frames) do
    bind(member_of(frames), fn fr ->
      key = Filter.key(fr)

      fixed_map(%{
        sel: list_of(member_of([true, false, false]), length: 8),
        mask: one_of([constant(nil), binary(length: 6)]),
        rmac: Gen.mac(),
        mc: boolean(),
        rvid: integer(0..4095),
        rport: integer(0..65535),
        span: integer(0..40),
        rand: boolean(),
        action: action()
      })
      |> map(fn r ->
        [mac?, mc?, vlan?, et?, proto?, ip?, port?, _] = r.sel

        pick = fn k, rnd -> if not r.rand and key[k] != nil, do: key[k], else: rnd end
        mac = pick.(:dst_mac, r.rmac)

        m =
          %{}
          |> put_if(mac?, :dst_mac, if(r.mask, do: {mac, r.mask}, else: mac))
          |> put_if(mc?, :multicast, r.mc)
          |> put_if(vlan?, :vlan, pick.(:vlan, r.rvid))
          |> put_if(et?, :ethertype, pick.(:ethertype, 0x0800))
          |> put_if(proto?, :ip_proto, pick.(:ip_proto, 17))
          |> put_if(ip?, :ip_dst, pick.(:ip_dst, {239, 69, 1, 1}))
          |> put_if(port?, :udp_dst_port, port(pick.(:udp_dst_port, r.rport), r.span))

        {m, r.action}
      end)
    end)
  end

  defp port(p, 0), do: p
  defp port(p, span), do: p..min(p + span, 65535)

  defp put_if(m, true, k, v), do: Map.put(m, k, v)
  defp put_if(m, _, _, _), do: m

  # -- expectations ---------------------------------------------------------------------

  @doc "Expected metadata of `frame` through `filter` (the BEAM models are the contract)."
  def expected(filter, frame, bad) do
    {action, hit} = Filter.classify_rule(filter, frame, not bad)
    {pre_action, pre_hit} = Filter.classify_rule(filter, frame, true)
    fields = fields(frame)

    %{
      pre: Map.merge(fields, verdict(pre_action, pre_hit)),
      final: Map.merge(fields, verdict(action, hit))
    }
  end

  defp verdict(action, hit) do
    {kind, st} = action_bits(action)
    %{m_kind: kind, m_stream: st, m_hit: b(hit != nil), m_hit_index: hit || 0}
  end

  defp fields(frame) do
    base = %{
      m_vlan_id: 0,
      m_vlan_valid: 0,
      m_ntags: 0,
      m_ethertype: 0,
      m_ip_valid: 0,
      m_ip_proto: 0,
      m_src_ip: 0,
      m_dst_ip: 0,
      m_src_port: 0,
      m_dst_port: 0,
      m_payload_valid: 0,
      m_payload_offset: 0
    }

    case Ethernet.decode(frame) do
      {:ok, eth} ->
        vlan = Filter.key(frame).vlan

        base = %{
          base
          | m_vlan_id: vlan || 0,
            m_vlan_valid: b(vlan != nil),
            m_ntags: length(eth.tags),
            m_ethertype: eth.ethertype
        }

        ip_fields(base, eth)

      _ ->
        base
    end
  end

  defp ip_fields(base, %{ethertype: 0x0800, payload: p, tags: tags}) do
    case IPv4.decode(p) do
      {:ok, ip} ->
        base = %{
          base
          | m_ip_valid: 1,
            m_ip_proto: ip.protocol,
            m_src_ip: IPv4.ip_int(ip.src),
            m_dst_ip: IPv4.ip_int(ip.dst)
        }

        with 17 <- ip.protocol,
             false <- ip.fragment,
             {:ok, u} <- Packets.header(:udp, ip.payload) do
          off = Ethernet.header_size(length(tags)) + 20 + byte_size(ip.options) + 8

          %{
            base
            | m_payload_valid: 1,
              m_src_port: u.src_port,
              m_dst_port: u.dst_port,
              m_payload_offset: off
          }
        else
          _ -> base
        end

      _ ->
        base
    end
  end

  defp ip_fields(base, _), do: base
end
