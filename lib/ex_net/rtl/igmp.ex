defmodule ExNet.RTL.Igmp do
  @moduledoc """
  IGMP host in RTL (IGMPv2, RFC 2236, and IGMPv3, RFC 3376, as a host that joins any-source
  groups), the hardware twin of `ExNet.IGMP.Host`. It keeps a table of joined groups driven
  by a join/leave command port, reports them on join and leave, answers general and
  group-specific queries after a random delay, and sends the frames itself: Ethernet (optional
  802.1Q tag, priority 6), IPv4 with TTL 1, DSCP CS6 and the Router Alert option, header
  checksum, multicast MAC mapping (`01:00:5E` + low 23 bits of the group), IGMP checksum.

  ## Interfaces

    * `s`: the classified frame stream (`ExNet.RTL.Ifc.rx_frame/3`, from `ExNet.RTL.Classifier`
      or `ExNet.RTL.RxPath`'s `frame_*` ports). Only frames with `ethertype` 0x0800, `ip_valid`
      and `ip_proto` 2 are looked at; they do not need a table entry (kind 0 is fine).
    * `m_axis`: the transmit stream (`ExNet.RTL.Ifc.mac_tx/1`), frames without FCS (the MAC pads
      to 60 bytes), `tuser` 0. The stream may pause inside a frame: feed it to a store-and-forward
      FIFO, which is what the `raw:` sources of `ExNet.RTL.TxPath` do.
    * Static configuration inputs: `src_mac` (48), `src_ip` (32), `vlan_id` (12, only with
      `vlan: true`), `v2_only` (1: never use v3), `robustness` (3, number of transmissions of a
      state change, 0 reads as 1; the default of the standard is 2), `unsol_ms` (16, maximum
      delay between those transmissions, 1 to 30000 ms, the standard says 1000).
    * Command port: `cmd_valid`, `cmd_leave` (0 join, 1 leave), `cmd_group` (32, first octet in the
      MSBs). `cmd_ready` is high when the block is idle (not while a query or a report is being
      processed, a few tens of cycles); a command is taken in the cycle with `cmd_valid` and
      `cmd_ready`. One cycle later `cmd_done` pulses, with `cmd_err` in the same cycle when a join
      was refused: not a multicast address, a 224.0.0.x address (link local, never reported) or no
      free table slot. Joining a joined group and leaving a group that is not joined do nothing.
    * Status outputs: `member` (bit per table slot: joined), `joined` (count), `rd_idx` /
      `rd_group` / `rd_member` (read a slot back), `mode_v2` (v2 compatibility mode is active),
      `tx_done` (pulse per frame sent), `rx_missed` (pulse: an IGMP frame or an event was dropped
      because the receiver was still busy with the one before; it is a once in several microseconds
      event, the querier repeats).

  ## Behaviour

  The model is `ExNet.IGMP.Host`; the message choices are the same, the random delays come from a
  32 bit LFSR (16 steps per clock, seeded from `src_mac`) scaled by `(r * range) >> 16 + 1`
  milliseconds, so the delays differ from the model but obey the same bounds.

    * join: a v3 report with a `change_to_exclude` record (v2: membership report to the group),
      sent `robustness` times, the first at once. Leave: `change_to_include` (v2: leave to
      224.0.0.2), the same repetition. The slot is freed after the last repetition.
    * general query, v3 mode: one pending response with all joined groups in one report
      (`mode_is_exclude`, one record each), sent to 224.0.0.22 after a delay up to the maximum
      response time (clamped to 30 s). v2 mode: one membership report per group, each with its
      own delay. Group-specific queries (v3 group-and-source queries too): the report of that group.
      A pending response is kept if it is earlier than a new one.
    * A v1/v2 query puts a v3 host into v2 compatibility for `robustness * 125 s` plus the
      maximum response time. A membership report of another host in v2 mode cancels our pending
      response for that group (suppression).
    * Received messages are checked: IP header checksum (by the classifier), IGMP checksum over the
      whole message, IGMP length (8 bytes: v1/v2, 12 or more: v3 query), IHL 5 to 8 and at most two
      VLAN tags, the IGMP message inside the first 64 bytes of the frame.

  Time is counted in milliseconds from `clk_hz`.

  ## Options

  `groups:` (table slots, 16), `vlan:` (false), `clk_hz:` (156_250_000), `stream_bits:` and
  `hit_bits:` (4, as `Ifc.rx_frame/3`).

  Frame layout of the transmitted messages (46 bytes, 50 with the tag): v2 report and v2 leave 8 bytes
  of IGMP, v3 report 8 bytes plus 8 bytes per record, laid out by `ExNet.IGMP.Host.frame/3`.
  """
  use ExHdl.RTL
  alias ExHdl.RTL.Builder
  alias ExNet.RTL.Ifc

  # main states
  @idle 0
  @qw 1
  @prep 2
  @cs1 3
  @cs2 4
  @hdr 5
  @rec 6
  @fin 7

  def build(opts \\ []) do
    n = Keyword.get(opts, :groups, 16)
    vlan? = Keyword.get(opts, :vlan, false)
    clk_hz = Keyword.get(opts, :clk_hz, 156_250_000)
    sb = Keyword.get(opts, :stream_bits, 4)
    hw = Keyword.get(opts, :hit_bits, 4)
    ms_div = max(div(clk_hz, 1000), 1)
    wb = max(Builder.ceil_log2(n), 1)
    hdr_len = if vlan?, do: 50, else: 46
    hb = div(hdr_len, 8)
    r = rem(hdr_len, 8)
    t = 8 - r

    module "igmp_g#{n}_#{if vlan?, do: "v", else: "u"}_c#{clk_hz}_s#{sb}_h#{hw}" do
      s = slave(:s, Ifc.rx_frame(sb, hw))
      m = master(:m_axis, Ifc.mac_tx(64))
      src_mac = input(:src_mac, 48)
      src_ip = input(:src_ip, 32)
      vlan_id = if vlan?, do: input(:vlan_id, 12), else: nil
      v2_only = input(:v2_only, 1)
      robust_in = input(:robustness, 3)
      unsol_in = input(:unsol_ms, 16)
      cmd_valid = input(:cmd_valid, 1)
      cmd_leave = input(:cmd_leave, 1)
      cmd_group = input(:cmd_group, 32)
      rd_idx = input(:rd_idx, wb)
      cmd_ready = output(:cmd_ready, 1)
      cmd_done = output(:cmd_done, 1)
      cmd_err = output(:cmd_err, 1)
      member_o = output(:member, n)
      joined_o = output(:joined, wb + 1)
      rd_group = output(:rd_group, 32)
      rd_member = output(:rd_member, 1)
      mode_v2 = output(:mode_v2, 1)
      tx_done = output(:tx_done, 1)
      rx_missed = output(:rx_missed, 1)

      c8 = fn v -> const(v, 8) end
      byte = fn x, i -> x[(8 * i)..(8 * i + 7)] end
      be = fn x, nb -> for i <- (nb - 1)..0//-1, do: byte.(x, i) end

      # -- time, random numbers ------------------------------------------------------------
      psc = reg(:psc, Builder.ceil_log2(ms_div + 1) + 1)
      now = reg(:now, 32)
      lfsr = reg(:lfsr, 32)
      tick = wire(:tick, psc == ms_div - 1)
      now16 = now[0..15]

      # 16 LFSR steps per clock, each one a named wire (a nested expression would grow 4^16)
      step =
        Enum.reduce(1..16, lfsr, fn i, x ->
          fb = bxor(bxor(x[31], x[21]), bxor(x[1], x[0]))
          wire(:"lfsr_s#{i}", cat([x[0..30], fb]))
        end)

      # -- configuration ---------------------------------------------------------------------
      rb = wire(:rb, mux(robust_in == 0, const(1, 3), robust_in))

      unsol =
        wire(
          :unsol,
          mux(unsol_in == 0, const(1, 16), mux(unsol_in > 30000, const(30000, 16), unsol_in))
        )

      # -- state -----------------------------------------------------------------------------
      st = reg(:st, 3)
      wi = reg(:wi, wb)

      # group table
      v = for i <- 0..(n - 1), do: reg(:"v#{i}", 1)
      lv = for i <- 0..(n - 1), do: reg(:"lv#{i}", 1)
      cp = for i <- 0..(n - 1), do: reg(:"cp#{i}", 1)
      qp = for i <- 0..(n - 1), do: reg(:"qp#{i}", 1)
      rl = for i <- 0..(n - 1), do: reg(:"rl#{i}", 3, reset: nil)
      cdue = for i <- 0..(n - 1), do: reg(:"cdue#{i}", 16, reset: nil)
      qdue = for i <- 0..(n - 1), do: reg(:"qdue#{i}", 16, reset: nil)
      g = for i <- 0..(n - 1), do: reg(:"g#{i}", 32, reset: nil)
      at = &Enum.at/2

      mem = for i <- 0..(n - 1), do: wire(:"mem#{i}", at.(v, i) and not at.(lv, i))

      # event latched by the receiver, handled in IDLE
      ev_pend = reg(:ev_pend, 1)
      ev_kind = reg(:ev_kind, 1, reset: nil)
      ev_v2q = reg(:ev_v2q, 1, reset: nil)
      ev_group = reg(:ev_group, 32, reset: nil)
      ev_ms = reg(:ev_ms, 16, reset: nil)
      ev_code = reg(:ev_code, 8, reset: nil)

      compat_on = reg(:compat_on, 1)
      compat_until = reg(:compat_until, 32, reset: nil)
      gq_pend = reg(:gq_pend, 1)
      gq_due = reg(:gq_due, 16, reset: nil)

      # message being built
      m_kind = reg(:m_kind, 2, reset: nil)
      m_rtype = reg(:m_rtype, 3, reset: nil)
      m_all = reg(:m_all, 1, reset: nil)
      m_group = reg(:m_group, 32, reset: nil)
      acc = reg(:acc, 24, reset: nil)
      nrec = reg(:nrec, 8, reset: nil)
      f_dst = reg(:f_dst, 32, reset: nil)
      f_tot = reg(:f_tot, 16, reset: nil)
      f_type = reg(:f_type, 8, reset: nil)
      f_g = reg(:f_g, 32, reset: nil)
      ip_sum = reg(:ip_sum, 24, reset: nil)
      ig_sum = reg(:ig_sum, 24, reset: nil)
      f_ipck = reg(:f_ipck, 16, reset: nil)
      f_ick = reg(:f_ick, 16, reset: nil)
      eb = reg(:eb, 3)
      hold = reg(:hold, 64, reset: nil)
      done_r = reg(:done_r, 1)
      err_r = reg(:err_r, 1)
      txd_r = reg(:txd_r, 1)
      miss_r = reg(:miss_r, 1)

      # receiver
      ps = reg(:ps, 3)
      cb = reg(:cb, 4)
      nt = reg(:nt, 2, reset: nil)
      ihl = reg(:ihl, 4, reset: nil)
      tl = reg(:tl, 16, reset: nil)
      ilen = reg(:ilen, 16, reset: nil)
      ws = reg(:ws, 6, reset: nil)
      nw = reg(:nw, 6, reset: nil)
      k = reg(:k, 6, reset: nil)
      racc = reg(:racc, 21, reset: nil)
      q_type = reg(:q_type, 8, reset: nil)
      q_mr = reg(:q_mr, 8, reset: nil)
      q_gh = reg(:q_gh, 16, reset: nil)
      q_gl = reg(:q_gl, 16, reset: nil)
      bufs = for j <- 0..7, do: reg(:"rb#{j}", 64, reset: nil)

      # -- status outputs ---------------------------------------------------------------------
      member_o <~ cat(Enum.reverse(mem))
      joined_o <~ Enum.reduce(mem, const(0, wb + 1), fn x, a -> add_wrap(a, zext(x, wb + 1)) end)
      rd_group <~ mux(rd_idx, g)
      rd_member <~ mux(rd_idx, mem)
      cmd_done <~ done_r
      cmd_err <~ err_r
      tx_done <~ txd_r
      rx_missed <~ miss_r

      compat_diff = wire(:compat_diff, sub_wrap(compat_until, now))

      compat_active =
        wire(:compat_active, compat_on and compat_diff != 0 and not compat_diff[31])

      mode2 = wire(:mode2, v2_only or compat_active)
      mode_v2 <~ mode2

      times100 = fn x ->
        w = width(x)
        a = zext(cat([x, const(0, 6)]), w + 7)
        b = zext(cat([x, const(0, 5)]), w + 7)
        c = zext(cat([x, const(0, 2)]), w + 7)
        add_wrap(add_wrap(a, b), c)
      end

      # -- delay generator ---------------------------------------------------------------------
      in_idle = wire(:in_idle, st == @idle)
      ev_now = wire(:ev_now, in_idle and ev_pend)
      use_ev = wire(:use_ev, st == @qw or ev_now)
      range = wire(:range, mux(use_ev, ev_ms, unsol))
      prod = wire(:prod, lfsr[16..31] * range)
      rdelay = wire(:rdelay, add_wrap(prod[16..31], 1))
      new_due = wire(:new_due, add_wrap(now16, rdelay))
      due? = fn d -> not sub_wrap(now16, d)[15] end
      earlier? = fn a, b -> sub_wrap(a, b)[15] end

      # -- command port -------------------------------------------------------------------------
      ready = wire(:ready, in_idle and not ev_pend)
      cmd_ready <~ ready
      exec = wire(:exec, ready and cmd_valid)
      do_join = wire(:do_join, exec and not cmd_leave)
      do_leave = wire(:do_leave, exec and cmd_leave)

      mc_ok =
        wire(:mc_ok, cmd_group[28..31] == 0xE and cmd_group[8..31] != 0xE00000)

      # one set of comparators for commands and for the group of a received report (never both)
      cmp = wire(:cmp, mux(ev_pend, ev_group, cmd_group))
      eqs = for i <- 0..(n - 1), do: wire(:"eq#{i}", at.(v, i) and at.(g, i) == cmp)
      any_eq = wire(:any_eq, reduce_or(cat(eqs)))
      frees = for i <- 0..(n - 1), do: wire(:"free#{i}", not at.(v, i))
      any_free = wire(:any_free, reduce_or(cat(frees)))

      first_free =
        for i <- 0..(n - 1) do
          before = Enum.take(frees, i)
          if before == [], do: at.(frees, i), else: at.(frees, i) and not reduce_or(cat(before))
        end

      join_new =
        for i <- 0..(n - 1),
            do: wire(:"jn#{i}", do_join and mc_ok and not any_eq and at.(first_free, i))

      revive =
        for i <- 0..(n - 1),
            do: wire(:"rv#{i}", do_join and mc_ok and at.(eqs, i) and at.(lv, i))

      leaving =
        for i <- 0..(n - 1),
            do: wire(:"lq#{i}", do_leave and at.(eqs, i) and not at.(lv, i))

      # -- scan: due slot ---------------------------------------------------------------------
      idle_run = wire(:idle_run, ready and not cmd_valid)
      cp_w = wire(:cp_w, mux(wi, cp))
      qp_w = wire(:qp_w, mux(wi, qp))
      cdue_w = wire(:cdue_w, mux(wi, cdue))
      qdue_w = wire(:qdue_w, mux(wi, qdue))
      rl_w = wire(:rl_w, mux(wi, rl))
      cp_hit = wire(:cp_hit, cp_w and due?.(cdue_w))
      qp_hit = wire(:qp_hit, qp_w and mux(wi, mem) and due?.(qdue_w))
      gq_hit = wire(:gq_hit, gq_pend and due?.(gq_due))
      start_gq = wire(:start_gq, idle_run and gq_hit)
      start_cp = wire(:start_cp, idle_run and not gq_hit and cp_hit)
      start_qp = wire(:start_qp, idle_run and not gq_hit and not cp_hit and qp_hit)
      start = wire(:start, start_gq or start_cp or start_qp)
      g_w = wire(:g_w, mux(wi, g))
      lv_w = wire(:lv_w, mux(wi, lv))
      mode3 = wire(:mode3, not mode2)

      # -- events (query, report seen) ----------------------------------------------------------
      qry = wire(:qry, ev_now and not ev_kind)
      rep_seen = wire(:rep_seen, ev_now and ev_kind)
      mode3_after = wire(:mode3_after, not (v2_only or compat_active or ev_v2q))
      ev_general = wire(:ev_general, ev_group == 0)
      gq_path = wire(:gq_path, qry and ev_general and mode3_after)
      walk = wire(:walk, qry and not gq_path)
      any_mem = wire(:any_mem, reduce_or(cat(mem)))

      # robustness * 125 s + code * 100 ms, shifts and adds instead of multipliers
      ev_comp =
        wire(
          :ev_comp,
          add_wrap(
            mux(rb, for(x <- 0..7, do: const(x * 125_000, 20))),
            zext(times100.(ev_code), 20)
          )
        )

      qw_ok = wire(:qw_ok, st == @qw and mux(wi, mem) and (ev_general or g_w == ev_group))

      # -- header words --------------------------------------------------------------------------
      dmac = [
        c8.(0x01),
        c8.(0x00),
        c8.(0x5E),
        cat([const(0, 1), f_dst[16..22]]),
        byte.(f_dst, 1),
        byte.(f_dst, 0)
      ]

      ethtype =
        if vlan? do
          [
            c8.(0x81),
            c8.(0x00),
            cat([const(0b1100, 4), vlan_id[8..11]]),
            byte.(vlan_id, 0),
            c8.(0x08),
            c8.(0x00)
          ]
        else
          [c8.(0x08), c8.(0x00)]
        end

      hdr_bytes =
        dmac ++
          be.(src_mac, 6) ++
          ethtype ++
          [c8.(0x46), c8.(0xC0)] ++
          be.(f_tot, 2) ++
          [c8.(0), c8.(0), c8.(0), c8.(0), c8.(1), c8.(2)] ++
          be.(f_ipck, 2) ++
          be.(src_ip, 4) ++
          be.(f_dst, 4) ++
          [c8.(0x94), c8.(4), c8.(0), c8.(0), f_type, c8.(0)] ++
          be.(f_ick, 2) ++
          be.(f_g, 4)

      words =
        hdr_bytes
        |> Enum.chunk_every(8)
        |> Enum.map(fn ch -> zext(cat(Enum.reverse(ch)), 64) end)

      hdr_word = wire(:hdr_word, mux(eb, Enum.take(words, hb)))
      tail_word = List.last(words)

      # -- header values and checksums (registered in CS1, folded in CS2) -------------------------
      nrec_e = wire(:nrec_e, mux(m_all, nrec, mux(m_kind == 2, const(1, 8), const(0, 8))))

      dst =
        wire(:dst, mux(m_kind, [m_group, const(0xE0000002, 32), const(0xE0000016, 32)]))

      tot = wire(:tot, add_wrap(const(32, 16), zext(cat([nrec_e, const(0, 3)]), 16)))
      type_n = wire(:type_n, mux(m_kind, [const(0x16, 8), const(0x17, 8), const(0x22, 8)]))
      gsum = wire(:gsum, add_wrap(zext(m_group[16..31], 24), zext(m_group[0..15], 24)))
      single = wire(:single, add_wrap(gsum, zext(cat([const(0, 5), m_rtype, const(0, 8)]), 24)))

      ip_terms =
        Enum.reduce(
          [
            const(0x0102, 16),
            tot,
            src_ip[16..31],
            src_ip[0..15],
            dst[16..31],
            dst[0..15],
            const(0x9404, 16)
          ],
          const(0x46C0, 24),
          fn x, a -> add_wrap(a, zext(x, 24)) end
        )

      ig_terms =
        mux(
          m_kind == 2,
          add_wrap(
            add_wrap(const(0x2200, 24), zext(nrec_e, 24)),
            mux(m_all, acc, single)
          ),
          add_wrap(gsum, zext(cat([type_n, const(0, 8)]), 24))
        )

      fold = fn x ->
        a = zext(x[0..15], 17) + zext(x[16..23], 17)
        b = zext(a[0..15], 17) + zext(a[16], 17)
        b[0..15]
      end

      # -- record word (little endian lanes: type, aux length, source count, group) --------------
      rg = wire(:rg, mux(m_all, g_w, m_group))

      rec_word =
        wire(
          :rec_word,
          cat([
            byte.(rg, 0),
            byte.(rg, 1),
            byte.(rg, 2),
            byte.(rg, 3),
            const(0, 24),
            cat([const(0, 5), m_rtype])
          ])
        )

      rec_ok = wire(:rec_ok, mux(m_all, mux(wi, mem), wi == 0))
      rec_last = wire(:rec_last, mux(m_all, wi == n - 1, const(1, 1)))

      # -- transmit stream --------------------------------------------------------------------------
      comb do
        m.tvalid <~ 0
        m.tdata <~ 0
        m.tkeep <~ 0
        m.tlast <~ 0
        m.tuser <~ 0

        if st == @hdr do
          m.tvalid <~ 1
          m.tdata <~ hdr_word
          m.tkeep <~ 0xFF
        end

        if st == @rec do
          m.tvalid <~ rec_ok
          m.tdata <~ cat([rec_word[0..(8 * t - 1)], hold[0..(8 * r - 1)]])
          m.tkeep <~ 0xFF
        end

        if st == @fin do
          m.tvalid <~ 1
          m.tdata <~ hold
          m.tkeep <~ (Bitwise.bsl(1, r) - 1)
          m.tlast <~ 1
        end
      end

      # -- receive buffer ------------------------------------------------------------------------------
      cand =
        wire(
          :cand,
          s.tvalid and s.sof and s.ethertype == 0x0800 and s.ip_valid and s.ip_proto == 2
        )

      rstart = wire(:rstart, cand and ps == 0)
      capb = wire(:capb, rstart or (ps == 1 and s.tvalid))
      idx = wire(:idx, mux(rstart, const(0, 4), cb))

      rwords =
        for w <- 0..31 do
          b = at.(bufs, div(w, 4))
          kk = rem(w, 4)
          cat([b[(16 * kk)..(16 * kk + 7)], b[(16 * kk + 8)..(16 * kk + 15)]])
        end

      rd = fn a -> mux(a, rwords) end
      nt2 = zext(cat([nt, const(0, 1)]), 6)

      rw =
        wire(
          :rw,
          rd.(mux(ps == 2, add_wrap(nt2, 7), mux(ps == 3, add_wrap(nt2, 8), add_wrap(ws, k))))
        )

      ihl2 = zext(cat([ihl, const(0, 1)]), 6)
      c_ilen = wire(:c_ilen, sub_wrap(tl, zext(cat([ihl, const(0, 2)]), 16)))
      c_ws = wire(:c_ws, add_wrap(add_wrap(ihl2, nt2), 7))

      c_ok =
        wire(
          :c_ok,
          tl >= zext(cat([ihl, const(0, 2)]), 16) + 8 and not c_ilen[0] and c_ilen <= 64 and
            zext(c_ws, 8) + zext(c_ilen[1..6], 8) <= 32
        )

      f1 = wire(:f1, zext(racc[0..15], 17) + zext(racc[16..20], 17))
      f2 = wire(:f2, zext(f1[0..15], 17) + zext(f1[16], 17))
      ck_ok = wire(:ck_ok, f2[0..15] == 0xFFFF)

      v2q = wire(:v2q, ilen == 8)
      v3q = wire(:v3q, ilen >= 12)
      is_q = wire(:is_q, q_type == 0x11 and (v2q or v3q))
      is_r = wire(:is_r, q_type == 0x16)

      dec =
        mux(
          q_mr[4..6],
          for e <- 0..7 do
            zext(cat([const(1, 1), q_mr[0..3]]) <<< (e + 3), 15)
          end
        )

      units = wire(:units, mux(q_mr[7] and v3q, dec, zext(q_mr, 15)))

      ms_val =
        wire(
          :ms_val,
          mux(
            units > 300,
            const(30000, 16),
            trunc(times100.(mux(units == 0, const(1, 15), units)), 16)
          )
        )

      ev_post = wire(:ev_post, ps == 6 and ck_ok and (is_q or is_r))

      # -- sequential logic --------------------------------------------------------------------------------
      sync do
        # time
        psc <~ add_wrap(psc, 1)

        if tick do
          psc <~ 0
          now <~ add_wrap(now, 1)
        end

        lfsr <~ mux(lfsr == 0, src_mac[0..31] ||| 1, step)

        done_r <~ exec
        err_r <~ (do_join and (not mc_ok or (not any_eq and not any_free)))
        txd_r <~ 0
        miss_r <~ 0

        # slot updates, later statements win
        for i <- 0..(n - 1) do
          if at.(join_new, i) do
            at.(v, i) <~ 1
            at.(lv, i) <~ 0
            at.(g, i) <~ cmd_group
            at.(cp, i) <~ 1
            at.(cdue, i) <~ now16
            at.(rl, i) <~ rb
            at.(qp, i) <~ 0
          end

          if at.(revive, i) do
            at.(lv, i) <~ 0
            at.(cp, i) <~ 1
            at.(cdue, i) <~ now16
            at.(rl, i) <~ rb
          end

          if at.(leaving, i) do
            at.(lv, i) <~ 1
            at.(cp, i) <~ 1
            at.(cdue, i) <~ now16
            at.(rl, i) <~ rb
            at.(qp, i) <~ 0
          end

          if start_cp and wi == i do
            at.(rl, i) <~ add_wrap(rl_w, 7)

            if rl_w > 1 do
              at.(cdue, i) <~ new_due
            else
              at.(cp, i) <~ 0

              if lv_w do
                at.(v, i) <~ 0
                at.(lv, i) <~ 0
              end
            end
          end

          if start_qp and wi == i do
            at.(qp, i) <~ 0
          end

          if rep_seen and mode2 and at.(mem, i) and at.(eqs, i) do
            at.(qp, i) <~ 0
          end

          if qw_ok and wi == i and (not qp_w or earlier?.(new_due, qdue_w)) do
            at.(qp, i) <~ 1
            at.(qdue, i) <~ new_due
          end
        end

        # idle: events, scan, start of a transmission
        if idle_run and not start do
          wi <~ mux(wi == n - 1, const(0, wb), add_wrap(wi, 1))
        end

        if ev_now do
          ev_pend <~ 0

          if qry and ev_v2q and not v2_only do
            compat_on <~ 1
            compat_until <~ add_wrap(now, ev_comp)
          end

          if gq_path and any_mem and (not gq_pend or earlier?.(new_due, gq_due)) do
            gq_pend <~ 1
            gq_due <~ new_due
          end

          if walk do
            ev_pend <~ 1
            st <~ @qw
            wi <~ 0
          end
        end

        if st == @qw do
          wi <~ add_wrap(wi, 1)

          if wi == n - 1 do
            wi <~ 0
            st <~ @idle
            ev_pend <~ 0
          end
        end

        if start do
          m_all <~ start_gq
          m_group <~ g_w
          m_rtype <~ mux(start_cp, mux(lv_w, const(3, 3), const(4, 3)), const(2, 3))

          m_kind
          <~ mux(
            start_cp,
            mux(mode3, const(2, 2), mux(lv_w, const(1, 2), const(0, 2))),
            mux(start_gq or mode3, const(2, 2), const(0, 2))
          )

          acc <~ 0
          nrec <~ 0
          wi <~ 0
          st <~ mux(start_gq, const(@prep, 3), const(@cs1, 3))
        end

        if start_gq do
          gq_pend <~ 0
        end

        # records of a general report: sum and count
        if st == @prep do
          if mux(wi, mem) do
            acc
            <~ add_wrap(
              add_wrap(acc, zext(cat([const(0, 5), m_rtype, const(0, 8)]), 24)),
              add_wrap(zext(g_w[16..31], 24), zext(g_w[0..15], 24))
            )

            nrec <~ add_wrap(nrec, 1)
          end

          wi <~ add_wrap(wi, 1)

          if wi == n - 1 do
            wi <~ 0
            st <~ @cs1
          end
        end

        # header fields and sums
        if st == @cs1 do
          st <~ @cs2
          f_type <~ type_n
          f_dst <~ dst
          f_tot <~ tot
          f_g <~ mux(m_kind == 2, zext(nrec_e, 32), m_group)
          ip_sum <~ ip_terms

          ig_sum <~ ig_terms

          if m_all and nrec == 0 do
            st <~ @idle
          end
        end

        if st == @cs2 do
          f_ipck <~ ~~~fold.(ip_sum)
          f_ick <~ ~~~fold.(ig_sum)
          eb <~ 0
          st <~ @hdr
        end

        if st == @hdr and m.tready do
          eb <~ add_wrap(eb, 1)

          if eb == hb - 1 do
            hold <~ tail_word
            wi <~ 0
            st <~ mux(m_kind == 2, const(@rec, 3), const(@fin, 3))
          end
        end

        if st == @rec do
          if not rec_ok or m.tready do
            wi <~ add_wrap(wi, 1)

            if rec_last do
              wi <~ 0
              st <~ @fin
            end
          end

          if rec_ok and m.tready do
            hold <~ zext(rec_word[(8 * t)..63], 64)
          end
        end

        if st == @fin and m.tready do
          st <~ @idle
          txd_r <~ 1
        end

        # receiver
        if rstart do
          nt <~ s.ntags
          ps <~ 1
        end

        if cand and ps != 0 do
          miss_r <~ 1
        end

        if capb do
          cb <~ mux(idx == 8, const(8, 4), add_wrap(idx, 1))
        end

        for j <- 0..7 do
          if capb and idx == j do
            at.(bufs, j) <~ s.tdata
          end
        end

        if capb and s.tlast do
          ps <~ mux(Ifc.bad(s.tuser), const(0, 3), const(2, 3))
        end

        if ps == 2 do
          ihl <~ rw[8..11]
          ps <~ 3

          if rw[12..15] != 4 or rw[8..11] < 5 or rw[8..11] > 8 do
            ps <~ 0
          end
        end

        if ps == 3 do
          tl <~ rw
          ps <~ 4
        end

        if ps == 4 do
          ilen <~ c_ilen
          ws <~ c_ws
          nw <~ c_ilen[1..6]
          k <~ 0
          racc <~ 0
          ps <~ mux(c_ok, const(5, 3), const(0, 3))
        end

        if ps == 5 do
          racc <~ add_wrap(racc, zext(rw, 21))
          k <~ add_wrap(k, 1)

          if k == 0 do
            q_type <~ rw[8..15]
            q_mr <~ rw[0..7]
          end

          if k == 2, do: q_gh <~ rw
          if k == 3, do: q_gl <~ rw

          if add_wrap(k, 1) == nw do
            ps <~ 6
          end
        end

        if ps == 6 do
          ps <~ 0

          if ev_post do
            if ev_pend do
              miss_r <~ 1
            else
              ev_pend <~ 1
              ev_kind <~ is_r
              ev_v2q <~ v2q
              ev_group <~ cat([q_gh, q_gl])
              ev_ms <~ ms_val
              ev_code <~ q_mr
            end
          end
        end
      end
    end
  end
end
