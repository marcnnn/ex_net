defmodule ExNet.RTL.PCS1000X do
  @moduledoc """
  1000BASE-X PCS (Clause 36) in hardware, one GMII byte or one 10-bit code
  group per clock, cycle-exact with `ExNet.PCS.Base1000X` (`Tx`, `Sync`, `Rx`)
  and `ExNet.PCS.AutoNeg`. Running disparity is one bit everywhere, 1 = RD+;
  code groups are `abcdei fghj` with `a` in bit 9 and sent first.

  Modules (all ports unsigned):

    * `build_tx/0` `pcs1000x_tx` - GMII to code groups.
    * `build_rx_core/0` `pcs1000x_rx_core` - code groups that are already
      aligned to `Sync` and `Rx`.
    * `build_rx/0` `pcs1000x_rx` - comma alignment in fabric plus the core.
    * `build/1` `pcs1000x_lt<link_timer>_td<tick_div>` - the top: tx, rx and
      auto-negotiation (`ExNet.RTL.AutoNeg`).

  ## `pcs1000x_tx`

  Inputs `txd` (8), `tx_en`, `tx_er`, `tx_config`, `tx_config_reg` (16). Output
  `code10` (10), registered: the code group for the GMII cycle `i` is on
  `code10` in cycle `i + 1` (latency 1, one group per cycle, reset value 0).
  With `tx_config = 0` the sequence equals `ExNet.PCS.Base1000X.Tx` exactly
  (idle sets `/I1/` `/I2/` chosen by running disparity, `/S/` replacing the first
  preamble byte, `/V/` on `tx_er`, `/T/` and one or two `/R/` so that the next
  idle set starts on an even group; a frame starting in the second half of an
  idle set drops that GMII byte).

  Configuration extension (no model in `Base1000X`; the reference is
  `ExNet.PCS1000XRef` in `test/support`): while `tx_config = 1` and the
  transmitter sits on an ordered-set boundary (idle, first half, not inside a
  frame, its `/R/` tail or a configuration set), a `/C/` ordered set starts:
  `K28.5`, `D21.5` (`/C1/`) or `D2.2` (`/C2/`), then `tx_config_reg` low byte,
  high byte. `tx_config_reg` is sampled in the cycle of `K28.5`. Sets alternate
  `/C1/` `/C2/` (starting with `/C1/` after reset); a started set is always
  completed. `tx_en` is ignored while sending configuration. Disparity runs
  through the sets like through any other group.

  ## `pcs1000x_rx_core`

  Input `code10` (10). Outputs, all registered, so the group seen in cycle `i`
  shows up in cycle `i + 1`: `rxd` (8), `rx_dv`, `rx_er` (the model's
  `gmii` triple, `{0, 0, 0}` while not in sync), `sync` (the model's `sync`:
  `Sync.in_sync?` after consuming the group), `config_valid` (one cycle pulse
  for a completed `/C/` ordered set) with `config_reg` (16, valid in that cycle
  and held), `idle_valid` (pulse for a completed `/I/` set), `bad_valid` (pulse
  when a started `/C/` or `/I/` set is not completed by data groups of the right
  kind, i.e. an invalid ordered set; all three only while in sync and never in
  the same cycle). Debug outputs show the state register before the edge:
  `dbg_state` (4: `Sync` states in the order loss_of_sync, comma_detect_1-3,
  acquire_sync_1-2, sync_acquired_1, 2, 2a, 3, 3a, 4, 4a), `dbg_even`,
  `dbg_good` (2), `dbg_phase` (3: idle, ord1, cfg_lo, cfg_hi, frame, after_t),
  `dbg_rd`. The synchronisation next-state table is generated from
  `Base1000X.Sync.step/2` itself.

  ## `pcs1000x_rx`

  Input `rx_code10` (10): the transceiver's parallel word without word
  alignment, i.e. the serial stream cut into 10-bit chunks at an arbitrary bit
  offset, chunk bit 9 being the earliest bit. Outputs as the core except `dbg_rd`, plus `shift` (4, the chosen bit offset 0-9).

  Alignment: a 20-bit window of the previous and the current chunk is searched
  for the 7-bit comma `0011111` or `1100000` at each of the 10 start offsets;
  the lowest offset wins. While the core is not in sync (`sync` low) every comma
  found loads `shift`; once in sync `shift` is frozen, so alignment follows a new
  comma only while out of sync (a stream slip is noticed by `Sync` losing sync,
  after which the next comma re-aligns). A second 20-bit window, one cycle
  older than the detection window, is shifted by `shift` into the aligned
  register, so the group that starts at the comma is not lost. Latency: the
  group whose first bit is bit `b` of chunk `j` (needs chunks `j` and `j + 1`,
  if `b > 0`) is in the core's outputs in cycle `j + 4`; for `b = 0` as well
  (the pipeline is fixed: window register, aligned register, core register).
  Throughput one group per cycle.

  ## Top `pcs1000x_lt<link_timer>_td<tick_div>`

  Inputs: `txd`, `tx_en`, `tx_er` (GMII in), `rx_code10` (unaligned chunks),
  `an_enable`, `an_restart`, `an_ability` (16). Outputs: `tx_code10` (10),
  `rxd`, `rx_dv`, `rx_er`, `sync`, `link_up`, `partner_reg` (16),
  `partner_valid`, `duplex` (2), `pause` (2) (as `ExNet.RTL.AutoNeg`),
  `config_valid`, `config_reg` (16), `an_state` (3), `dbg` (16 + w: `rx` debug state,
  even, good, phase, idle and bad pulses, `shift`, then the AN timer of w bits).

  `link_timer` ticks of `tick_div` clocks each time the auto-negotiation link
  timer unit (a tick every 1 ms is `tick_div = 125_000` at 125 MHz and `link_timer = 10` gives
  the standard 10 ms). With
  `an_enable = 1` the AN machine drives the transmitter: configuration sets
  (`/C/`) while negotiating, idles during `idle_detect`, the GMII data in
  `link_ok`; `link_up` is `AutoNeg.link_ok`. The machine is restarted while
  `an_enable = 0`, on `an_restart` and when `sync` falls (link loss), so it
  only starts counting once enabled. With `an_enable = 0` the GMII data is
  always passed and `link_up` is `sync`. Received ordered sets reach the AN
  machine as `rx_kind` 1 (`config_valid`), 2 (`idle_valid`), 3 (`bad_valid`).
  Latencies: GMII to `tx_code10` 1 cycle; `rx_code10` to GMII as in `pcs1000x_rx`.
  """
  use ExHdl.RTL

  alias ExHdlCores.CommaAligner
  alias ExNet.PCS.Base1000X.Sync
  alias ExNet.RTL.AutoNeg, as: AN
  alias ExNet.RTL.Code8b10b, as: C8

  @k28_5 0xBC
  @k27_7 0xFB
  @k29_7 0xFD
  @k23_7 0xF7
  @k30_7 0xFE
  @d21_5 0xB5
  @d2_2 0x42
  @i1 0xC5
  @i2 0x50

  @sync_states [
    :loss_of_sync,
    :comma_detect_1,
    :comma_detect_2,
    :comma_detect_3,
    :acquire_sync_1,
    :acquire_sync_2,
    :sync_acquired_1,
    :sync_acquired_2,
    :sync_acquired_2a,
    :sync_acquired_3,
    :sync_acquired_3a,
    :sync_acquired_4,
    :sync_acquired_4a
  ]

  @phases [:idle, :ord1, :cfg_lo, :cfg_hi, :frame, :after_t]

  @doc "3-bit `dbg_phase` code of a model `Rx` phase atom."
  def phase_code(atom), do: Enum.find_index(@phases, &(&1 == atom))

  @doc "4-bit `dbg_state` code of a `Sync` state atom."
  def sync_code(atom), do: Enum.find_index(@sync_states, &(&1 == atom))

  # -- transmitter -------------------------------------------------------------------

  @doc "Transmitter module `pcs1000x_tx`."
  def build_tx do
    module "pcs1000x_tx" do
      txd = input(:txd, 8)
      tx_en = input(:tx_en, 1)
      tx_er = input(:tx_er, 1)
      tx_config = input(:tx_config, 1)
      creg_in = input(:tx_config_reg, 16)
      code10 = output(:code10, 10, reset: 0)

      rd = reg(:rd, 1, reset: 0)
      phase = reg(:phase, 2, reset: 0)
      half = reg(:half, 1, reset: 0)
      dsel = reg(:dsel, 1, reset: 0)
      par = reg(:par, 1, reset: 0)
      more = reg(:more, 1, reset: 0)
      cpos = reg(:cpos, 2, reset: 0)
      c2 = reg(:c2, 1, reset: 0)
      creg = reg(:creg, 16, reset: 0)

      start_cfg = wire(:start_cfg, tx_config and phase == 0 and half == 0 and cpos == 0)
      in_cfg = wire(:in_cfg, start_cfg or cpos != 0)

      idle_k = mux(half, const(0, 1), const(1, 1))

      idle_b =
        mux(
          half,
          mux(dsel, const(@i1, 8), const(@i2, 8)),
          mux(tx_en, const(@k27_7, 8), const(@k28_5, 8))
        )

      frame_k = not (tx_en and not tx_er)
      frame_b = mux(tx_en, mux(tx_er, const(@k30_7, 8), txd), const(@k29_7, 8))
      norm_k = mux(phase == 0, idle_k, mux(phase == 1, frame_k, const(1, 1)))
      norm_b = mux(phase == 0, idle_b, mux(phase == 1, frame_b, const(@k23_7, 8)))

      cfg_b =
        mux(
          cpos == 0,
          const(@k28_5, 8),
          mux(
            cpos == 1,
            mux(c2, const(@d2_2, 8), const(@d21_5, 8)),
            mux(cpos == 2, slice(creg, 0, 8), slice(creg, 8, 8))
          )
        )

      e =
        C8.encode(
          mux(in_cfg, cpos == 0, norm_k),
          mux(in_cfg, cfg_b, norm_b),
          rd,
          "tx"
        )

      sync do
        code10 <~ e.code
        rd <~ e.rd_next

        if in_cfg do
          if cpos == 3 do
            cpos <~ 0
            c2 <~ not c2
          else
            cpos <~ add_wrap(cpos, 1)
          end

          if start_cfg, do: creg <~ creg_in
        else
          if phase == 0 do
            if half == 0 do
              if tx_en do
                phase <~ 1
                par <~ 1
              else
                half <~ 1
                dsel <~ rd
              end
            else
              half <~ 0
            end
          else
            if phase == 1 do
              if tx_en do
                par <~ not par
              else
                phase <~ 2
                more <~ par
              end
            else
              if more do
                more <~ 0
              else
                phase <~ 0
                half <~ 0
              end
            end
          end
        end
      end
    end
  end

  # -- receiver ----------------------------------------------------------------------

  # next-state table of Sync.step/2, index cat([class(2), good(2), even(1), st(4)]),
  # word cat([good(2), even(1), st(4)]); class 0 comma, 1 data, 2 invalid (3 unused)
  defp sync_word(class, good, even, st) do
    state = %Sync{st: Enum.at(@sync_states, st), even: even == 1, good: good}

    try do
      n = Sync.step(state, Enum.at([:comma, :data, :invalid], class))

      Bitwise.bsl(n.good, 5) + Bitwise.bsl(if(n.even, do: 1, else: 0), 4) +
        Enum.find_index(@sync_states, &(&1 == n.st))
    rescue
      _ -> Bitwise.bsl(good, 5) + Bitwise.bsl(even, 4) + st
    end
  end

  # Builds the aligned receiver inside the current module; `code` is the aligned
  # 10-bit group. Returns the registered outputs and debug signals as a map.
  defp rx_core(code) do
    rtl do
      rd = reg(:rd, 1, reset: 0)
      st = reg(:sst, 4, reset: 0)
      even = reg(:even, 1, reset: 0)
      good = reg(:good, 2, reset: 0)
      phase = reg(:phase, 3, reset: 0)
      lo = reg(:lo, 8, reset: 0)

      rxd = output(:rxd, 8, reset: 0)
      rx_dv = output(:rx_dv, 1, reset: 0)
      rx_er = output(:rx_er, 1, reset: 0)
      sync_o = output(:sync, 1, reset: 0)
      config_valid = output(:config_valid, 1, reset: 0)
      config_reg = output(:config_reg, 16, reset: 0)
      idle_valid = output(:idle_valid, 1, reset: 0)
      bad_valid = output(:bad_valid, 1, reset: 0)

      d = C8.decode(code, rd, "rx")
      inval = wire(:inval, d.code_err or d.disp_err)
      valid_k = fn byte -> not inval and d.k and d.data == byte end
      is_d = wire(:is_d, not inval and not d.k)
      comma = not inval and d.k and (d.data == 0xBC or d.data == 0x3C or d.data == 0xFC)
      class = mux(comma, const(0, 2), mux(inval, const(2, 2), const(1, 2)))

      words =
        for c <- 0..3, g <- 0..3, e <- 0..1, s <- 0..15, do: const(sync_word(c, g, e, s), 7)

      nxt = wire(:sync_next, mux(cat([class, good, even, st]), words))
      nst = slice(nxt, 0, 4)
      insync = wire(:insync, nst >= 6)

      s_sym = valid_k.(@k27_7)
      bc = valid_k.(@k28_5)
      t_sym = valid_k.(@k29_7)
      r_sym = valid_k.(@k23_7)
      i_d = is_d and (d.data == @i1 or d.data == @i2)
      c_d = is_d and (d.data == @d21_5 or d.data == @d2_2)

      cont =
        wire(
          :cont,
          mux(
            phase == 1,
            i_d or c_d,
            mux(phase == 2 or phase == 3, is_d, mux(phase == 5, r_sym, const(1, 1)))
          )
        )

      eff = wire(:eff, mux(cont, phase, const(0, 3)))

      # {next phase, gmii data, dv, er} per effective phase
      idle_ph = mux(s_sym, const(4, 3), mux(bc, const(1, 3), const(0, 3)))

      frame_ph =
        mux(is_d, const(4, 3), mux(t_sym, const(5, 3), mux(bc, const(1, 3), const(4, 3))))

      nph =
        mux(
          eff == 0,
          idle_ph,
          mux(
            eff == 1,
            mux(i_d, const(0, 3), const(2, 3)),
            mux(
              eff == 2,
              const(3, 3),
              mux(eff == 3, const(0, 3), mux(eff == 4, frame_ph, const(5, 3)))
            )
          )
        )

      in_frame = eff == 4
      start = eff == 0 and s_sym
      dv = start or (in_frame and not t_sym)
      er = in_frame and not is_d and not t_sym
      data = mux(start, const(0x55, 8), mux(in_frame and is_d, d.data, const(0, 8)))
      cfg_done = insync and eff == 3

      sync do
        rd <~ d.rd_next
        st <~ nst
        even <~ nxt[4]
        good <~ slice(nxt, 5, 2)
        sync_o <~ insync
        phase <~ mux(insync, nph, const(0, 3))
        rxd <~ mux(insync, data, const(0, 8))
        rx_dv <~ (insync and dv)
        rx_er <~ (insync and er)
        config_valid <~ cfg_done
        idle_valid <~ (insync and eff == 1 and i_d)
        bad_valid <~ (insync and (phase == 1 or phase == 2 or phase == 3) and not cont)
        if insync and eff == 2, do: lo <~ d.data
        if cfg_done, do: config_reg <~ cat([d.data, lo])
      end

      %{rd: rd, st: st, even: even, good: good, phase: phase}
    end
  end

  defp rx_ports(core) do
    rtl do
      dbg_state = output(:dbg_state, 4)
      dbg_even = output(:dbg_even, 1)
      dbg_good = output(:dbg_good, 2)
      dbg_phase = output(:dbg_phase, 3)
      dbg_state <~ core.st
      dbg_even <~ core.even
      dbg_good <~ core.good
      dbg_phase <~ core.phase
    end
  end

  @doc "Aligned receiver module `pcs1000x_rx_core`."
  def build_rx_core do
    module "pcs1000x_rx_core" do
      code = input(:code10, 10)
      core = rx_core(code)
      rx_ports(core)
      dbg_rd = output(:dbg_rd, 1)
      dbg_rd <~ core.rd
    end
  end

  @doc "Receiver with comma alignment, module `pcs1000x_rx`."
  def build_rx do
    module "pcs1000x_rx" do
      rx_code10 = input(:rx_code10, 10)
      shift_o = output(:shift, 4)

      al = instance(:u_align, CommaAligner.build())
      core = rx_core(al.aligned)
      rx_ports(core)

      al.code <~ rx_code10
      al.lock <~ signal(:sync)
      shift_o <~ al.shift
    end
  end

  # -- top ---------------------------------------------------------------------------

  @doc """
  Top module `pcs1000x_lt<link_timer>_td<tick_div>` (see the module doc).
  """
  def build(link_timer \\ 10, tick_div \\ 1) do
    module "pcs1000x_lt#{link_timer}_td#{tick_div}" do
      txd = input(:txd, 8)
      tx_en = input(:tx_en, 1)
      tx_er = input(:tx_er, 1)
      rx_code10 = input(:rx_code10, 10)
      an_enable = input(:an_enable, 1)
      an_restart = input(:an_restart, 1)
      an_ability = input(:an_ability, 16)

      tx_code10 = output(:tx_code10, 10)
      rxd = output(:rxd, 8)
      rx_dv = output(:rx_dv, 1)
      rx_er = output(:rx_er, 1)
      sync_o = output(:sync, 1)
      link_up = output(:link_up, 1)
      partner_reg = output(:partner_reg, 16)
      partner_valid = output(:partner_valid, 1)
      duplex = output(:duplex, 2)
      pause = output(:pause, 2)
      config_valid = output(:config_valid, 1)
      config_reg = output(:config_reg, 16)
      an_state = output(:an_state, 3)
      tw = max(ExHdl.RTL.Builder.ceil_log2(link_timer + 1), 1)
      dbg = output(:dbg, 16 + tw)

      tx = instance(:u_tx, build_tx())
      rx = instance(:u_rx, build_rx())
      an = instance(:u_an, AN.build(link_timer))
      sync_d = reg(:sync_d, 1, reset: 0)

      tick =
        if tick_div == 1 do
          const(1, 1)
        else
          cw = ExHdl.RTL.Builder.ceil_log2(tick_div)
          cnt = reg(:tick_cnt, cw, reset: 0)

          sync do
            if cnt == tick_div - 1, do: cnt <~ 0, else: cnt <~ add_wrap(cnt, 1)
          end

          wire(:tick, cnt == tick_div - 1)
        end

      sync do
        sync_d <~ rx.sync
      end

      rx.rx_code10 <~ rx_code10

      an.rx_kind
      <~ mux(
        rx.config_valid,
        const(1, 2),
        mux(rx.idle_valid, const(2, 2), mux(rx.bad_valid, const(3, 2), const(0, 2)))
      )

      an.rx_reg <~ rx.config_reg
      an.tick <~ tick
      an.restart <~ (an_restart or (sync_d and not rx.sync) or not an_enable)
      an.ability <~ an_ability

      tx.txd <~ txd
      tx.tx_en <~ (tx_en and (not an_enable or an.tx_kind == 2))
      tx.tx_er <~ tx_er
      tx.tx_config <~ (an_enable and an.tx_kind == 0)
      tx.tx_config_reg <~ an.tx_reg

      tx_code10 <~ tx.code10
      rxd <~ rx.rxd
      rx_dv <~ rx.rx_dv
      rx_er <~ rx.rx_er
      sync_o <~ rx.sync
      link_up <~ mux(an_enable, an.link_ok, rx.sync)
      partner_reg <~ an.partner
      partner_valid <~ an.partner_valid
      duplex <~ an.duplex
      pause <~ an.pause
      config_valid <~ rx.config_valid
      config_reg <~ rx.config_reg
      an_state <~ an.dbg_state

      dbg
      <~ cat([
        rx.dbg_state,
        rx.dbg_even,
        rx.dbg_good,
        rx.dbg_phase,
        rx.idle_valid,
        rx.bad_valid,
        rx.shift,
        an.dbg_timer
      ])
    end
  end
end
