defmodule ExNet.RTL.UdpRx do
  @moduledoc """
  UDP payload extraction behind the classifier: turns the classified frame stream
  (`ExNet.RTL.Ifc.rx_frame/3`) into whole UDP payload packets (`ExNet.RTL.Ifc.udp_rx/0`)
  for stream engines such as `ExAes67.RTL.Depacketiser`.

  A frame is forwarded when the classifier says `kind = 2` (stream engine, decided on
  the first beat), the UDP header was found (`payload_valid`) and the payload is not
  empty. Its payload (`payload_len` bytes from byte `payload_offset`) is realigned to
  lane 0 by a one beat shifter and written into a store-and-forward packet FIFO
  (`ExHdlCores.FIFO.packet/1`); the last payload beat is held back until the frame's
  `tlast`, so the frame's FCS verdict (`tuser[0]` on `tlast`) can discard the whole packet.
  A packet whose frame ends before `payload_len` bytes arrived is discarded as well.
  Ethernet padding and anything after the UDP payload is cut off.

  `m_axis` is the FIFO output (`tuser` per `Ifc.pack_udp_rx/1`, constant over the packet, no
  bubbles inside a packet when `tready` is high). The input has no `tready` (the MAC cannot
  stall); a packet that does not fit the FIFO is dropped whole (`drop_full` pulse), a bad
  frame is dropped (`drop_bad` pulse), `level` is the FIFO fill in beats.

  The UDP checksum (pseudo header with the classifier's addresses and `payload_len + 8`
  as UDP length) is summed over the frame beats and checked on `tlast`; a packet with a
  nonzero checksum field that does not verify is dropped like a bad frame (`drop_bad`).
  A zero checksum field means "none" and passes (senders of AES67 media often use 0).
  The model is `ExNet.UDP.checksum_ok?/3`.

  Latency: the shifter holds one beat, and the packet FIFO releases a packet only after its
  last beat was stored, so a packet leaves after the frame ended plus a few cycles, then one
  beat per cycle.
  `dbg` carries bits that are always 0 (FIFO input not ready, the error bit of the output).

  Options: `stream_bits:` and `hit_bits:` (widths of the classifier's `stream` and
  `hit_index`, defaults 4), `depth:` (FIFO beats, 512), `style:` (`:block`),
  `checksum:` (verify the UDP checksum, default true).
  """
  use ExHdl.RTL
  alias ExHdlCores.FIFO
  alias ExNet.RTL.Ifc

  def build(opts \\ []) do
    sb = Keyword.get(opts, :stream_bits, 4)
    hw = Keyword.get(opts, :hit_bits, 4)
    depth = Keyword.get(opts, :depth, 512)
    style = Keyword.get(opts, :style, :block)
    csum? = Keyword.get(opts, :checksum, true)
    aw = ExHdl.RTL.Builder.ceil_log2(depth)
    fifo = FIFO.packet(data: 64, user: 97, err_bit: 96, depth: depth, style: style)

    module "udp_rx_s#{sb}_h#{hw}_d#{depth}_#{style}#{if csum?, do: "", else: "_nocs"}" do
      s = slave(:s, Ifc.rx_frame(sb, hw))
      m = master(:m_axis, Ifc.udp_rx())
      drop_bad = output(:drop_bad, 1)
      drop_full = output(:drop_full, 1)
      level = output(:level, aw + 1)
      dbg = output(:dbg, 2)

      f = instance(:u_fifo, fifo)

      act = reg(:act, 1)
      lane = reg(:lane, 3, reset: nil)
      b0 = reg(:b0, 4, reset: nil)
      bk = reg(:bk, 4)
      rem = reg(:rem, 16)
      meta = reg(:meta, 96, reset: nil)
      prev = reg(:prev, 64, reset: nil)
      h_v = reg(:h_v, 1)
      h_d = reg(:h_d, 64, reset: nil)
      h_k = reg(:h_k, 8, reset: nil)
      h_l = reg(:h_l, 1, reset: nil)
      fdone = reg(:fdone, 1)
      fbad = reg(:fbad, 1)
      flush = reg(:flush, 1)
      cbeat = reg(:cbeat, 13)
      csum = reg(:csum, 32)
      cfield = reg(:cfield, 16)

      first = wire(:first, s.tvalid and s.sof)
      off = s.payload_offset

      new_act =
        wire(:new_act, s.kind == 2 and s.payload_valid and s.payload_len != 0)

      new_meta = cat([s.payload_len, s.src_ip, s.dst_port, s.dst_ip])

      c_act = wire(:c_act, mux(s.sof, new_act, act))
      c_lane = wire(:c_lane, mux(s.sof, off[0..2], lane))
      c_b0 = wire(:c_b0, mux(s.sof, off[3..6], b0))
      c_rem = wire(:c_rem, mux(s.sof, s.payload_len, rem))
      k = wire(:k, mux(s.sof, const(0, 4), bk))
      ge = wire(:ge, k >= c_b0)
      gt = wire(:gt, k > c_b0)
      sel = cat([c_lane, const(0, 3)])

      # bytes of this output word: min(8, remaining)
      n8 = fn r -> mux(r >= 8, const(8, 4), trunc(r, 4)) end
      thermo = fn n -> cat(for i <- 7..0//-1, do: n > i) end
      bytemask = fn n -> cat(for i <- 7..0//-1, do: rep(n > i, 8)) end

      produce = wire(:produce, s.tvalid and c_act and gt and c_rem != 0)
      n_now = wire(:n_now, n8.(c_rem))
      word = wire(:word, part(cat([s.tdata, prev]), sel, 64) &&& bytemask.(n_now))
      rem_n = wire(:rem_n, mux(produce, sub_wrap(c_rem, zext(n_now, 16)), c_rem))

      # the flush word: the bytes of the frame's last beat behind the shift
      n_fl = wire(:n_fl, n8.(rem))

      fl_word =
        wire(
          :fl_word,
          part(cat([const(0, 64), prev]), cat([lane, const(0, 3)]), 64) &&& bytemask.(n_fl)
        )

      # UDP checksum: 16-bit words of the bytes in [off - 8, off + payload_len), the UDP
      # header starts at an even offset, so words sit on even lanes
      kf = wire(:kf, mux(s.sof, const(0, 13), cbeat))
      u_st = wire(:u_st, sub_wrap(zext(off, 16), 8))
      u_en = wire(:u_en, add_wrap(zext(off, 17), zext(s.payload_len, 17)))

      ub =
        for j <- 0..7 do
          pos = cat([kf, const(j, 3)])
          inb = zext(pos, 17) >= zext(u_st, 17) and zext(pos, 17) < u_en
          mux(inb, s.tdata[(8 * j)..(8 * j + 7)], const(0, 8))
        end

      uw = for i <- 0..3, do: zext(cat([Enum.at(ub, 2 * i), Enum.at(ub, 2 * i + 1)]), 32)
      beat_sum = Enum.reduce(uw, &add_wrap(&2, &1))
      csum_n = wire(:csum_n, add_wrap(mux(s.sof, const(0, 32), csum), beat_sum))

      f_pos = wire(:f_pos, sub_wrap(zext(off, 16), 2))
      f_here = wire(:f_here, kf == zext(f_pos[3..15], 13))

      f_word =
        wire(
          :f_word,
          mux(f_pos[1..2], for(i <- 0..3, do: s.tdata[(16 * i)..(16 * i + 15)]))
        )

      c_field = wire(:c_field, mux(f_here, f_word, cfield))

      pseudo =
        [
          s.src_ip[16..31],
          s.src_ip[0..15],
          s.dst_ip[16..31],
          s.dst_ip[0..15],
          const(17, 16),
          add_wrap(s.payload_len, 8)
        ]
        |> Enum.map(&zext(&1, 32))
        |> Enum.reduce(csum_n, &add_wrap(&2, &1))

      tot = wire(:csum_tot, pseudo)
      fold1 = wire(:csum_f1, tot[0..15] + tot[16..31])
      fold2 = wire(:csum_f2, add_wrap(fold1[0..15], zext(fold1[16], 16)))
      fword = fn v -> cat([v[0..7], v[8..15]]) end

      cs_bad =
        if csum?,
          do: wire(:cs_bad, fword.(c_field) != 0 and fold2 != 0xFFFF),
          else: const(0, 1)

      # a beat leaves the holding register: not the last one before the frame is over
      rel = wire(:rel, h_v and (not h_l or fdone))

      f.s_axis.tdata <~ h_d
      f.s_axis.tkeep <~ h_k
      f.s_axis.tlast <~ h_l
      f.s_axis.tuser <~ cat([h_l and fbad, meta])
      f.s_axis.tvalid <~ rel

      m.tdata <~ f.m_axis.tdata
      m.tkeep <~ f.m_axis.tkeep
      m.tlast <~ f.m_axis.tlast
      m.tuser <~ f.m_axis.tuser[0..95]
      m.tvalid <~ f.m_axis.tvalid
      f.m_axis.tready <~ m.tready
      drop_bad <~ f.drop_bad
      drop_full <~ f.drop_full
      level <~ f.level
      dbg <~ cat([not f.s_axis.tready, f.m_axis.tuser[96]])

      sync do
        if rel do
          h_v <~ 0
          if h_l, do: fdone <~ 0
        end

        if flush do
          flush <~ 0
          h_v <~ 1
          h_d <~ fl_word
          h_k <~ thermo.(n_fl)
          h_l <~ 1
          rem <~ 0
        end

        if s.tvalid do
          cbeat <~ mux(s.tlast, const(0, 13), add_wrap(kf, 1))
          csum <~ csum_n
          cfield <~ c_field
          bk <~ mux(s.tlast, const(0, 4), mux(k == 15, k, add_wrap(k, 1)))

          if first do
            act <~ new_act
            lane <~ off[0..2]
            b0 <~ off[3..6]
            rem <~ s.payload_len
          end

          # the previous packet may still be leaving: take the metadata where the payload starts
          if c_act and k == c_b0, do: meta <~ new_meta

          if c_act do
            if ge, do: prev <~ s.tdata

            if produce do
              rem <~ rem_n
              h_v <~ 1
              h_d <~ word
              h_k <~ thermo.(n_now)
              h_l <~ (c_rem <= 8)
            end

            if s.tlast and ge do
              fdone <~ 1
              # more payload than this frame has: the packet is cut short and dropped
              fbad
              <~ (s.tuser[0] or cs_bad or rem_n > sub_wrap(const(8, 4), zext(c_lane, 4)))

              if rem_n != 0, do: flush <~ 1
            end
          end
        end
      end
    end
  end
end
