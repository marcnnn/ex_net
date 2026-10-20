defmodule ExNet.RTL.MacTxTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExNet.MAC.{Tx, Tx64}
  alias ExNet.RTL.MacTx
  alias ExNet.RtlCase

  alias ExNet.AxisSource

  defp plans, do: AxisSource.plans()
  defp run_plan(mod, plans, w), do: AxisSource.run(mod, plans, w)

  defp b(true), do: 1
  defp b(false), do: 0

  defp offer_of(%{s_axis_tvalid: 0}, _), do: nil
  defp offer_of(%{s_axis_tdata: d, s_axis_tlast: l}, 1), do: {d, l == 1}
  defp offer_of(%{s_axis_tdata: d, s_axis_tkeep: k, s_axis_tlast: l}, 8), do: {d, k, l == 1}

  # -- 8 bit -----------------------------------------------------------------------------

  describe "mac_tx_8" do
    for ifg <- [12, 5] do
      test "matches ExNet.MAC.Tx cycle by cycle (ifg #{ifg})" do
        mod = MacTx.build(8, ifg: unquote(ifg))

        check all(p <- plans(), max_runs: 25) do
          {events, outs, _} = run_plan(mod, p, 1)
          assert_tx8(events, outs, unquote(ifg))
        end
      end
    end

    defp assert_tx8(events, outs, ifg) do
      {model, _} =
        Enum.map_reduce(events, Tx.new(ifg: ifg), fn ev, s ->
          sfd = s.phase == {:pre, 7}
          {s2, out, ready} = Tx.step(s, offer_of(ev, 1))
          {{out, ready, sfd}, s2}
        end)

      assert hd(outs).gmii_tx_en == 0
      n = length(events)

      for t <- 0..(n - 2) do
        {{d, en, er}, ready, sfd} = Enum.at(model, t)
        o = Enum.at(outs, t)
        nx = Enum.at(outs, t + 1)
        ev = Enum.at(events, t)

        assert {nx.gmii_txd, nx.gmii_tx_en, nx.gmii_tx_er, nx.sof} ==
                 {d, b(en), b(er), b(sfd)},
               "cycle #{t}"

        assert (o.s_axis_tready == 1 and ev.s_axis_tvalid == 1) == ready, "ready, cycle #{t}"
      end
    end

    test "frame output equals the byte model's wire cycles" do
      mod = MacTx.build(8)
      frame = :binary.copy(<<0x5A>>, 61)
      {events, outs, _} = run_plan(mod, [{frame, 2, nil}, {"abc", 0, nil}], 1)
      got = for o <- outs, o.gmii_tx_en == 1, do: o.gmii_txd
      want = for {d, true, _} <- ExNet.MAC.tx_cycles([frame, "abc"]), do: d
      assert got == want
      assert length(events) == length(outs)
    end

    @tag :verilator
    test "co-simulates" do
      mod = MacTx.build(8)
      {events, _, _} = run_plan(mod, [{:binary.copy(<<0xA7>>, 30), 1, nil}, {"xy", 3, 1}], 1)
      RtlCase.cosim!(mod, events)
    end
  end

  # -- 64 bit ----------------------------------------------------------------------------

  describe "mac_tx_64" do
    test "matches ExNet.MAC.Tx64 cycle by cycle" do
      mod = MacTx.build(64)

      check all(p <- plans(), max_runs: 30) do
        {events, outs, _} = run_plan(mod, p, 8)
        assert_tx64(events, outs)
      end
    end

    defp assert_tx64(events, outs) do
      {model, _} =
        Enum.map_reduce(events, Tx64.new(), fn ev, s ->
          offer = offer_of(ev, 8)
          sof = s.phase == :idle and offer != nil
          {s2, out, ready} = Tx64.step(s, offer)
          {{out, ready, sof}, s2}
        end)

      assert hd(outs).xgmii_txc == 0xFF
      n = length(events)

      for t <- 0..(n - 2) do
        {{d, c}, ready, sof} = Enum.at(model, t)
        o = Enum.at(outs, t)
        nx = Enum.at(outs, t + 1)
        ev = Enum.at(events, t)
        assert {nx.xgmii_txd, nx.xgmii_txc, nx.sof} == {d, c, b(sof)}, "cycle #{t}"
        assert (o.s_axis_tready == 1 and ev.s_axis_tvalid == 1) == ready, "ready, cycle #{t}"
      end
    end

    test "back to back frames reproduce ExNet.MAC.Tx64.run words" do
      mod = MacTx.build(64)
      frames = [:binary.copy(<<1>>, 5), :binary.copy(<<2>>, 64), :binary.copy(<<3>>, 77), "x"]
      {_, outs, _} = run_plan(mod, Enum.map(frames, &{&1, 0, nil}), 8)
      words = for o <- outs, do: {o.xgmii_txd, o.xgmii_txc}
      want = Tx64.run(frames)
      first = Enum.find_index(words, &(&1 == Tx64.start_word()))
      assert Enum.slice(words, first, length(want) - 1) == Enum.slice(want, 0, length(want) - 1)
    end

    test "carries the byte model's wire frames" do
      mod = MacTx.build(64)
      frames = for n <- [1, 20, 59, 60, 61, 72, 150], do: :crypto.strong_rand_bytes(n)
      {_, outs, _} = run_plan(mod, Enum.map(frames, &{&1, 1, nil}), 8)
      words = for o <- outs, do: {o.xgmii_txd, o.xgmii_txc}
      assert ExNet.PCS.Base10GR.parse_frames(words) == Enum.map(frames, &ExNet.MAC.wire_frame/1)
    end

    @tag :verilator
    test "co-simulates" do
      mod = MacTx.build(64)
      p = [{:binary.copy(<<0xA7>>, 30), 1, nil}, {"xy", 3, nil}, {:binary.copy(<<9>>, 70), 0, 2}]
      {events, _, _} = run_plan(mod, p, 8)
      RtlCase.cosim!(mod, events)
    end
  end
end
