defmodule ExNet.RTL.AutoNeg do
  @moduledoc """
  Clause 37 auto-negotiation in hardware, cycle-exact with `ExNet.PCS.AutoNeg`
  (`step/2`, `tick/1`, `restart/1`, `tx/1`, `link_up?/1`, `resolve/2`).

  `build/1` returns module `autoneg_lt<link_timer>`; `link_timer` is the number
  of `tick` pulses after which the `an_enable`/`complete_acknowledge` timers
  expire (an elaboration-time parameter). Unlike the model's one-call-per-event
  API, all inputs are sampled every cycle.

  Inputs: `rx_kind` (2: 0 nothing this cycle, 1 `/C/` ordered set with `rx_reg`,
  2 `/I/`, 3 invalid), `rx_reg` (16), `tick` (1, link timer unit), `restart` (1,
  management restart), `ability` (16, our base page).

  Per cycle the register update is `step(tick(s), event)` of the model (tick
  first, then the event, exactly as `AutoNeg.connect/3` orders them); `restart`
  has priority over both (state `an_restart`, partner and history cleared).

  Outputs, all combinational from the state register (no latency, as the
  model's accessors): `tx_kind` (2: 0 config, 1 idle, 2 data), `tx_reg` (16: the
  register to send when `tx_kind` is 0, as `tx/1`; 0 in the other kinds),
  `link_ok`, `partner` (16, Ack cleared, 0 until a partner register was
  matched) with `partner_valid`, `duplex` (2: 0 none, 1 full, 2 half) and `pause`
  (2: 0 none, 1 tx, 2 rx, 3 both) as `resolve(partner, ability)`, `dbg_state` (3:
  an_enable 0, an_restart 1, ability_detect 2, acknowledge_detect 3,
  complete_acknowledge 4, idle_detect 5, link_ok 6) and `dbg_timer`.
  A register update takes effect one cycle after its inputs.

  Deviations from the model: none. As there, next pages, remote fault and the
  link-fail-inhibit timer are not implemented.
  """
  use ExHdl.RTL

  @states [
    an_enable: 0,
    an_restart: 1,
    ability_detect: 2,
    acknowledge_detect: 3,
    complete_acknowledge: 4,
    idle_detect: 5,
    link_ok: 6
  ]

  @doc "State atom to the 3-bit code of `dbg_state`."
  def state_code(atom), do: Keyword.fetch!(@states, atom)

  @doc "Input `rx_kind` code of a model event (`{:config, reg} | :idle | :invalid`)."
  def kind_code({:config, _}), do: 1
  def kind_code(:idle), do: 2
  def kind_code(:invalid), do: 3

  @ack 0x4000
  @nack 0xBFFF

  def build(link_timer \\ 10) when link_timer >= 1 do
    tw = max(ExHdl.RTL.Builder.ceil_log2(link_timer + 1), 1)

    module "autoneg_lt#{link_timer}" do
      rx_kind = input(:rx_kind, 2)
      rx_reg = input(:rx_reg, 16)
      tick = input(:tick, 1)
      restart = input(:restart, 1)
      ability = input(:ability, 16)

      tx_kind = output(:tx_kind, 2)
      tx_reg = output(:tx_reg, 16)
      link_ok = output(:link_ok, 1)
      partner_o = output(:partner, 16)
      partner_valid = output(:partner_valid, 1)
      duplex = output(:duplex, 2)
      pause = output(:pause, 2)
      dbg_state = output(:dbg_state, 3)
      dbg_timer = output(:dbg_timer, tw)

      st = reg(:st, 3, reset: 0)
      timer = reg(:timer, tw, reset: 0)
      partner = reg(:partner_r, 16, reset: 0)
      pvalid = reg(:pvalid, 1, reset: 0)
      hk0 = reg(:hk0, 2, reset: 0)
      hk1 = reg(:hk1, 2, reset: 0)
      hr0 = reg(:hr0, 16, reset: 0)
      hr1 = reg(:hr1, 16, reset: 0)

      # tick(s): the two timed states leave when the unit count reaches link_timer
      timed = wire(:timed, st == 0 or st == 1 or st == 4)
      tn = wire(:tn, timer + 1)
      done = wire(:done, tick and timed and tn >= link_timer)
      st1 = wire(:st1, mux(done, mux(st == 4, const(5, 3), const(2, 3)), st))

      # step(s, event): history after shifting the event in
      ev = wire(:ev, rx_kind != 0)
      cfg3 = wire(:cfg3, rx_kind == 1 and hk0 == 1 and hk1 == 1)
      m0 = wire(:m0, rx_reg &&& @nack)
      m1 = wire(:m1, hr0 &&& @nack)
      m2 = wire(:m2, hr1 &&& @nack)
      amatch = wire(:amatch, cfg3 and m0 == m1 and m1 == m2)
      nz = wire(:nz, amatch and m0 != 0)
      chg = wire(:chg, amatch and m0 != partner)
      ackm = wire(:ackm, amatch and m0 == partner and (rx_reg &&& hr0 &&& hr1 &&& @ack) != 0)
      idlem = wire(:idlem, rx_kind == 2 and hk0 == 2 and hk1 == 2)

      go_en = wire(:go_en, ev and chg and st1 >= 3)
      to_ack = wire(:to_ack, ev and st1 == 2 and nz)
      to_ca = wire(:to_ca, ev and st1 == 3 and not chg and ackm)
      to_lok = wire(:to_lok, ev and st1 == 5 and not chg and idlem)
      moved = wire(:moved, go_en or to_ack or to_ca or to_lok)

      nst =
        wire(
          :nst,
          mux(
            go_en,
            const(0, 3),
            mux(to_ack, const(3, 3), mux(to_ca, const(4, 3), mux(to_lok, const(6, 3), st1)))
          )
        )

      sync do
        if restart do
          st <~ 1
          timer <~ 0
          partner <~ 0
          pvalid <~ 0
          hk0 <~ 0
          hk1 <~ 0
        else
          st <~ nst

          if moved do
            timer <~ 0
          else
            if tick and timed, do: timer <~ trunc(tn, tw)
          end

          if done, do: timer <~ 0

          if go_en do
            partner <~ 0
            pvalid <~ 0
          end

          if to_ack do
            partner <~ m0
            pvalid <~ 1
          end

          if go_en do
            hk0 <~ 0
            hk1 <~ 0
          else
            if ev do
              hk0 <~ rx_kind
              hk1 <~ hk0
              hr0 <~ rx_reg
              hr1 <~ hr0
            end
          end
        end
      end

      tx_kind <~ mux(st == 6, const(2, 2), mux(st == 5, const(1, 2), const(0, 2)))

      tx_reg
      <~ mux(
        st == 2,
        ability &&& @nack,
        mux(st == 3 or st == 4, ability ||| @ack, const(0, 16))
      )

      link_ok <~ (st == 6)
      partner_o <~ partner
      partner_valid <~ pvalid
      dbg_state <~ st
      dbg_timer <~ timer

      fd = ability[5] and partner[5]
      hd = ability[6] and partner[6]
      duplex <~ mux(fd, const(1, 2), mux(hd, const(2, 2), const(0, 2)))

      lp = ability[7]
      la = ability[8]
      pp = partner[7]
      pa = partner[8]

      pause
      <~ mux(
        lp and pp,
        const(3, 2),
        mux(
          not lp and la and pp and pa,
          const(1, 2),
          mux(lp and la and not pp and pa, const(2, 2), const(0, 2))
        )
      )
    end
  end
end
