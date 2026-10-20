defmodule ExNet.RTL.PCS1000XTest do
  use ExUnit.Case, async: true
  use ExHdl.RTL

  import Bitwise, only: [<<<: 2, >>>: 2, &&&: 2]
  alias ExHdl.RTL.Module
  alias ExNet.MAC
  alias ExNet.PCS.Base1000X, as: P
  alias ExNet.PCS.Base1000X.Rx
  alias ExNet.PCS.Code8b10b, as: C
  alias ExNet.PCS1000XRef, as: Ref
  alias ExNet.RTL.PCS1000X, as: Hw
  alias ExNet.RtlCase

  @idle {0, false, false}

  defp b(true), do: 1
  defp b(false), do: 0

  # -- stimulus ----------------------------------------------------------------------

  # GMII cycles: idle runs (sometimes with junk data), bursts of data, rare errors
  defp gmii(n) do
    Stream.repeatedly(fn ->
      if :rand.uniform() < 0.5 do
        for _ <- 1..:rand.uniform(8),
            do: {if(:rand.uniform() < 0.2, do: :rand.uniform(256) - 1, else: 0), false, false}
      else
        for _ <- 1..:rand.uniform(30),
            do: {:rand.uniform(256) - 1, true, :rand.uniform() < 0.03}
      end
    end)
    |> Stream.flat_map(& &1)
    |> Enum.take(n)
  end

  # per cycle {tx_config, reg}: runs of on / off, the register changes every cycle
  defp cfg_flags(n) do
    Stream.repeatedly(fn ->
      on = :rand.uniform() < 0.5
      for _ <- 1..:rand.uniform(12), do: {on, :rand.uniform(65536) - 1}
    end)
    |> Stream.flat_map(& &1)
    |> Enum.take(n)
  end

  # -- transmitter -------------------------------------------------------------------

  defp tx_events(gm, cfg) do
    for {{d, en, er}, {c, r}} <- Enum.zip(gm, cfg),
        do: %{txd: d, tx_en: b(en), tx_er: b(er), tx_config: b(c), tx_config_reg: r}
  end

  # the output register shows the code of the previous cycle
  defp delayed(codes), do: [0 | Enum.drop(codes, -1)]

  defp tx_codes(mod, gm, cfg),
    do: mod |> RtlCase.run(tx_events(gm, cfg)) |> Enum.map(& &1.code10)

  test "transmitter equals Base1000X.Tx when tx_config is low (one cycle later)" do
    :rand.seed(:exsss, {1, 1, 1})
    mod = Hw.build_tx()

    for _ <- 1..15 do
      gm = gmii(300)
      off = List.duplicate({false, 0}, 300)
      assert tx_codes(mod, gm, off) == delayed(P.tx_run(gm))
    end
  end

  test "transmitter with /C1/ /C2/ sets equals the reference" do
    :rand.seed(:exsss, {2, 2, 2})
    mod = Hw.build_tx()

    for _ <- 1..15 do
      gm = gmii(300)
      cfg = cfg_flags(300)
      assert tx_codes(mod, gm, cfg) == delayed(Ref.run(Enum.zip(gm, cfg)))
    end
  end

  test "a /C/ set is whole, alternates /C1/ /C2/ and sends the register low byte first" do
    mod = Hw.build_tx()
    reg = 0xA560
    gm = List.duplicate(@idle, 40)
    cfg = for i <- 1..40, do: {i in 5..14, reg}
    [_reset | out] = tx_codes(mod, gm, cfg)

    {syms, _} =
      Enum.map_reduce(out, :neg, fn code, rd ->
        {:ok, sym, rd2} = C.decode(rd, code)
        {sym, rd2}
      end)

    # idle sets until the boundary, then C1 C2 C1 (a started set is finished), then idles
    k = C.k(28, 5)
    lo = {:d, 0x60}
    hi = {:d, 0xA5}

    cfg_at =
      syms
      |> Enum.chunk_every(4, 1, :discard)
      |> Enum.find_index(&(&1 == [k, C.d(21, 5), lo, hi]))

    assert cfg_at != nil
    sets = Enum.slice(syms, cfg_at, 12)
    assert sets == [k, C.d(21, 5), lo, hi, k, C.d(2, 2), lo, hi, k, C.d(21, 5), lo, hi]
    assert Enum.slice(syms, cfg_at + 12, 2) in [[k, C.d(16, 2)], [k, C.d(5, 6)]]
  end

  # -- aligned receiver core --------------------------------------------------------

  # a code stream with configuration sets, frames, idles, bit errors and garbage
  defp code_stream(n) do
    Stream.repeatedly(fn ->
      case :rand.uniform(10) do
        1 ->
          for _ <- 1..:rand.uniform(6), do: :rand.uniform(1024) - 1

        2 ->
          codes = valid_codes(40)
          i = :rand.uniform(length(codes)) - 1
          List.update_at(codes, i, &Bitwise.bxor(&1, 1 <<< (:rand.uniform(10) - 1)))

        _ ->
          valid_codes(40 + :rand.uniform(80))
      end
    end)
    |> Stream.flat_map(& &1)
    |> Enum.take(n)
  end

  defp valid_codes(n), do: Ref.run(Enum.zip(gmii(n), cfg_flags(n)))

  defp phase_cont(:ord1, {:d, x}), do: x in [0xC5, 0x50, 0xB5, 0x42]
  defp phase_cont(p, {:d, _}) when p in [:cfg_lo, :cfg_hi], do: true
  defp phase_cont(_, _), do: false

  # expected rows: outputs of group i - 1 (reset values in row 0) next to the model
  # state before group i (the debug outputs)
  defp rx_rows(codes) do
    zero = %{
      rxd: 0,
      rx_dv: 0,
      rx_er: 0,
      sync: 0,
      config_valid: 0,
      config_reg: nil,
      idle_valid: 0,
      bad_valid: 0
    }

    {rows, _, _} =
      Enum.reduce(codes, {[], Rx.new(), zero}, fn code, {rows, s, prev} ->
        dbg = %{
          dbg_state: Hw.sync_code(s.sync.st),
          dbg_even: b(s.sync.even),
          dbg_good: s.sync.good,
          dbg_phase: Hw.phase_code(s.phase),
          dbg_rd: b(s.rd == :pos)
        }

        {s2, out} = Rx.step(s, code)
        {d, dv, er} = out.gmii
        sync = out.sync

        row = %{
          rxd: d,
          rx_dv: b(dv),
          rx_er: b(er),
          sync: b(sync),
          config_valid: b(out.config != nil),
          config_reg: out.config,
          idle_valid: b(sync and s.phase == :ord1 and out.symbol in [{:d, 0xC5}, {:d, 0x50}]),
          bad_valid:
            b(
              sync and s.phase in [:ord1, :cfg_lo, :cfg_hi] and
                not phase_cont(s.phase, out.symbol)
            )
        }

        {[Map.merge(prev, dbg) | rows], s2, row}
      end)

    Enum.reverse(rows)
  end

  @rx_keys [
    :rxd,
    :rx_dv,
    :rx_er,
    :sync,
    :config_valid,
    :config_reg,
    :idle_valid,
    :bad_valid,
    :dbg_state,
    :dbg_even,
    :dbg_good,
    :dbg_phase,
    :dbg_rd
  ]

  # config_reg is only specified while config_valid is high
  defp masked(rows, keys) do
    for o <- rows do
      o = Map.take(o, keys)
      if o.config_valid == 0, do: %{o | config_reg: nil}, else: o
    end
  end

  test "aligned core equals the Rx/Sync models cycle by cycle (states, GMII, ordered sets)" do
    :rand.seed(:exsss, {3, 3, 3})
    mod = Hw.build_rx_core()

    stats =
      for _ <- 1..12, reduce: %{cfg: 0, idle: 0, bad: 0, lost: 0, err: 0, dv: 0, sync: 0} do
        acc ->
          codes = code_stream(600)
          outs = RtlCase.run(mod, Enum.map(codes, &%{code10: &1}))
          got = masked(outs, @rx_keys)
          assert got == masked(rx_rows(codes), @rx_keys)

          {acc, _} =
            Enum.reduce(got, {acc, 0}, fn o, {a, prev_sync} ->
              a = %{
                a
                | cfg: a.cfg + o.config_valid,
                  idle: a.idle + o.idle_valid,
                  bad: a.bad + o.bad_valid,
                  lost: a.lost + b(prev_sync == 1 and o.sync == 0),
                  err: a.err + b(o.rx_er == 1),
                  dv: a.dv + o.rx_dv,
                  sync: a.sync + o.sync
              }

              {a, o.sync}
            end)

          acc
      end

    for {k, v} <- stats, do: assert(v > 0, "no #{k} in the random streams")
  end

  # -- alignment ---------------------------------------------------------------------

  defp bits(codes), do: for(c <- codes, i <- 9..0//-1, do: c >>> i &&& 1)

  defp chunks(bits),
    do:
      bits
      |> Enum.chunk_every(10, 10, :discard)
      |> Enum.map(&Enum.reduce(&1, 0, fn x, a -> a * 2 + x end))

  defp junk(n), do: for(_ <- 1..n//1, do: :rand.uniform(2) - 1)

  defp frame(len), do: for(_ <- 1..len, into: <<>>, do: <<:rand.uniform(256) - 1>>)

  # idle lead, frames with gaps, trailing idle: {codes, frames}
  defp stream_with_frames(lead) do
    frames = for _ <- 1..3, do: frame(60 + :rand.uniform(60))
    gm = List.duplicate(@idle, lead) ++ MAC.tx_cycles(frames) ++ List.duplicate(@idle, 20)
    {P.tx_run(gm), Enum.map(frames, &MAC.pad/1)}
  end

  defp received(outs) do
    outs
    |> Enum.map(&{&1.rxd, &1.rx_dv == 1, &1.rx_er == 1})
    |> MAC.rx_frames()
  end

  test "comma alignment locks for every bit offset 0-9 and delivers the same frames" do
    :rand.seed(:exsss, {4, 4, 4})
    mod = Hw.build_rx()

    for o <- 0..9 do
      {codes, frames} = stream_with_frames(30)
      chunk_in = chunks(junk(o) ++ bits(codes) ++ junk(20))
      outs = RtlCase.run(mod, Enum.map(chunk_in, &%{rx_code10: &1}))

      assert received(outs) == Enum.map(frames, &{:ok, &1})
      # the model on aligned groups sees the same frames
      assert codes |> P.rx_run() |> Enum.map(& &1.gmii) |> MAC.rx_frames() ==
               Enum.map(frames, &{:ok, &1})

      assert List.last(outs).shift == o
      assert List.last(outs).sync == 1

      # fixed latency: group g starts in chunk g, its output is in cycle g + 4
      g_s =
        Enum.find_index(
          codes,
          &(&1 == elem(C.encode(:neg, C.k(27, 7)), 0) or &1 == elem(C.encode(:pos, C.k(27, 7)), 0))
        )

      first_dv = Enum.find_index(outs, &(&1.rx_dv == 1))
      assert first_dv == g_s + 4
    end
  end

  test "a new comma re-aligns only after sync is lost (stream slip)" do
    :rand.seed(:exsss, {5, 5, 5})
    mod = Hw.build_rx()

    for _ <- 1..10 do
      o1 = :rand.uniform(10) - 1
      slip = :rand.uniform(9)
      {codes_a, frames_a} = stream_with_frames(30)
      {codes_b, frames_b} = stream_with_frames(40)
      bit_stream = junk(o1) ++ bits(codes_a) ++ junk(slip) ++ bits(codes_b) ++ junk(20)
      outs = RtlCase.run(mod, Enum.map(chunks(bit_stream), &%{rx_code10: &1}))

      # the first stream is received through alignment o1, the second after a slip of `slip` bits
      assert received(outs) == Enum.map(frames_a ++ frames_b, &{:ok, &1})
      assert List.last(outs).shift == rem(o1 + slip, 10)
      assert Enum.any?(Enum.drop_while(outs, &(&1.sync == 0)), &(&1.sync == 0))
    end
  end

  # -- top: two instances back to back -------------------------------------------------

  @lt 4
  @td 6

  defp pair do
    top = Hw.build(@lt, @td)
    outs = Module.outputs(top)

    module "pcs1000x_pair" do
      abil = input(:abil, 16)
      en = input(:en, 1)

      a_in =
        for n <- [:txd, :tx_en, :tx_er], do: {n, input(:"a_#{n}", if(n == :txd, do: 8, else: 1))}

      b_in =
        for n <- [:txd, :tx_en, :tx_er], do: {n, input(:"b_#{n}", if(n == :txd, do: 8, else: 1))}

      a = instance(:u_a, top, connect: [an_enable: en, an_restart: 0, an_ability: abil])
      b = instance(:u_b, top, connect: [an_enable: en, an_restart: 0, an_ability: abil])
      a.rx_code10 <~ b.tx_code10
      b.rx_code10 <~ a.tx_code10
      for {n, x} <- a_in, do: a[n] <~ x
      for {n, x} <- b_in, do: b[n] <~ x

      # every instance output is read (unread instance wires fail Verilator -Wall)
      for p <- outs, p.name != :tx_code10 do
        {_, w} = p.type
        oa = output(:"a_#{p.name}", w)
        ob = output(:"b_#{p.name}", w)
        oa <~ a[p.name]
        ob <~ b[p.name]
      end
    end
  end

  defp pair_events(a_gmii, b_gmii, abil, n) do
    pad = fn l -> Enum.take(l ++ List.duplicate(@idle, n), n) end

    for {{ad, aen, aer}, {bd, ben, ber}} <- Enum.zip(pad.(a_gmii), pad.(b_gmii)) do
      %{
        abil: abil,
        en: 1,
        a_txd: ad,
        a_tx_en: b(aen),
        a_tx_er: b(aer),
        b_txd: bd,
        b_tx_en: b(ben),
        b_tx_er: b(ber)
      }
    end
  end

  test "two instances negotiate to link_ok, then GMII frames cross both ways intact" do
    :rand.seed(:exsss, {6, 6, 6})
    abil = ExNet.PCS.AutoNeg.reg(fd: true, pause: true)
    fa = for _ <- 1..4, do: frame(60 + :rand.uniform(300))
    fb = for _ <- 1..4, do: frame(1 + :rand.uniform(200))
    n_wait = 400
    a_gmii = List.duplicate(@idle, n_wait) ++ MAC.tx_cycles(fa)
    b_gmii = List.duplicate(@idle, n_wait + 7) ++ MAC.tx_cycles(fb)
    n = max(length(a_gmii), length(b_gmii)) + 30
    outs = RtlCase.run(pair(), pair_events(a_gmii, b_gmii, abil, n))

    at = fn k -> Enum.at(outs, k) end
    # both sides negotiated well before the first frame
    link_at = Enum.find_index(outs, &(&1.a_link_up == 1 and &1.b_link_up == 1))
    assert link_at != nil and link_at < n_wait - 50
    assert {at.(n_wait).a_sync, at.(n_wait).b_sync} == {1, 1}
    assert {at.(n_wait).a_partner_reg, at.(n_wait).b_partner_reg} == {abil, abil}
    assert {at.(n_wait).a_duplex, at.(n_wait).a_pause} == {1, 3}
    assert at.(n_wait).a_an_state == ExNet.RTL.AutoNeg.state_code(:link_ok)
    assert Enum.any?(outs, &(&1.a_config_valid == 1))

    from = fn side ->
      outs
      |> Enum.map(
        &{Map.fetch!(&1, :"#{side}_rxd"), Map.fetch!(&1, :"#{side}_rx_dv") == 1,
         Map.fetch!(&1, :"#{side}_rx_er") == 1}
      )
      |> MAC.rx_frames()
    end

    assert from.(:b) == Enum.map(fa, &{:ok, MAC.pad(&1)})
    assert from.(:a) == Enum.map(fb, &{:ok, MAC.pad(&1)})
  end

  # -- co-simulation -----------------------------------------------------------------

  @tag :verilator
  test "transmitter co-simulates" do
    :rand.seed(:exsss, {7, 7, 7})
    RtlCase.cosim!(Hw.build_tx(), tx_events(gmii(300), cfg_flags(300)))
  end

  @tag :verilator
  test "aligned core co-simulates" do
    :rand.seed(:exsss, {8, 8, 8})
    RtlCase.cosim!(Hw.build_rx_core(), Enum.map(code_stream(300), &%{code10: &1}))
  end

  @tag :verilator
  test "receiver with alignment co-simulates" do
    :rand.seed(:exsss, {9, 9, 9})
    {codes, _} = stream_with_frames(30)
    chunk_in = chunks(junk(3) ++ bits(codes) ++ junk(20))
    RtlCase.cosim!(Hw.build_rx(), Enum.map(chunk_in, &%{rx_code10: &1}))
  end

  @tag :verilator
  test "back to back pair co-simulates through auto-negotiation" do
    :rand.seed(:exsss, {10, 10, 10})
    abil = ExNet.PCS.AutoNeg.reg(fd: true)
    RtlCase.cosim!(pair(), pair_events(gmii(0), gmii(0), abil, 350))
  end
end
