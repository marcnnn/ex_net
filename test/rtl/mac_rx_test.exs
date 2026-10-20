defmodule ExNet.RTL.MacRxTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExNet.MAC.{Rx, Rx64}
  alias ExNet.RTL.MacRx
  alias ExNet.{RtlCase, XgmiiGen}

  defp b(true), do: 1
  defp b(false), do: 0

  # -- 8 bit -----------------------------------------------------------------------------

  defp gmii_traffic do
    item =
      gen all(
            len <- one_of([integer(0..70), integer(0..140)]),
            data <- binary(length: len),
            fcs <- frequency([{7, constant(:good)}, {1, constant(:bad)}]),
            gap <- integer(1..4),
            er_at <- frequency([{9, constant(nil)}, {1, integer(0..(len + 4))}]),
            junk <- frequency([{8, constant(nil)}, {1, binary(min_length: 1, max_length: 12)}]),
            pre <- member_of([7, 7, 7, 3, 1])
          ) do
        body = XgmiiGen.wire(data, fcs)
        cyc = for _ <- 1..(pre - 1)//1, do: {0x55, true, false}
        cyc = cyc ++ [{0xD5, true, false}]

        cyc =
          cyc ++
            for {x, i} <- Enum.with_index(:binary.bin_to_list(body)), do: {x, true, i == er_at}

        junk = if junk, do: for(x <- :binary.bin_to_list(junk), do: {x, true, false}), else: []
        junk ++ [{0x55, true, false}] ++ cyc ++ List.duplicate({0, false, false}, gap)
      end

    list_of(item, min_length: 1, max_length: 5) |> map(&List.flatten/1)
  end

  defp rx8_events(cycles),
    do: for({d, v, e} <- cycles, do: %{gmii_rxd: d, gmii_rx_dv: b(v), gmii_rx_er: b(e)})

  defp rx_model(cycles, max_len) do
    {rows, _} =
      Enum.map_reduce(cycles, Rx.new(max_len: max_len), fn c, s ->
        sof = match?({:pre, _}, s.phase) and match?({0xD5, true, _}, c)
        {s2, ev} = Rx.step(s, c)
        {{sof, ev, s.count}, s2}
      end)

    rows
  end

  # per cycle t: expected {sof, end_status | nil, data | nil}, data = {byte, last?, user set}
  defp expect8(rows, max_len) do
    # group data events per frame to find the last
    {groups, _} =
      Enum.reduce(Enum.with_index(rows), {[], []}, fn
        {{_, {:data, _, _}, _}, t}, {done, cur} -> {done, [t | cur]}
        {{_, {:end, st}, n}, _}, {done, cur} -> {[{st, Enum.reverse(cur), n} | done], []}
        _, acc -> acc
      end)

    info =
      for {st, ts, n} <- groups, t <- ts, into: %{} do
        {t, {t == List.last(ts), st, n > max_len}}
      end

    for {{sof, ev, _}, t} <- Enum.with_index(rows) do
      data =
        with {:data, byte, _} <- ev do
          {last, st, cut} = Map.fetch!(info, t)
          user = if last, do: if(cut, do: :cut, else: Rx64.user(st)), else: 0
          {byte, b(last), user}
        else
          _ -> nil
        end

      {sof,
       case ev do
         {:end, st} -> st
         _ -> nil
       end, data}
    end
  end

  defp assert_rx8(cycles, outs, max_len) do
    exp = expect8(rx_model(cycles, max_len), max_len)
    n = length(cycles)
    assert hd(outs).m_axis_tvalid == 0

    for {{sof, en, data}, t} <- Enum.with_index(exp), t + 2 < n do
      o1 = Enum.at(outs, t + 1)
      o2 = Enum.at(outs, t + 2)
      assert o1.sof == b(sof), "sof, cycle #{t}"
      assert o1.frame_end == b(en != nil), "frame_end, cycle #{t}"
      if en, do: assert(o1.status == Rx64.code(en), "status, cycle #{t}")

      case data do
        nil ->
          assert o2.m_axis_tvalid == 0, "no beat, cycle #{t}"

        {byte, last, user} ->
          assert {o2.m_axis_tvalid, o2.m_axis_tdata, o2.m_axis_tlast} == {1, byte, last},
                 "beat, cycle #{t}"

          if user == :cut,
            do: assert(o2.m_axis_tuser in [0b1001, 0b0101]),
            else: assert(o2.m_axis_tuser == user, "tuser, cycle #{t}")
      end
    end
  end

  describe "mac_rx_8" do
    for max_len <- [1522, 100] do
      test "matches ExNet.MAC.Rx cycle by cycle (max_len #{max_len})" do
        mod = MacRx.build(8, max_len: unquote(max_len))

        check all(c <- gmii_traffic(), max_runs: 30) do
          cycles = c ++ List.duplicate({0, false, false}, 4)
          assert_rx8(cycles, RtlCase.run(mod, rx8_events(cycles)), unquote(max_len))
        end
      end
    end

    test "random bytes with random dv and er" do
      mod = MacRx.build(8, max_len: 100)

      check all(
              cycles <-
                list_of(
                  tuple(
                    {one_of([constant(0x55), constant(0xD5), integer(0..255)]), boolean(),
                     boolean()}
                  ),
                  max_length: 150
                ),
              max_runs: 30
            ) do
        cycles = cycles ++ [{0, false, false}] ++ List.duplicate({0, false, false}, 3)
        assert_rx8(cycles, RtlCase.run(mod, rx8_events(cycles)), 100)
      end
    end

    test "known frame passes with tlast and a good tuser" do
      mod = MacRx.build(8)
      frame = :binary.copy(<<0x3C>>, 60)
      cycles = ExNet.MAC.tx_cycles([frame])
      outs = RtlCase.run(mod, rx8_events(cycles ++ List.duplicate({0, false, false}, 4)))
      beats = for o <- outs, o.m_axis_tvalid == 1, do: o
      assert length(beats) == 60
      assert Enum.map(beats, & &1.m_axis_tdata) == :binary.bin_to_list(frame)
      assert Enum.map(beats, & &1.m_axis_tlast) == List.duplicate(0, 59) ++ [1]
      assert List.last(beats).m_axis_tuser == 0
    end

    @tag :verilator
    test "co-simulates" do
      mod = MacRx.build(8, max_len: 100)
      cycles = ExNet.MAC.tx_cycles([:binary.copy(<<0x11>>, 60), :binary.copy(<<0x22>>, 130), "z"])

      cycles =
        cycles ++ [{0x55, true, true}, {1, true, false}, {0, false, false}, {0, false, false}]

      RtlCase.cosim!(mod, rx8_events(cycles))
    end
  end

  # -- 64 bit ----------------------------------------------------------------------------

  defp rx64_events(words), do: for({d, c} <- words, do: %{xgmii_rxd: d, xgmii_rxc: c})

  # replace one lane of one word by a control character
  defp mutate(words, nil), do: words

  defp mutate(words, {wi, lane, ch}) do
    wi = rem(wi, length(words))

    List.update_at(words, wi, fn {d, c} ->
      {Bitwise.bor(
         Bitwise.band(d, Bitwise.bnot(Bitwise.bsl(0xFF, 8 * lane))),
         Bitwise.bsl(ch, 8 * lane)
       ), Bitwise.bor(c, Bitwise.bsl(1, lane))}
    end)
  end

  defp assert_rx64(words, outs, max_len) do
    {rows, _} =
      Enum.map_reduce(words, Rx64.new(max_len: max_len), fn w, s ->
        {s2, ev} = Rx64.step(s, w)
        {ev, s2}
      end)

    assert hd(outs).m_axis_tvalid == 0
    n = length(words)

    for {ev, t} <- Enum.with_index(rows), t + 1 < n do
      o = Enum.at(outs, t + 1)
      assert o.sof == b(ev.sof), "sof, cycle #{t}"
      assert o.frame_end == b(ev.end != nil), "frame_end, cycle #{t}"
      if ev.end, do: assert(o.status == Rx64.code(ev.end), "status, cycle #{t}")

      case ev.beat do
        nil ->
          assert o.m_axis_tvalid == 0, "no beat, cycle #{t}"

        {d, k, l, u} ->
          assert {o.m_axis_tvalid, o.m_axis_tdata, o.m_axis_tkeep, o.m_axis_tlast, o.m_axis_tuser} ==
                   {1, d, k, b(l), u},
                 "beat, cycle #{t}"
      end
    end
  end

  describe "mac_rx_64" do
    for max_len <- [1522, 100, 99, 70] do
      test "matches ExNet.MAC.Rx64 cycle by cycle (max_len #{max_len})" do
        mod = MacRx.build(64, max_len: unquote(max_len))

        check all(
                items <- XgmiiGen.traffic(max_len: 260, frames: 5),
                mut <-
                  frequency([
                    {3, constant(nil)},
                    {1,
                     tuple({integer(0..60), integer(0..7), member_of([0xFE, 0x07, 0xFB, 0xFD])})}
                  ]),
                max_runs: 40
              ) do
          words = XgmiiGen.words([{:idle, 1}] ++ items ++ [{:idle, 2}]) |> mutate(mut)
          assert_rx64(words, RtlCase.run(mod, rx64_events(words)), unquote(max_len))
        end
      end
    end

    test "random words" do
      mod = MacRx.build(64, max_len: 100)

      lane =
        frequency([
          {4, tuple({constant(0), integer(0..255)})},
          {2, tuple({constant(1), member_of([0x07, 0xFD, 0xFE, 0xFB, 0x55])})},
          {1, tuple({constant(0), member_of([0x55, 0xD5])})}
        ])

      check all(
              words <- list_of(map(list_of(lane, length: 8), &XgmiiGen.word/1), max_length: 60),
              max_runs: 40
            ) do
        words = words ++ [{0x0707070707070707, 0xFF}]
        assert_rx64(words, RtlCase.run(mod, rx64_events(words)), 100)
      end
    end

    test "known frames come out with tkeep and tuser" do
      mod = MacRx.build(64)
      frames = for n <- [5, 60, 61, 64, 100], do: :crypto.strong_rand_bytes(n)
      items = [{:idle, 1}] ++ Enum.flat_map(frames, &[{:frame, XgmiiGen.wire(&1), 0}, {:idle, 1}])
      words = XgmiiGen.words(items) ++ [{0x0707070707070707, 0xFF}]
      outs = RtlCase.run(mod, rx64_events(words))
      beats = for o <- outs, o.m_axis_tvalid == 1, do: o

      got =
        beats
        |> Enum.chunk_while(
          {<<>>, nil},
          fn o, {acc, _} ->
            n =
              for(
                i <- 0..7,
                reduce: 0,
                do: (a -> a + Bitwise.band(Bitwise.bsr(o.m_axis_tkeep, i), 1))
              )

            acc = acc <> <<o.m_axis_tdata::little-size(8 * n)>>

            if o.m_axis_tlast == 1,
              do: {:cont, {acc, o.m_axis_tuser}, {<<>>, nil}},
              else: {:cont, {acc, nil}}
          end,
          fn _ -> {:cont, nil} end
        )

      assert got == for(f <- frames, do: {f, if(byte_size(f) < 60, do: 7, else: 0)})
    end

    @tag :verilator
    test "co-simulates" do
      mod = MacRx.build(64, max_len: 100)

      items = [
        {:idle, 1},
        {:frame, XgmiiGen.wire(:binary.copy(<<7>>, 90)), 4},
        {:frame, XgmiiGen.wire("abc"), 0},
        {:frame, XgmiiGen.wire(:binary.copy(<<5>>, 70), :bad), 0},
        {:idle, 2}
      ]

      words = XgmiiGen.words(items) |> mutate({3, 5, 0xFE})
      RtlCase.cosim!(mod, rx64_events(words))
    end
  end
end
