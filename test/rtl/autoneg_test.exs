defmodule ExNet.RTL.AutoNegTest do
  use ExUnit.Case, async: true

  import Bitwise
  alias ExNet.PCS.AutoNeg, as: AN
  alias ExNet.RTL.AutoNeg, as: Hw
  alias ExNet.RtlCase

  @lt 3
  @abilities [
    AN.reg(fd: true, pause: true),
    AN.reg(fd: true),
    AN.reg(fd: true, hd: true, pause: true, asym: true),
    AN.reg(hd: true, asym: true)
  ]
  @regs for a <- @abilities, ack <- [0, 0x4000], do: AN.reg(fd: true) ||| a ||| ack

  defp b(true), do: 1
  defp b(false), do: 0

  # model event of one cycle: %{restart, tick, rx} with rx nil | {:config, r} | :idle | :invalid
  defp apply_model(s, %{restart: true}), do: AN.restart(s)

  defp apply_model(s, %{tick: t, rx: rx}) do
    s = if t, do: AN.tick(s), else: s
    if rx, do: AN.step(s, rx), else: s
  end

  defp rx_kind(nil), do: 0
  defp rx_kind(ev), do: Hw.kind_code(ev)
  defp rx_reg({:config, r}), do: r
  defp rx_reg(_), do: 0

  defp stim(evs, ability) do
    for e <- evs do
      %{
        rx_kind: rx_kind(e.rx),
        rx_reg: rx_reg(e.rx),
        tick: b(e.tick),
        restart: b(e.restart),
        ability: ability
      }
    end
  end

  defp expected(s, ability) do
    {kind, reg} =
      case AN.tx(s) do
        {:config, r} -> {0, r}
        :idle -> {1, 0}
        :data -> {2, 0}
      end

    p = s.partner || 0
    res = AN.resolve(p, ability)

    %{
      tx_kind: kind,
      tx_reg: reg,
      link_ok: b(AN.link_up?(s)),
      partner: p,
      partner_valid: b(s.partner != nil),
      duplex: %{nil => 0, :full => 1, :half => 2}[res.duplex],
      pause: %{none: 0, tx: 1, rx: 2, both: 3}[res.pause],
      dbg_state: Hw.state_code(s.st),
      dbg_timer: s.timer
    }
  end

  defp model_trace(evs, ability) do
    s0 = AN.new(reg: ability, link_timer: @lt)

    {_, rev} =
      Enum.reduce(evs, {s0, []}, fn e, {s, acc} ->
        {apply_model(s, e), [expected(s, ability) | acc]}
      end)

    Enum.reverse(rev)
  end

  # pure noise: runs of one event drawn from a small set
  defp random_events(n) do
    Stream.repeatedly(fn ->
      rx =
        Enum.random([nil, :idle, :idle, :invalid, {:config, Enum.random(@regs)}, {:config, 0}])

      len = Enum.random(1..6)
      for _ <- 1..len, do: %{restart: :rand.uniform() < 0.01, tick: :rand.uniform() < 0.3, rx: rx}
    end)
    |> Stream.flat_map(& &1)
    |> Enum.take(n)
  end

  # a model partner answers with its own transmit; a little noise on the wire
  defp partner_events(n, ability, partner_ability, noise) do
    a0 = AN.new(reg: ability, link_timer: @lt)
    p0 = AN.new(reg: partner_ability, link_timer: @lt)

    {_, _, rev} =
      Enum.reduce(1..n, {a0, p0, []}, fn _, {a, p, acc} ->
        wire = fn m ->
          case AN.tx(m) do
            {:config, r} -> {:config, r}
            _ -> :idle
          end
        end

        to_a = wire.(p)
        to_p = wire.(a)

        to_a =
          if :rand.uniform() < noise,
            do: Enum.random([nil, :invalid, :idle, {:config, Enum.random(@regs)}]),
            else: to_a

        ev = %{restart: :rand.uniform() < 0.003, tick: :rand.uniform() < 0.5, rx: to_a}
        pev = %{restart: false, tick: ev.tick, rx: to_p}
        {apply_model(a, ev), apply_model(p, pev), [ev | acc]}
      end)

    Enum.reverse(rev)
  end

  test "matches the model cycle by cycle on random event sequences" do
    mod = Hw.build(@lt)
    :rand.seed(:exsss, {11, 22, 33})

    visited =
      for run <- 1..40, reduce: MapSet.new() do
        acc ->
          ability = Enum.at(@abilities, rem(run, length(@abilities)))

          evs =
            if rem(run, 2) == 0,
              do: random_events(120),
              else:
                partner_events(
                  150,
                  ability,
                  Enum.random(@abilities),
                  Enum.random([0.0, 0.02, 0.1])
                )

          assert RtlCase.run(mod, stim(evs, ability)) == model_trace(evs, ability)
          MapSet.union(acc, MapSet.new(Enum.map(model_trace(evs, ability), & &1.dbg_state)))
      end

    # every state of the machine was visited
    assert MapSet.to_list(visited) |> Enum.sort() == Enum.to_list(0..6)
  end

  # two RTL machines wired to each other against `AutoNeg.connect/3`'s round
  use ExHdl.RTL

  defp pair_module do
    module "autoneg_pair" do
      abil_a = input(:abil_a, 16)
      abil_b = input(:abil_b, 16)
      a = instance(:a, Hw.build(@lt), connect: [tick: 1, restart: 0, ability: abil_a])
      b = instance(:b, Hw.build(@lt), connect: [tick: 1, restart: 0, ability: abil_b])
      a.rx_kind <~ mux(b.tx_kind == 0, const(1, 2), const(2, 2))
      a.rx_reg <~ b.tx_reg
      b.rx_kind <~ mux(a.tx_kind == 0, const(1, 2), const(2, 2))
      b.rx_reg <~ a.tx_reg
      o_a_state = output(:o_a_state, 3)
      o_b_state = output(:o_b_state, 3)
      o_a_ok = output(:o_a_ok, 1)
      o_b_ok = output(:o_b_ok, 1)
      o_a_partner = output(:o_a_partner, 16)
      o_a_duplex = output(:o_a_duplex, 2)
      o_a_pause = output(:o_a_pause, 2)
      # every instance output is read (unread instance wires fail Verilator -Wall)
      o_misc = output(:o_misc, 26)

      o_misc
      <~ cat([
        a.partner_valid,
        a.dbg_timer,
        b.partner,
        b.partner_valid,
        b.duplex,
        b.pause,
        b.dbg_timer
      ])

      o_a_state <~ a.dbg_state
      o_b_state <~ b.dbg_state
      o_a_ok <~ a.link_ok
      o_b_ok <~ b.link_ok
      o_a_partner <~ a.partner
      o_a_duplex <~ a.duplex
      o_a_pause <~ a.pause
    end
  end

  test "two machines back to back follow AutoNeg.connect round by round and reach link_ok" do
    ra = AN.reg(fd: true, pause: true)
    rb = AN.reg(fd: true)
    evs = for _ <- 1..40, do: %{abil_a: ra, abil_b: rb}
    outs = RtlCase.run(pair_module(), evs)

    as_rx = fn
      {:config, r} -> {:config, r}
      _ -> :idle
    end

    {_, _, expected} =
      Enum.reduce(
        1..40,
        {AN.new(reg: ra, link_timer: @lt), AN.new(reg: rb, link_timer: @lt), []},
        fn _, {a, b, acc} ->
          row = {Hw.state_code(a.st), Hw.state_code(b.st)}
          ta = as_rx.(AN.tx(a))
          tb = as_rx.(AN.tx(b))
          {a |> AN.tick() |> AN.step(tb), b |> AN.tick() |> AN.step(ta), [row | acc]}
        end
      )

    assert Enum.map(outs, &{&1.o_a_state, &1.o_b_state}) == Enum.reverse(expected)
    last = List.last(outs)
    assert {last.o_a_ok, last.o_b_ok} == {1, 1}
    {ma, mb} = AN.connect(AN.new(reg: ra, link_timer: @lt), AN.new(reg: rb, link_timer: @lt))
    assert {AN.link_up?(ma), AN.link_up?(mb)} == {true, true}
    assert last.o_a_partner == rb
    assert {last.o_a_duplex, last.o_a_pause} == {1, 0}
    assert AN.resolve(ma.partner, ma.ability) == %{duplex: :full, pause: :none}
  end

  @tag :verilator
  test "co-simulates (random events and the back to back pair)" do
    :rand.seed(:exsss, {5, 6, 7})
    ability = hd(@abilities)
    evs = partner_events(250, ability, Enum.at(@abilities, 1), 0.05)
    RtlCase.cosim!(Hw.build(@lt), stim(evs, ability))

    RtlCase.cosim!(
      pair_module(),
      for(_ <- 1..60, do: %{abil_a: hd(@abilities), abil_b: hd(@abilities)})
    )
  end
end
