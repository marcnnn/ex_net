defmodule ExNet.RTL.MacRx do
  @moduledoc """
  Ethernet MAC receive: GMII (8 bit) or XGMII (64 bit) in, AXI4-Stream out. Finds
  preamble and SFD, strips and checks the FCS, flags runts, oversize frames and receive
  errors. All outputs are registered; there is no backpressure (the stream has no
  `tready`). The reference models are `ExNet.MAC.Rx` (8 bit) and `ExNet.MAC.Rx64`
  (64 bit); a model event of cycle `t` shows on the outputs in cycle `t + 1`
  (`rx_sof`, `frame_end`, `status`) or `t + 2` (stream beats, see below).

  Common outputs:

    * `m_axis_*`: `tdata`, `tlast`, `tuser` (4 bits), `tvalid`, and `tkeep` (64 bit).
      The frame without FCS. `tuser` is meaningful with `tlast`: bit 0 set means bad
      frame, bits 3:1 are the status code (0 ok, 1 FCS error, 2 receive error, 3 runt,
      4 oversize). The last beat is held back until the end of the frame is known, so
      `tlast` is on the real last beat. Frames with at most 4 bytes (including FCS)
      produce no beat. Oversize frames are cut after `max_len - 4` bytes with `tlast`
      and an error `tuser` on the cut beat (status oversize, or receive error if one
      was seen before the cut); the exact status follows on `status`.
    * `frame_end` (1 cycle) with `status` (3 bits, same code, held until the next
      frame end): every frame, also those without beats.
    * `rx_sof` (`ExNet.RTL.Ifc.ts_rx/0`): one cycle, the cycle after the SFD was on the
      interface (8 bit: the SFD byte; 64 bit: the Start word, with the SFD in lane 7). A
      timestamp unit that samples a free running counter on `rx_sof` sees the SFD
      `ExNet.RTL.Ifc.rx_sof_cycles/0` (1) cycle late, constant. The stream interface is
      `ExNet.RTL.Ifc.mac_rx/1`.

  ## `build(8, opts)`: module `mac_rx_8`

  Inputs `gmii_rxd` (8), `gmii_rx_dv`, `gmii_rx_er`. The frame needs at least one
  `dv = 0` cycle after it (it ends there). Stream: beat for the model's data event of
  cycle `t` in cycle `t + 2`, one byte per cycle, `tlast` and `tuser` from the end
  event one cycle after the last byte (so frames are contiguous bursts). `max_len`
  (default 1522) counts bytes with FCS.

  ## `build(64, opts)`: module `mac_rx_64`

  Inputs `xgmii_rxd` (64), `xgmii_rxc` (8). Frame start (Start in lane 0 or 4, SFD in
  lane 7), first control lane ends the frame (`/T/` normal, anything else is a receive
  error). Beats appear one cycle after the word that completes them is followed by
  the next word (`ExNet.MAC.Rx64`): the model event of cycle `t` shows on the stream
  in cycle `t + 1`; a short tail beat (1 to 3 bytes) comes one cycle later. A word
  with a Terminate cannot start a frame. `tdata` is zero beyond `tkeep`. Throughput
  one beat per cycle. Needs `max_len >= 64`.
  """
  use ExHdl.RTL
  alias ExNet.RTL.CRC32, as: Crc
  alias ExNet.RTL.Ifc

  @init 0xFFFFFFFF
  @residue 0xDEBB20E3

  def build(width, opts \\ [])

  def build(8, opts) do
    max_len = Keyword.get(opts, :max_len, 1522)
    cw = ExHdl.RTL.Builder.ceil_log2(max_len + 2)
    name = if max_len == 1522, do: "mac_rx_8", else: "mac_rx_8_max#{max_len}"

    module name do
      rxd = input(:gmii_rxd, 8)
      dv = input(:gmii_rx_dv, 1)
      rxer = input(:gmii_rx_er, 1)

      m = master(:m_axis, Ifc.mac_rx(8), reset: 0)
      ts = master(:rx, Ifc.ts_rx(), reset: 0)
      sof = ts.sof
      fend = output(:frame_end, 1, reset: 0)
      status = output(:status, 3, reset: 0)

      # phases: 0 idle, 1 skip (wait for dv = 0), 2 preamble, 3 frame
      phase = reg(:phase, 2, reset: 0)
      win = reg(:win, 32, reset: 0)
      crc = reg(:crc, 32, reset: @init)
      cnt = reg(:cnt, cw, reset: 0)
      err = reg(:err, 1, reset: 0)
      hold_v = reg(:hold_v, 1, reset: 0)
      hold_d = reg(:hold_d, 8, reset: 0)

      idle = wire(:p_idle, phase == 0)
      skip = wire(:p_skip, phase == 1)
      pre = wire(:p_pre, phase == 2)
      frame = wire(:p_frame, phase == 3)
      is55 = wire(:is55, rxd == 0x55)
      isd5 = wire(:isd5, rxd == 0xD5)
      crc_n = wire(:crc_next, Crc.next(crc, rxd, 1))
      in_dv = wire(:in_frame_dv, frame and dv)

      ev_d = wire(:ev_data, in_dv and cnt >= 4 and cnt < max_len)
      ev_trunc = wire(:ev_trunc, in_dv and cnt == max_len)
      ev_end = wire(:ev_end, frame and not dv)

      code =
        wire(
          :code,
          mux(
            err,
            const(2, 3),
            mux(
              cnt < 64,
              const(3, 3),
              mux(cnt > max_len, const(4, 3), mux(crc != @residue, const(1, 3), const(0, 3)))
            )
          )
        )

      user_end = wire(:user_end, cat([code, code != 0]))
      err_now = wire(:err_now, err or rxer)
      user_trunc = wire(:user_trunc, mux(err_now, const(0b0101, 4), const(0b1001, 4)))

      sync do
        sof <~ (pre and dv and isd5)
        fend <~ ev_end
        if ev_end, do: status <~ code

        m.tvalid <~ 0
        m.tlast <~ 0

        if ev_d do
          hold_d <~ win[0..7]
          hold_v <~ 1

          if hold_v do
            m.tvalid <~ 1
            m.tdata <~ hold_d
            m.tlast <~ 0
            m.tuser <~ 0
          end
        else
          if (ev_end or ev_trunc) and hold_v do
            m.tvalid <~ 1
            m.tdata <~ hold_d
            m.tlast <~ 1
            m.tuser <~ mux(ev_end, user_end, user_trunc)
            hold_v <~ 0
          end
        end

        if idle and dv, do: phase <~ mux(is55, const(2, 2), const(1, 2))
        if skip and not dv, do: phase <~ 0

        if pre do
          if dv do
            if isd5 do
              phase <~ 3
              crc <~ @init
              cnt <~ 0
              err <~ 0
            else
              if not is55, do: phase <~ 1
            end
          else
            phase <~ 0
          end
        end

        if frame do
          if dv do
            win <~ cat([rxd, win[8..31]])
            crc <~ crc_n
            cnt <~ mux(cnt == max_len + 1, cnt, add_wrap(cnt, 1))
            err <~ err_now
          else
            phase <~ 0
          end
        end
      end
    end
  end

  def build(64, opts) do
    max_len = Keyword.get(opts, :max_len, 1522)
    if max_len < 64, do: raise(ArgumentError, "max_len must be at least 64")
    lim = max_len - 4
    kl = div(lim + 7, 8)
    lim_n = lim - 8 * (kl - 1)
    kw = ExHdl.RTL.Builder.ceil_log2(kl + 2)
    cw = ExHdl.RTL.Builder.ceil_log2(max_len + 2)
    name = if max_len == 1522, do: "mac_rx_64", else: "mac_rx_64_max#{max_len}"

    module name do
      rxd = input(:xgmii_rxd, 64)
      rxc = input(:xgmii_rxc, 8)
      m = master(:m_axis, Ifc.mac_rx(64), reset: 0)
      ts = master(:rx, Ifc.ts_rx(), reset: 0)
      sof = ts.sof
      fend = output(:frame_end, 1, reset: 0)
      status = output(:status, 3, reset: 0)

      inframe = reg(:inframe, 1, reset: 0)
      hv = reg(:hv, 1, reset: 0)
      h = reg(:h, 64, reset: 0)
      k = reg(:k, kw, reset: 0)
      cnt = reg(:cnt, cw, reset: 0)
      crc = reg(:crc, 32, reset: @init)
      err = reg(:err, 1, reset: 0)
      trunc = reg(:trunc, 1, reset: 0)
      tail_v = reg(:tail_v, 1, reset: 0)
      tail_d = reg(:tail_d, 64, reset: 0)
      tail_k = reg(:tail_k, 8, reset: 0)
      tail_u = reg(:tail_u, 4, reset: 0)

      lane = fn i -> rxd[(8 * i)..(8 * i + 7)] end

      start0 =
        wire(
          :start0,
          rxc == 1 and lane.(0) == 0xFB and rxd[8..55] == 0x555555555555 and lane.(7) == 0xD5
        )

      start4 =
        wire(
          :start4,
          rxc[4] and rxc[5..7] == 0 and lane.(4) == 0xFB and rxd[40..55] == 0x5555 and
            lane.(7) == 0xD5
        )

      idle = wire(:p_idle, not inframe)
      start = wire(:start, start0 or start4)

      # first control lane (8: none) and whether it is /T/
      first =
        wire(
          :first,
          Enum.reduce(7..0//-1, const(8, 4), fn i, a -> mux(rxc[i], const(i, 4), a) end)
        )

      tflag =
        wire(
          :tflag,
          Enum.reduce(7..0//-1, const(0, 1), fn i, a -> mux(rxc[i], lane.(i) == 0xFD, a) end)
        )

      term = wire(:term, rxc != 0)
      keepv = wire(:keepv, cat(for i <- 7..0//-1, do: first > i))
      bm = wire(:bm, cat(for i <- 7..0//-1, do: rep(first > i, 8)))
      crc_n = wire(:crc_next, mux(first == 0, crc, Crc.next_keep(crc, rxd &&& bm, keepv, 8)))
      sum = wire(:cnt_sum, cnt + first)
      cnt_n = wire(:cnt_n, mux(sum >= max_len + 1, const(max_len + 1, cw), trunc(sum, cw)))
      err_n = wire(:err_n, err or (term and not tflag))

      code =
        wire(
          :code,
          mux(
            err_n,
            const(2, 3),
            mux(
              cnt_n < 64,
              const(3, 3),
              mux(cnt_n > max_len, const(4, 3), mux(crc_n != @residue, const(1, 3), const(0, 3)))
            )
          )
        )

      user_end = wire(:user_end, cat([code, code != 0]))
      user_t = wire(:user_t, mux(err, const(0b0101, 4), const(0b1001, 4)))
      lim_hit = wire(:lim_hit, k == kl)

      # end word: last beat from the held word (case A) or held word plus a short tail (case B)
      few = wire(:few, first <= 4)
      case_a = wire(:case_a, few or lim_hit)
      use_lim = wire(:use_lim, lim_hit and (not few or lim_n < add_wrap(first, 4)))
      n_last = wire(:n_last, mux(use_lim, const(lim_n, 4), add_wrap(first, 4)))

      n_tail =
        wire(
          :n_tail,
          mux(k == kl - 1 and lim_n < sub_wrap(first, 4), const(lim_n, 4), sub_wrap(first, 4))
        )

      bm_last = wire(:bm_last, cat(for i <- 7..0//-1, do: rep(n_last > i, 8)))
      bm_tail = wire(:bm_tail, cat(for i <- 7..0//-1, do: rep(n_tail > i, 8)))
      keep_last = wire(:keep_last, cat(for i <- 7..0//-1, do: n_last > i))
      keep_tail = wire(:keep_tail, cat(for i <- 7..0//-1, do: n_tail > i))
      lim_mask = Bitwise.bsl(1, 8 * lim_n) - 1
      lim_keep = Bitwise.bsl(1, lim_n) - 1

      # the beat leaving the held word in this cycle
      b_v = wire(:b_v, 1)
      b_d = wire(:b_d, 64)
      b_k = wire(:b_k, 8)
      b_l = wire(:b_l, 1)
      b_u = wire(:b_u, 4)

      comb do
        b_v <~ 0
        b_d <~ h
        b_k <~ 0xFF
        b_l <~ 0
        b_u <~ 0

        if inframe and hv and not trunc do
          b_v <~ 1

          if term do
            if case_a do
              b_d <~ (h &&& bm_last)
              b_k <~ keep_last
              b_l <~ 1
              b_u <~ user_end
            end
          else
            if lim_hit do
              b_d <~ (h &&& lim_mask)
              b_k <~ lim_keep
              b_l <~ 1
              b_u <~ user_t
            end
          end
        end
      end

      sync do
        sof <~ (idle and start)
        fend <~ (inframe and term)
        if inframe and term, do: status <~ code

        m.tvalid <~ (b_v or tail_v)
        m.tdata <~ mux(tail_v, tail_d, b_d)
        m.tkeep <~ mux(tail_v, tail_k, b_k)
        m.tlast <~ (tail_v or b_l)
        m.tuser <~ mux(tail_v, tail_u, b_u)
        tail_v <~ 0

        if idle and start do
          inframe <~ 1
          hv <~ 0
          k <~ 0
          cnt <~ 0
          crc <~ @init
          err <~ 0
          trunc <~ 0
        end

        if inframe do
          cnt <~ cnt_n
          crc <~ crc_n
          err <~ err_n

          if term do
            inframe <~ 0
            hv <~ 0

            if not trunc and not case_a do
              tail_v <~ 1
              tail_d <~ (rxd &&& bm_tail)
              tail_k <~ keep_tail
              tail_u <~ user_end
            end
          else
            k <~ mux(k >= kl + 1, k, add_wrap(k, 1))

            if not trunc do
              if lim_hit do
                trunc <~ 1
                hv <~ 0
              else
                h <~ rxd
                hv <~ 1
              end
            end
          end
        end
      end
    end
  end
end
