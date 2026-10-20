defmodule ExNet.RTL.PCS10GRTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  use ExHdl.RTL

  import Bitwise
  alias ExNet.PCS.{Base10GR, Block66}
  alias ExNet.RTL.PCS10GR, as: Hw
  alias ExNet.RtlCase

  # -- stimulus -----------------------------------------------------------------------

  defp frame_gen do
    StreamData.bind(StreamData.integer(8..100), fn n ->
      StreamData.tuple({StreamData.binary(length: n), StreamData.integer(0..3)})
    end)
  end

  # lock-up idles, frames back to back and with idles, a few trailing idles
  defp traffic do
    StreamData.map(StreamData.list_of(frame_gen(), min_length: 1, max_length: 5), fn frames ->
      Base10GR.idle_words(70) ++
        Enum.flat_map(frames, fn {bin, gap} ->
          Base10GR.frame_words(bin) ++ Base10GR.idle_words(gap)
        end) ++ Base10GR.idle_words(3)
    end)
  end

  defp garbage_words do
    word =
      StreamData.one_of([
        StreamData.tuple({StreamData.integer(0..0xFFFFFFFFFFFFFFFF), StreamData.integer(0..255)}),
        StreamData.member_of([Block66.idle(), Block66.error_word(), {0xD5555555555555FB, 1}]),
        StreamData.map(StreamData.integer(0..0xFFFFFFFFFFFFFFFF), &{&1, 0}),
        StreamData.map(StreamData.integer(0..7), fn k ->
          {(0x0707070707070707 &&& ~~~(0xFF <<< (8 * k))) ||| 0xFD <<< (8 * k), 0xFF}
        end)
      ])

    StreamData.list_of(word, min_length: 20, max_length: 150)
  end

  defp garbage_blocks do
    block =
      StreamData.tuple({
        StreamData.frequency([
          {8, StreamData.member_of([1, 2])},
          {1, StreamData.member_of([0, 3])}
        ]),
        StreamData.integer(0..0xFFFFFFFFFFFFFFFF)
      })

    StreamData.list_of(block, min_length: 100, max_length: 250)
  end

  # locked traffic with a burst of corrupt headers and random blocks appended
  defp rx_blocks do
    StreamData.bind(traffic(), fn ws ->
      StreamData.map(garbage_blocks(), fn junk -> Base10GR.tx_run(ws) ++ junk end)
    end)
  end

  defp b(true), do: 1
  defp b(false), do: 0

  # -- TX -----------------------------------------------------------------------------

  defp tx_events(ws, en \\ nil) do
    ws
    |> Enum.with_index()
    |> Enum.map(fn {{d, c}, i} -> %{data: d, ctl: c, en: if(en, do: Enum.at(en, i), else: 1)} end)
  end

  defp tx_expected(ws) do
    for {sync, p} <- Base10GR.tx_run(ws), do: %{tx_valid: 1, tx_data: p, tx_header: sync}
  end

  defp tx_run(mod, ws), do: mod |> RtlCase.run(tx_events(ws) ++ [%{}]) |> Enum.drop(1)

  test "tx: reset values and one cycle latency" do
    out = RtlCase.run(Hw.tx(), tx_events([Block66.idle()]) ++ [%{}, %{}])
    assert [%{tx_valid: 0, tx_data: 0, tx_header: 0}, %{tx_valid: 1}, %{tx_valid: 0}] = out
    assert Enum.at(out, 1).tx_header == 2
  end

  test "tx matches Base10GR.tx_step on frame traffic" do
    mod = Hw.tx()

    check all(ws <- traffic(), max_runs: 6) do
      assert tx_run(mod, ws) == tx_expected(ws)
    end
  end

  test "tx matches Base10GR.tx_step on random garbage" do
    mod = Hw.tx()

    check all(ws <- garbage_words(), max_runs: 15) do
      assert tx_run(mod, ws) == tx_expected(ws)
    end
  end

  test "tx with random enables: valid outputs are the model's blocks" do
    mod = Hw.tx()

    check all(
            ws <- garbage_words(),
            en <- StreamData.list_of(StreamData.member_of([1, 1, 0]), length: length(ws)),
            max_runs: 10
          ) do
      outs = RtlCase.run(mod, tx_events(ws, en) ++ [%{}]) |> Enum.drop(1)
      assert Enum.map(outs, & &1.tx_valid) == en

      assert for(%{tx_valid: 1} = o <- outs, do: o) ==
               tx_expected(for({w, 1} <- Enum.zip(ws, en), do: w))

      idle = for(%{tx_valid: 0} = o <- outs, do: {o.tx_data, o.tx_header})

      assert Enum.all?(idle, &(&1 == {0, 0}))
    end
  end

  # -- RX -----------------------------------------------------------------------------

  defp rx_events(blocks, en \\ nil) do
    blocks
    |> Enum.with_index()
    |> Enum.map(fn {{s, p}, i} ->
      %{rx_data: p, rx_header: s, en: if(en, do: Enum.at(en, i), else: 1)}
    end)
  end

  defp rx_expected(blocks) do
    for o <- Base10GR.rx_run(blocks) do
      {d, c} = o.xgmii || {0, 0}

      %{
        out_valid: 1,
        lock: b(o.lock),
        rx_bitslip: b(o.slip),
        xgmii_valid: b(o.xgmii != nil),
        xgmii_data: d,
        xgmii_ctl: c
      }
    end
  end

  defp rx_run(mod, blocks), do: mod |> RtlCase.run(rx_events(blocks) ++ [%{}]) |> Enum.drop(1)

  test "rx matches Base10GR.rx_step on traffic followed by corrupt blocks" do
    mod = Hw.rx()

    check all(blocks <- rx_blocks(), max_runs: 6) do
      assert rx_run(mod, blocks) == rx_expected(blocks)
    end
  end

  test "rx matches Base10GR.rx_step on random blocks" do
    mod = Hw.rx()

    check all(blocks <- garbage_blocks(), max_runs: 10) do
      assert rx_run(mod, blocks) == rx_expected(blocks)
    end
  end

  test "rx is silent before lock and locks on the 64th valid header" do
    blocks = Base10GR.tx_run(Base10GR.idle_words(80))
    out = rx_run(Hw.rx(), blocks)
    assert Enum.find_index(out, &(&1.xgmii_valid == 1)) == 63
    assert Enum.all?(Enum.take(out, 63), &(&1.xgmii_data == 0 and &1.lock == 0))
  end

  test "rx with random enables: enabled cycles equal the model, others emit nothing" do
    mod = Hw.rx()

    check all(
            blocks <- rx_blocks(),
            en <- StreamData.list_of(StreamData.member_of([1, 1, 1, 0]), length: 400),
            max_runs: 4
          ) do
      en = Enum.take(en ++ List.duplicate(1, length(blocks)), length(blocks))
      outs = RtlCase.run(mod, rx_events(blocks, en) ++ [%{}]) |> Enum.drop(1)
      used = for {bl, 1} <- Enum.zip(blocks, en), do: bl
      assert Enum.map(outs, & &1.out_valid) == en
      assert for(%{out_valid: 1} = o <- outs, do: o) == rx_expected(used)
      assert Enum.all?(outs, &(&1.out_valid == 1 or (&1.xgmii_valid == 0 and &1.rx_bitslip == 0)))
    end
  end

  # -- combined and back to back --------------------------------------------------------

  def loop do
    module "pcs10gr_loop" do
      data = input(:data, 64)
      ctl = input(:ctl, 8)
      en = input(:en, 1)
      lock = output(:lock, 1)
      xv = output(:xgmii_valid, 1)
      xd = output(:xgmii_data, 64)
      xc = output(:xgmii_ctl, 8)
      ov = output(:out_valid, 1)
      sl = output(:rx_bitslip, 1)
      t = instance(:u_tx, Hw.tx(), connect: [data: data, ctl: ctl, en: en])

      r =
        instance(:u_rx, Hw.rx(),
          connect: [rx_data: t.tx_data, rx_header: t.tx_header, en: t.tx_valid]
        )

      lock <~ r.lock
      xv <~ r.xgmii_valid
      xd <~ r.xgmii_data
      xc <~ r.xgmii_ctl
      ov <~ r.out_valid
      sl <~ r.rx_bitslip
    end
  end

  test "combined pcs10gr is tx and rx side by side" do
    ws =
      Base10GR.idle_words(70) ++
        Base10GR.frame_words(:binary.copy(<<0x55, 7>>, 20)) ++ Base10GR.idle_words(2)

    blocks = Base10GR.tx_run(ws)
    n = length(ws)

    evs =
      for i <- 0..(n - 1) do
        {d, c} = Enum.at(ws, i)
        {s, p} = Enum.at(blocks, rem(i * 7 + 3, n))

        %{tx_xgmii_data: d, tx_xgmii_ctl: c, tx_en: 1, rx_data: p, rx_header: s, rx_en: 1}
      end

    out = RtlCase.run(Hw.pcs(), evs ++ [%{}]) |> Enum.drop(1)
    rx_in = for i <- 0..(n - 1), do: Enum.at(blocks, rem(i * 7 + 3, n))
    tx_exp = tx_expected(ws)
    rx_exp = rx_expected(rx_in)

    assert Enum.map(out, &Map.take(&1, [:tx_data, :tx_header, :tx_valid])) == tx_exp

    assert Enum.map(out, fn o ->
             %{
               out_valid: o.rx_out_valid,
               lock: o.rx_lock,
               rx_bitslip: o.rx_bitslip,
               xgmii_valid: o.rx_xgmii_valid,
               xgmii_data: o.rx_xgmii_data,
               xgmii_ctl: o.rx_xgmii_ctl
             }
           end) == rx_exp
  end

  test "tx to rx back to back returns the frames intact" do
    mod = loop()

    check all(ws <- traffic(), max_runs: 5) do
      out =
        RtlCase.run(
          mod,
          tx_events(ws) ++ [%{}, %{}, %{}]
        )

      got = for %{xgmii_valid: 1, xgmii_data: d, xgmii_ctl: c} <- out, do: {d, c}
      frames = Base10GR.parse_frames(ws)
      assert frames != []
      assert Base10GR.parse_frames(got) == frames
      # the words themselves, once the descrambler has settled (after 64 locked blocks)
      assert Enum.take(got, -(length(ws) - 66)) == Enum.drop(ws, 66)
    end
  end

  # -- Verilator ------------------------------------------------------------------------

  defp short(gen, n), do: gen |> Enum.take(1) |> hd() |> Enum.take(n)

  @tag :verilator
  test "tx co-simulates" do
    ws = short(garbage_words(), 150)
    en = for i <- 0..(length(ws) - 1), do: if(rem(i * 5, 7) == 3, do: 0, else: 1)
    RtlCase.cosim!(Hw.tx(), tx_events(ws, en))
  end

  @tag :verilator
  test "rx co-simulates, including lock acquisition and loss" do
    blocks =
      Base10GR.tx_run(Base10GR.idle_words(80) ++ Base10GR.frame_words(:binary.copy(<<9>>, 40)))

    junk = for i <- 1..60, do: {rem(i * 5, 4), i * 0x9E3779B97F4A7C15 &&& 0xFFFFFFFFFFFFFFFF}
    blocks = blocks ++ junk ++ Base10GR.tx_run(Base10GR.idle_words(70))
    en = for i <- 1..length(blocks), do: if(rem(i, 9) == 0, do: 0, else: 1)
    RtlCase.cosim!(Hw.rx(), rx_events(blocks, en))
  end

  @tag :verilator
  test "pcs10gr and the back to back loop co-simulate" do
    ws =
      Base10GR.idle_words(70) ++
        Base10GR.frame_words(:binary.copy(<<0xA5, 3>>, 30)) ++ Base10GR.idle_words(4)

    evs = tx_events(ws)
    RtlCase.cosim!(loop(), evs)

    evs =
      for {{d, c}, {s, p}} <- Enum.zip(ws, Base10GR.tx_run(ws)) do
        %{tx_xgmii_data: d, tx_xgmii_ctl: c, tx_en: 1, rx_data: p, rx_header: s, rx_en: 1}
      end

    RtlCase.cosim!(Hw.pcs(), evs)
  end
end
