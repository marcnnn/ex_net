defmodule ExNet.RTL.Classifier do
  @moduledoc """
  RX classifier for a 64-bit AXI4-Stream frame stream (the MAC RX output): parses
  Ethernet (up to two VLAN tags), IPv4 (any IHL, options skipped, header checksum
  verified) and UDP, matches a runtime-written table and attaches the verdict and
  header metadata to the frame. The reference is `ExNet.Filter` (`key/1`,
  `classify_rule/3`); the module is `rxcls_n<entries>_s<stream_bits>_r<slots>`
  (`build/1`, options `entries: 16`, `stream_bits: 4`, `slots: 4`).

  ## Ports (clock `clk`, synchronous active-low reset `rst_n`)

  Input stream, no `tready` (the MAC cannot stall): `s_tdata` (64, byte `k` of the
  frame in bits `8k+7..8k` of beat `k/8`), `s_tkeep` (8, contiguous from lane 0, only
  the last beat may be partial), `s_tlast`, `s_tuser` (4, bit 0 = bad frame, only
  read with `s_tlast`), `s_tvalid`. Beats of one frame are contiguous.

  Table write port: `cfg_we`, `cfg_addr` (`index * 8 + word`, width `ceil(log2(entries + 1)) + 3`),
  `cfg_data` (32). One word per cycle, effective at the next cycle.

  Output stream (all `m_` outputs are combinational from registers, no handshake):
  `m_tdata` (64), `m_tkeep` (8), `m_tlast`, `m_tuser` (4), `m_tvalid`, `m_sof` (first
  beat of a frame). The frame is the input unchanged, headers included, delayed by
  exactly #{14} cycles: the beat on `s_*` in cycle `t` is on `m_*` in cycle `t + 14`;
  gaps are kept. The classifier never stalls and drops nothing itself.

  Metadata, valid in every cycle with `m_tvalid` (constant over the frame, with the
  one exception of the final verdict below); fields that do not apply read 0:

    * `m_kind` (2: 0 drop, 1 host, 2 stream engine), `m_stream` (`stream_bits`),
      `m_hit` (1 = a table entry matched, 0 = default action), `m_hit_index`
    * `m_vlan_id` (12, outermost tag), `m_vlan_valid`, `m_ntags` (0..2),
      `m_ethertype` (16, after all tags, 0 if the Ethernet header is not valid),
      `m_ip_valid`, `m_ip_proto` (8), `m_src_ip`, `m_dst_ip` (32)
    * `m_src_port`, `m_dst_port` (16), `m_payload_valid` (UDP header found, as
      `Filter.key`: protocol 17, unfragmented), `m_payload_offset` (7: byte offset of
      the UDP payload from the start of the frame, i.e. lane `offset % 8` of beat
      `offset / 8`; 22..90, 0 when not valid), `m_payload_len` (16: UDP payload bytes, the
      UDP length minus 8 clamped to what the IP total length leaves, 0 when not valid)
    * `ovf` (sticky): the result queue overflowed (frames shorter than the minimum
      period below)

  Final verdict: on the last beat of a frame whose `s_tuser[0]` (bad FCS) is set,
  `m_kind`, `m_stream`, `m_hit` and `m_hit_index` read drop/0/0/0, as
  `Filter.classify_rule(f, frame, false)`. On all other beats they show the header
  verdict (`fcs_ok = true`). A consumer therefore commits on `m_tlast` using the
  verdict of that beat; the first beat already carries the speculative verdict.

  ## Timing

  Throughput is one beat per cycle. The first 12 beats are captured into `hdr`
  (the maximum header is 90 bytes); the event is the beat 11 or an earlier `tlast`.
  Cycle `e` = event beat on the input; `e + 1`: field extraction (combinational
  over `hdr`, registered); `e + 2`: table match, result pushed into a ring of
  `slots` words; visible from `e + 3` <= `t0 + 14` where `t0` is the first beat.
  The pass-through is a 14 stage register chain, so the verdict is valid when
  the first beat leaves. A new frame may start the cycle after `tlast`; frames
  need a period (beats + idle cycles) of at least `slots` cycles (default 4, 25-32
  bytes), as the Ethernet minimum frame always satisfies.

  ## Table

  Entry `i` (`0..entries-1`, lowest index wins) is eight 32-bit words at `cfg_addr = i * 8 + w`;
  index `entries` word 0 writes the default action. Write words 1..7 first and
  word 0 last, the entry is live while word 0 bit 0 is set:

      w0: [0] valid, [2:1] action kind (0 drop, 1 host, 2 stream, 3 = drop),
          [8 + stream_bits - 1 : 8] stream index, enables: [16] dst_mac, [17] multicast,
          [18] multicast value, [19] vlan, [20] ethertype, [21] ip_proto, [22] ip_dst,
          [23] udp port
      w1: dst_mac[31:0]        w2: [15:0] dst_mac[47:32], [27:16] vlan id
      w3: mac mask[31:0]       w4: [15:0] mask[47:32], [31:16] ethertype
      w5: ip_dst               w6: [15:0] udp port low, [31:16] udp port high (inclusive)
      w7: [7:0] ip_proto

  `dst_mac` is the integer of the 6 bytes in wire order. Matching mirrors
  `ExNet.Filter`: all enabled conditions are ANDed, an absent field never matches an
  enabled condition. The multicast test compares the group bit with the value bit (so
  `multicast: false` is expressible).

  ## Deviations from `ExNet.Filter`

    * `IPv4.decode` rejects a total length larger than the frame. The classifier
      sees only the first 96 bytes, so the check is exact for frames up to 96 bytes
      and skipped for longer ones.
    * UDP ports of a frame are exposed only when the UDP header lies in the IP
      payload per total length (as the model).
  """
  use ExHdl.RTL
  import Bitwise
  alias ExNet.RTL.Ifc
  alias ExNet.{Filter, IPv4}

  @window 12
  @delay 14

  @doc "Pipeline delay of the pass-through in cycles."
  def delay, do: @delay

  @doc "Width of `cfg_addr` for `entries` table entries."
  def addr_width(entries), do: bits(entries + 1) + 3

  @doc "Width of `m_hit_index` for `entries` table entries."
  def hit_width(entries), do: bits(entries)

  @flag_bits [mac: 16, mc: 17, mcv: 18, vlan: 19, et: 20, proto: 21, ip: 22, port: 23]

  @doc "Bit positions of the enable flags in table word 0."
  def flag_bits, do: @flag_bits

  def build(opts \\ []) do
    n = Keyword.get(opts, :entries, 16)
    sb = Keyword.get(opts, :stream_bits, 4)
    slots = Keyword.get(opts, :slots, 4)
    iw = bits(n + 1)
    hw = bits(n)
    pw = bits(slots)
    cw = bits(slots + 1)

    if sb > 8 or sb < 1 or slots < 2 or n < 1,
      do: raise(ArgumentError, "entries >= 1, 1 <= stream_bits <= 8, slots >= 2")

    module "rxcls_n#{n}_s#{sb}_r#{slots}" do
      s = slave(:s, Ifc.mac_rx(64))
      s_data = s.tdata
      s_keep = s.tkeep
      s_last = s.tlast
      s_user = s.tuser
      s_valid = s.tvalid
      cfg_we = input(:cfg_we, 1)
      cfg_addr = input(:cfg_addr, iw + 3)
      cfg_data = input(:cfg_data, 32)

      m = master(:m, Ifc.rx_frame(sb, hw))
      m_ovf = output(:ovf, 1)

      # -- stage A: header capture and event --------------------------------------------
      idx = reg(:idx, 4)
      hdr = for i <- 0..(@window - 1), do: reg(:"hdr#{i}", 64, reset: nil)
      ev_v = reg(:ev_v, 1)
      ev_len = reg(:ev_len, 7, reset: nil)
      ev_more = reg(:ev_more, 1, reset: nil)

      first = wire(:sof_in, s_valid and idx == 0)
      event = wire(:hdr_event, s_valid and (idx == 11 or (s_last and idx < 11)))

      cnt =
        Enum.reduce(1..7, zext(s_keep[0], 4), fn k, acc -> add_wrap(acc, zext(s_keep[k], 4)) end)

      len_last = add_wrap(cat([idx, const(0, 3)]), zext(cnt, 7))

      sync do
        if s_valid do
          for {h, i} <- Enum.with_index(hdr), do: if(idx == i, do: h <~ s_data)

          idx
          <~ mux(s_last, const(0, 4), mux(idx == @window, const(@window, 4), add_wrap(idx, 1)))
        end

        ev_v <~ event

        if event do
          ev_len <~ mux(s_last, len_last, const(96, 7))
          ev_more <~ not s_last
        end
      end

      # -- stage B: field extraction -----------------------------------------------------
      p = parse(hdr, ev_len, ev_more)

      fv = reg(:fv, 1)

      fregs =
        for {k, w} <- field_widths(), into: %{}, do: {k, reg(:"f_#{k}", w, reset: nil)}

      sync do
        fv <~ ev_v
        for {k, r} <- fregs, do: r <~ p[k]
      end

      # -- table -------------------------------------------------------------------------
      wsel = cfg_addr[0..2]
      eidx = cfg_addr[3..(iw + 2)]
      d_kind = reg(:def_kind, 2)
      d_stream = reg(:def_stream, sb)
      we_def = wire(:we_def, cfg_we and eidx == n and wsel == 0)

      sync do
        if we_def do
          d_kind <~ kind_of(cfg_data)
          d_stream <~ cfg_data[8..(7 + sb)]
        end
      end

      ents =
        for i <- 0..(n - 1) do
          we = wire(:"we_#{i}", cfg_we and eidx == i)

          regs =
            for {k, w, _word, _lo} <- entry_fields(sb), into: %{} do
              {k, reg(:"e#{i}_#{k}", w, reset: if(k == :valid, do: 0, else: nil))}
            end

          sync do
            for {k, w, word, lo} <- entry_fields(sb) do
              v = if k == :kind, do: kind_of(cfg_data), else: cfg_data[lo..(lo + w - 1)]
              if we and wsel == word, do: regs[k] <~ v
            end
          end

          regs
        end

      # -- stage C: match and result push ------------------------------------------------
      f = fregs

      hits =
        for e <- ents do
          mac = cat([e.mac_hi, e.mac_lo])
          mask = cat([e.mask_hi, e.mask_lo])

          conds = [
            e.valid,
            not e.mac or (f.macp and (f.mac &&& mask) == (mac &&& mask)),
            not e.mc or (f.macp and f.mac[40] == e.mcv),
            not e.vlan or (f.vlan_v and f.vid == e.vid),
            not e.et or (f.etok and f.etype == e.etype),
            not e.proto or (f.ipok and f.proto == e.proto_v),
            not e.ip or (f.ipok and f.dst == e.ip_dst),
            not e.port or (f.udpok and f.dport >= e.plo and f.dport <= e.phi)
          ]

          Enum.reduce(conds, fn c, acc -> acc and c end)
        end

      init = {const(0, 1), const(0, hw), d_kind, d_stream}

      {hit, hit_idx, kind, stream} =
        ents
        |> Enum.zip(hits)
        |> Enum.with_index()
        |> Enum.reverse()
        |> Enum.reduce(init, fn {{e, ok}, i}, {h, ix, k, s} ->
          {mux(ok, const(1, 1), h), mux(ok, const(i, hw), ix), mux(ok, e.kind, k),
           mux(ok, e.stream, s)}
        end)

      word =
        cat([
          f.src,
          f.dst,
          f.sport,
          f.dport,
          f.vid,
          f.vlan_v,
          f.ntags,
          f.etype_o,
          f.proto_o,
          f.ipok,
          f.poff,
          f.plen,
          f.udpok,
          kind,
          stream,
          hit,
          hit_idx
        ])

      ww = width_of(word)
      slot_regs = for s <- 0..(slots - 1), do: reg(:"slot#{s}", ww, reset: nil)
      wptr = reg(:wptr, pw)
      rptr = reg(:rptr, pw)
      count = reg(:count, cw)
      ovf = reg(:ovf_r, 1)

      # -- pass-through chain ------------------------------------------------------------
      stage =
        for j <- 1..@delay do
          %{
            d: reg(:"d#{j}_data", 64, reset: nil),
            k: reg(:"d#{j}_keep", 8, reset: nil),
            u: reg(:"d#{j}_user", 4, reset: nil),
            l: reg(:"d#{j}_last", 1),
            v: reg(:"d#{j}_valid", 1),
            s: reg(:"d#{j}_sof", 1)
          }
        end

      sync do
        for {st, j} <- Enum.with_index(stage) do
          if j == 0 do
            st.d <~ s_data
            st.k <~ s_keep
            st.u <~ s_user
            st.l <~ (s_valid and s_last)
            st.v <~ s_valid
            st.s <~ first
          else
            pv = Enum.at(stage, j - 1)
            st.d <~ pv.d
            st.k <~ pv.k
            st.u <~ pv.u
            st.l <~ pv.l
            st.v <~ pv.v
            st.s <~ pv.s
          end
        end
      end

      out = List.last(stage)
      pop = wire(:pop_w, out.l)
      push = wire(:push_w, fv and (count < slots or pop))

      sync do
        if push do
          for {sr, s} <- Enum.with_index(slot_regs), do: if(wptr == s, do: sr <~ word)
          wptr <~ mux(wptr == slots - 1, const(0, pw), add_wrap(wptr, 1))
        end

        if pop, do: rptr <~ mux(rptr == slots - 1, const(0, pw), add_wrap(rptr, 1))

        if push and not pop do
          count <~ add_wrap(count, 1)
        else
          if pop and not push, do: count <~ sub_wrap(count, 1)
        end

        if fv and not push, do: ovf <~ 1
      end

      # -- outputs -----------------------------------------------------------------------
      rd = mux(rptr, slot_regs)
      fields = unpack(rd, sb, hw)
      bad_last = wire(:bad_last, out.l and out.u[0])

      m.tdata <~ out.d
      m.tkeep <~ out.k
      m.tlast <~ out.l
      m.tuser <~ out.u
      m.tvalid <~ out.v
      m.sof <~ out.s
      m.kind <~ mux(bad_last, const(0, 2), fields.kind)
      m.stream <~ mux(bad_last, const(0, sb), fields.stream)
      m.hit <~ mux(bad_last, const(0, 1), fields.hit)
      m.hit_index <~ mux(bad_last, const(0, hw), fields.hit_idx)
      m.vlan_id <~ fields.vid
      m.vlan_valid <~ fields.vlan_v
      m.ntags <~ fields.ntags
      m.ethertype <~ fields.etype
      m.ip_valid <~ fields.ipok
      m.ip_proto <~ fields.proto
      m.src_ip <~ fields.src
      m.dst_ip <~ fields.dst
      m.src_port <~ fields.sport
      m.dst_port <~ fields.dport
      m.payload_valid <~ fields.udpok
      m.payload_offset <~ fields.poff
      m.payload_len <~ fields.plen
      m_ovf <~ ovf
    end
  end

  @doc """
  `{cfg_addr, cfg_data}` writes (in order) that program the table of an `n` entry
  classifier with `stream_bits` = `sb` from an `ExNet.Filter` (rules in order, first match
  wins, `default` action in the default slot; at most `n` rules): entry words 1..7 before
  word 0 so an entry goes live atomically.
  """
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
    flags = flag_bits()

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

  # -- helpers -------------------------------------------------------------------------

  @doc false
  def bits(n) when n >= 2, do: length(Integer.digits(n - 1, 2))
  def bits(_), do: 1

  defp width_of(e), do: ExHdl.RTL.Expr.width(e)

  # (name, width, word, low bit) of every table entry register
  defp entry_fields(sb) do
    flags = for {k, b} <- @flag_bits, do: {k, 1, 0, b}

    [
      {:valid, 1, 0, 0},
      {:kind, 2, 0, 1},
      {:stream, sb, 0, 8}
    ] ++
      flags ++
      [
        {:mac_lo, 32, 1, 0},
        {:mac_hi, 16, 2, 0},
        {:vid, 12, 2, 16},
        {:mask_lo, 32, 3, 0},
        {:mask_hi, 16, 4, 0},
        {:etype, 16, 4, 16},
        {:ip_dst, 32, 5, 0},
        {:plo, 16, 6, 0},
        {:phi, 16, 6, 16},
        {:proto_v, 8, 7, 0}
      ]
  end

  # kind 3 is reserved and treated as drop
  defp kind_of(data) do
    rtl do
      mux(data[1..2] == 3, const(0, 2), data[1..2])
    end
  end

  # extracted fields registered between stage B and C
  defp field_widths do
    [
      mac: 48,
      macp: 1,
      etok: 1,
      vlan_v: 1,
      vid: 12,
      ntags: 2,
      etype: 16,
      etype_o: 16,
      ipok: 1,
      proto: 8,
      proto_o: 8,
      src: 32,
      dst: 32,
      udpok: 1,
      sport: 16,
      dport: 16,
      poff: 7,
      plen: 16
    ]
  end

  # layout of the result word, MSB first (see `build/1`)
  defp unpack(word, sb, hw) do
    layout = [
      src: 32,
      dst: 32,
      sport: 16,
      dport: 16,
      vid: 12,
      vlan_v: 1,
      ntags: 2,
      etype: 16,
      proto: 8,
      ipok: 1,
      poff: 7,
      plen: 16,
      udpok: 1,
      kind: 2,
      stream: sb,
      hit: 1,
      hit_idx: hw
    ]

    total = layout |> Keyword.values() |> Enum.sum()

    {map, _} =
      Enum.reduce(layout, {%{}, total}, fn {k, w}, {m, hi} ->
        {Map.put(m, k, ExHdl.RTL.Expr.slice(word, hi - w, w)), hi - w}
      end)

    map
  end

  # Header parser over the 12 captured beats; `len` (bytes, 0..96) and `more` (the frame
  # continues past the window) describe how much of `hdr` is the frame.
  defp parse(hdr, len, more) do
    rtl do
      byte = fn k -> slice(Enum.at(hdr, div(k, 8)), 8 * rem(k, 8), 8) end
      be = fn k, n -> cat(for j <- 0..(n - 1), do: byte.(k + j)) end
      lenge = fn x -> more or len >= x end
      tpid = fn e -> e == 0x8100 or e == 0x88A8 end

      e0 = be.(12, 2)
      e1 = be.(16, 2)
      e2 = be.(20, 2)
      t0 = tpid.(e0)
      n0 = lenge.(14) and not t0 and e0 >= 0x0600
      n1 = lenge.(18) and t0 and not tpid.(e1) and e1 >= 0x0600
      n2 = lenge.(22) and t0 and e1 == 0x8100 and not tpid.(e2) and e2 >= 0x0600
      etok = n0 or n1 or n2
      ntags = cat([n2, n1])
      etype = mux(ntags, [e0, e1, e2])
      vlan_v = n1 or n2
      vid = mux(vlan_v, be.(14, 2)[0..11], const(0, 12))

      at = fn f -> mux(ntags, [f.(14), f.(18), f.(22)]) end
      sv = mux(ntags, [const(14, 7), const(18, 7), const(22, 7)])
      b0 = at.(byte)
      ihl = b0[0..3]
      hlen = cat([ihl, const(0, 2)])
      total = at.(fn o -> be.(o + 2, 2) end)
      flags = at.(fn o -> be.(o + 6, 2) end)
      frag = flags[13] or reduce_or(flags[0..12])

      total_ok =
        total >= hlen and (more or zext(total, 17) + zext(sv, 17) <= len)

      # ones' complement sum over the header words (bytes sv .. sv + hlen)
      lo = mux(ntags, [const(7, 6), const(9, 6), const(11, 6)])
      hi = add_wrap(lo, cat([ihl, const(0, 1)]))

      terms =
        for k <- 7..40 do
          w = be.(2 * k, 2)
          mux(k >= lo and k < hi, w, const(0, 16))
        end

      s0 = tree_sum(terms)
      s1 = zext(s0[0..15], 17) + s0[16..(width_of(s0) - 1)]
      s2 = zext(s1[0..15], 17) + s1[16..17]
      csum_ok = s2[0..15] == 0xFFFF

      ipok =
        etok and etype == 0x0800 and lenge_dyn(more, len, sv) and b0[4..7] == 4 and
          ihl >= 5 and total_ok and csum_ok

      proto = at.(fn o -> byte.(o + 9) end)
      udpok = ipok and proto == 17 and not frag and total >= hlen + 8

      u = add_wrap(zext(ihl, 5), zext(ntags, 5))

      ports =
        mux(
          u,
          for uu <- 0..31 do
            if uu >= 5 and uu <= 17, do: be.(14 + 4 * uu, 6), else: const(0, 48)
          end
        )

      zero = fn c, v, w -> mux(c, v, const(0, w)) end

      # UDP payload bytes: UDP length - 8, at most what the IP total length leaves
      ulen = ports[0..15]
      avail = sub_wrap(total, zext(hlen, 16))
      shorter = mux(ulen < avail, ulen, avail)
      plen = mux(shorter >= 8, sub_wrap(shorter, 8), const(0, 16))

      %{
        mac: cat(for j <- 0..5, do: byte.(j)),
        macp: lenge.(6),
        etok: etok,
        vlan_v: vlan_v,
        vid: vid,
        ntags: ntags,
        etype: etype,
        etype_o: zero.(etok, etype, 16),
        ipok: ipok,
        proto: proto,
        proto_o: zero.(ipok, proto, 8),
        src: zero.(ipok, at.(fn o -> be.(o + 12, 4) end), 32),
        dst: zero.(ipok, at.(fn o -> be.(o + 16, 4) end), 32),
        udpok: udpok,
        sport: zero.(udpok, ports[32..47], 16),
        dport: zero.(udpok, ports[16..31], 16),
        poff: zero.(udpok, add_wrap(cat([u, const(0, 2)]), 22), 7),
        plen: zero.(udpok, plen, 16)
      }
    end
  end

  # the 20 IPv4 header bytes lie in the frame
  defp lenge_dyn(more, len, sv) do
    rtl do
      more or len >= sv + 20
    end
  end

  defp tree_sum([x]), do: x

  defp tree_sum(l) do
    {a, b} = Enum.split(l, div(length(l), 2))
    rtl(do: tree_sum(a) + tree_sum(b))
  end
end
