defmodule ExNet.RTL.MacTx do
  @moduledoc """
  Ethernet MAC transmit: AXI4-Stream in, GMII (8 bit, 1G) or XGMII (64 bit, 10G) out.
  Preamble and SFD, zero padding to 60 bytes, FCS, interframe gap. Every output is
  registered: the output of cycle `t + 1` is what the reference model produces in
  cycle `t` (`ExNet.MAC.Tx.step/2` for 8 bit, `ExNet.MAC.Tx64.step/2` for 64 bit).

  ## `build(8, opts)`: module `mac_tx_8`

  | port | dir | width | meaning |
  |---|---|---|---|
  | `s_axis_tdata`, `_tlast`, `_tvalid` | in | 8, 1, 1 | frame without FCS |
  | `s_axis_tready` | out | 1 | high while a byte is taken (phase data); not a function of `tvalid` |
  | `gmii_txd`, `gmii_tx_en`, `gmii_tx_er` | out | 8, 1, 1 | GMII, registered |
  | `s_axis_tuser` | in | 8 | PTP tag of the frame, read when the frame starts (`ExNet.RTL.Ifc.mac_tx/1`) |
  | `tx_sof` | out | 1 | high for exactly one cycle, together with the SFD byte (0xD5) on `gmii_txd` |
  | `tx_tag` | out | 8 | the tag of the frame being sent, valid in the `tx_sof` cycle and held |

  A frame starts in the cycle `tvalid` is seen while idle (that cycle's output word
  appears one cycle later as the first preamble byte). `tready` stays low for the 8
  preamble cycles, then is high while the frame is read: one byte per cycle, so
  `tvalid` must not drop inside a frame (use a store-and-forward FIFO in front); if it
  does, that cycle is sent with `tx_er` high and the frame ends with the gap. Frames
  shorter than 60 bytes are padded (`tready` low during the pad), FCS follows,
  then `ifg` (default 12) idle cycles. Back to back frames: 8 + n + 4 + 12 cycles.
  `opts`: `ifg:` (1..15).

  ## `build(64, opts)`: module `mac_tx_64`

  | port | dir | width | meaning |
  |---|---|---|---|
  | `s_axis_tdata`, `_tkeep`, `_tlast`, `_tvalid` | in | 64, 8, 1, 1 | tkeep is all ones except on the last beat, contiguous from lane 0 |
  | `s_axis_tready` | out | 1 | high while a beat is taken (phase data); the first beat is taken one cycle after `tvalid` is first seen |
  | `xgmii_txd`, `xgmii_txc` | out | 64, 8 | lane `i` in bits `8i+7..8i`, `txc[i]` for a control character; registered |
  | `s_axis_tuser` | in | 8 | PTP tag of the frame, read when the frame starts (`ExNet.RTL.Ifc.mac_tx/1`) |
  | `tx_sof` | out | 1 | one cycle, together with the Start word (SFD in lane 7) |
  | `tx_tag` | out | 8 | the tag of the frame being sent, valid in the `tx_sof` cycle and held |

  Word sequence: Start word, one word per beat (full throughput, no bubble), zero pad
  words below 60 bytes, the word with the last data bytes, FCS directly behind them,
  `/T/` and idles, then the gap: at least 12 bytes counting `/T/` (one idle word when
  `/T/` is in lanes 0 to 4, two otherwise; Start only in lane 0, no deficit idle
  count, so a minimum frame takes 11 words instead of 10.5). `tvalid` low inside a
  frame sends a word of `/E/` and one idle word.
  """
  use ExHdl.RTL
  alias ExNet.RTL.CRC32, as: Crc
  alias ExNet.RTL.Ifc

  @init 0xFFFFFFFF

  def build(width, opts \\ [])

  def build(8, opts) do
    ifg = Keyword.get(opts, :ifg, 12)
    cw = max(3, ExHdl.RTL.Builder.ceil_log2(ifg + 1))
    name = if ifg == 12, do: "mac_tx_8", else: "mac_tx_8_ifg#{ifg}"

    module name do
      s = slave(:s_axis, Ifc.mac_tx(8))
      txd = output(:gmii_txd, 8, reset: 0)
      txen = output(:gmii_tx_en, 1, reset: 0)
      txer = output(:gmii_tx_er, 1, reset: 0)
      ts = master(:tx, Ifc.ts_tx(), reset: 0)
      sof = ts.sof

      # phases: 0 idle, 1 preamble, 2 data, 3 pad, 4 fcs, 5 gap
      phase = reg(:phase, 3, reset: 0)
      cnt = reg(:cnt, cw, reset: 0)
      n = reg(:n, 6, reset: 0)
      crc = reg(:crc, 32, reset: @init)

      idle = wire(:p_idle, phase == 0)
      pre = wire(:p_pre, phase == 1)
      data = wire(:p_data, phase == 2)
      pad = wire(:p_pad, phase == 3)
      fcs = wire(:p_fcs, phase == 4)
      ge59 = wire(:ge59, n >= 59)
      sfd = wire(:sfd, pre and cnt == 7)
      nxt = wire(:crc_next, Crc.next(crc, mux(pad, 0, s.tdata), 1))

      fcs_byte =
        wire(
          :fcs_byte,
          mux(cnt[0..1], [(~~~crc)[0..7], (~~~crc)[24..31], (~~~crc)[16..23], (~~~crc)[8..15]])
        )

      o_d = wire(:o_d, 8)
      o_en = wire(:o_en, 1)
      o_er = wire(:o_er, 1)

      comb do
        o_d <~ 0
        o_en <~ 0
        o_er <~ 0

        if idle and s.tvalid do
          o_d <~ 0x55
          o_en <~ 1
        end

        if pre do
          o_d <~ mux(cnt == 7, const(0xD5, 8), 0x55)
          o_en <~ 1
        end

        if data do
          o_en <~ 1
          o_d <~ mux(s.tvalid, s.tdata, 0)
          o_er <~ not s.tvalid
        end

        if pad, do: o_en <~ 1

        if fcs do
          o_d <~ fcs_byte
          o_en <~ 1
        end
      end

      s.tready <~ data

      sync do
        txd <~ o_d
        txen <~ o_en
        txer <~ o_er
        sof <~ sfd

        if idle and s.tvalid do
          phase <~ 1
          cnt <~ 1
          ts.tag <~ s.tuser
        end

        if pre do
          if cnt == 7 do
            phase <~ 2
            crc <~ @init
            n <~ 0
          else
            cnt <~ add_wrap(cnt, 1)
          end
        end

        if data do
          if s.tvalid do
            crc <~ nxt
            n <~ mux(n >= 60, n, add_wrap(n, 1))

            if s.tlast do
              phase <~ mux(ge59, const(4, 3), 3)
              cnt <~ 4
            end
          else
            phase <~ 5
            cnt <~ ifg
          end
        end

        if pad do
          crc <~ nxt
          n <~ mux(n >= 60, n, add_wrap(n, 1))

          if ge59 do
            phase <~ 4
            cnt <~ 4
          end
        end

        if fcs do
          cnt <~ sub_wrap(cnt, 1)

          if cnt == 1 do
            phase <~ 5
            cnt <~ ifg
          end
        end

        if phase == 5 do
          cnt <~ sub_wrap(cnt, 1)
          if cnt <= 1, do: phase <~ 0
        end
      end
    end
  end

  def build(64, _opts) do
    module "mac_tx_64" do
      s = slave(:s_axis, Ifc.mac_tx(64))
      txd = output(:xgmii_txd, 64, reset: 0x0707070707070707)
      txc = output(:xgmii_txc, 8, reset: 0xFF)
      ts = master(:tx, Ifc.ts_tx(), reset: 0)
      sof = ts.sof

      # phases: 0 idle, 1 data, 2 pad, 3 tail word, 4 gap
      phase = reg(:phase, 3, reset: 0)
      nb = reg(:nb, 4, reset: 0)
      gap = reg(:gap, 2, reset: 0)
      crc = reg(:crc, 32, reset: @init)
      tail_d = reg(:tail_d, 64, reset: 0)
      tail_c = reg(:tail_c, 8, reset: 0)

      idle = wire(:p_idle, phase == 0)
      data = wire(:p_data, phase == 1)
      pad = wire(:p_pad, phase == 2)
      take = wire(:take, data and s.tvalid)
      keep = s.tkeep

      # valid bytes of the last beat (tkeep is contiguous from lane 0)
      r =
        wire(
          :r,
          Enum.reduce(0..7, const(0, 4), fn i, a -> mux(keep[i], const(i + 1, 4), a) end)
        )

      bmask = wire(:bmask, cat(for i <- 7..0//-1, do: rep(keep[i], 8)))
      dm = wire(:dm, s.tdata &&& bmask)
      dword = wire(:dword, mux(pad, 0, mux(s.tlast, dm, s.tdata)))

      # bytes of data (with padding) in the current word; 8 unless the frame ends here
      eff = wire(:eff, 4)
      fin = wire(:fin, 1)

      comb do
        eff <~ 8
        fin <~ 0

        if take and s.tlast do
          if nb >= 8 do
            eff <~ r
            fin <~ 1
          else
            if nb == 7 do
              eff <~ mux(r >= 4, r, const(4, 4))
              fin <~ 1
            end
          end
        end

        if pad and nb == 7 do
          eff <~ 4
          fin <~ 1
        end
      end

      thermo = wire(:thermo, cat(for i <- 7..0//-1, do: eff > i))
      crc_n = wire(:crc_next, Crc.next_keep(crc, dword, thermo, 8))
      fcs = wire(:fcs, ~~~crc_n)

      # final word and the tail word for each `eff`
      lane_d = fn i -> dword[(8 * i)..(8 * i + 7)] end
      fcs_b = fn j -> fcs[(8 * j)..(8 * j + 7)] end
      c8 = fn v -> const(v, 8) end

      lanes = fn e, off ->
        # lane `p` (absolute stream position off + p): data, fcs, /T/ or idle
        for p <- 0..7 do
          q = off + p - e

          cond do
            q < 0 -> {lane_d.(off + p), 0}
            q < 4 -> {fcs_b.(q), 0}
            q == 4 -> {c8.(0xFD), 1}
            true -> {c8.(0x07), 1}
          end
        end
      end

      word_of = fn ls -> cat(for {d, _} <- Enum.reverse(ls), do: d) end

      ctl_of = fn ls ->
        Bitwise.bor(0, 0)

        ls
        |> Enum.with_index()
        |> Enum.reduce(0, fn {{_, c}, i}, a -> Bitwise.bor(a, Bitwise.bsl(c, i)) end)
      end

      fws = for e <- 1..8, do: lanes.(e, 0)
      tls = for e <- 4..8, do: lanes.(e, 8)
      fw = wire(:fw, mux(eff, [const(0, 64) | Enum.map(fws, word_of)]))
      fc = wire(:fc, mux(eff, [const(0, 8) | Enum.map(fws, &const(ctl_of.(&1), 8))]))

      tw =
        wire(
          :tw,
          mux(eff, List.duplicate(const(0, 64), 4) ++ Enum.map(tls, word_of))
        )

      tc =
        wire(
          :tc,
          mux(eff, List.duplicate(const(0, 8), 4) ++ Enum.map(tls, &const(ctl_of.(&1), 8)))
        )

      o_d = wire(:o_d, 64)
      o_c = wire(:o_c, 8)

      comb do
        o_d <~ 0x0707070707070707
        o_c <~ 0xFF

        if idle and s.tvalid do
          o_d <~ 0xD5555555555555FB
          o_c <~ 0x01
        end

        if data do
          if s.tvalid do
            o_d <~ mux(fin, fw, dword)
            o_c <~ mux(fin, fc, const(0, 8))
          else
            o_d <~ 0xFEFEFEFEFEFEFEFE
          end
        end

        if pad do
          o_d <~ mux(fin, fw, const(0, 64))
          o_c <~ mux(fin, fc, const(0, 8))
        end

        if phase == 3 do
          o_d <~ tail_d
          o_c <~ tail_c
        end
      end

      s.tready <~ data

      # after the final word: tail word (eff >= 4) or two idle words
      finish = fn ->
        if eff >= 4 do
          phase <~ 3
          tail_d <~ tw
          tail_c <~ tc
        else
          phase <~ 4
          gap <~ 2
        end
      end

      sync do
        txd <~ o_d
        txc <~ o_c
        sof <~ (idle and s.tvalid)

        if idle and s.tvalid do
          phase <~ 1
          nb <~ 0
          crc <~ @init
          ts.tag <~ s.tuser
        end

        if data do
          if s.tvalid do
            crc <~ crc_n
            nb <~ mux(nb >= 8, nb, add_wrap(nb, 1))

            if s.tlast do
              if fin, do: finish.(), else: phase <~ 2
            end
          else
            phase <~ 4
            gap <~ 1
          end
        end

        if pad do
          crc <~ crc_n
          nb <~ mux(nb >= 8, nb, add_wrap(nb, 1))
          if fin, do: finish.()
        end

        if phase == 3 do
          phase <~ 4
          gap <~ 1
        end

        if phase == 4 do
          gap <~ sub_wrap(gap, 1)
          if gap <= 1, do: phase <~ 0
        end
      end
    end
  end
end
