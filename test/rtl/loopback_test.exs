defmodule ExNet.RTL.LoopbackTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExNet.{AxisSource, RtlCase}
  alias ExNet.RTL.Loopback

  # frames from the master stream: [{bytes, tuser}]
  defp frames(outs, w) do
    {done, _} =
      outs
      |> Enum.filter(&(&1.m_axis_tvalid == 1))
      |> Enum.reduce({[], <<>>}, fn o, {done, cur} ->
        n =
          if w == 1,
            do: 1,
            else: Enum.count(0..7, &(Bitwise.band(Bitwise.bsr(o.m_axis_tkeep, &1), 1) == 1))

        cur = cur <> <<o.m_axis_tdata::little-size(8 * n)>>
        if o.m_axis_tlast == 1, do: {[{cur, o.m_axis_tuser} | done], <<>>}, else: {done, cur}
      end)

    Enum.reverse(done)
  end

  defp plans_after_lock(frames),
    do: for({f, i} <- Enum.with_index(frames), do: {f, if(i == 0, do: 120, else: 3), nil})

  for {kind, w, lat} <- [{:gbe, 1, {8, 14, 20}}, {:xgbe, 8, {1, 4, 6}}] do
    describe "#{kind} loopback" do
      @kind kind
      @w w
      @lat lat

      test "reproduces random frames" do
        mod = Loopback.build(@kind)

        check all(
                fs <-
                  list_of(binary(min_length: 1, max_length: 120), min_length: 1, max_length: 4),
                max_runs: 8
              ) do
          {_, outs, _} = AxisSource.run(mod, plans_after_lock(fs), @w, 60)
          assert frames(outs, @w) == for(f <- fs, do: {ExNet.MAC.pad(f), 0})
          assert Enum.sum(for o <- outs, do: o.frame_end) == length(fs)
        end
      end

      test "frame latency and sof alignment" do
        mod = Loopback.build(@kind)
        f = :binary.copy(<<0x42>>, 64)
        {events, outs, _} = AxisSource.run(mod, [{f, 120, nil}], @w, 60)
        first = fn list, fun -> Enum.find_index(list, fun) end
        t_in = first.(events, &(&1.s_axis_tvalid == 1))
        t_out = first.(outs, &(&1.m_axis_tvalid == 1))
        t_sof_tx = first.(outs, &(&1.sof_tx == 1))
        t_sof_rx = first.(outs, &(&1.sof_rx == 1))

        assert {t_sof_tx - t_in, t_sof_rx - t_in, t_out - t_in} == @lat

        assert Enum.at(outs, t_sof_tx).sof_tx == 1

        assert Enum.count(outs, &(&1.sof_tx == 1)) == 1 and
                 Enum.count(outs, &(&1.sof_rx == 1)) == 1

        assert t_sof_rx > t_sof_tx
        assert t_out > t_sof_rx
      end

      @tag :verilator
      test "co-simulates" do
        mod = Loopback.build(@kind)

        {events, _, _} =
          AxisSource.run(mod, plans_after_lock([:binary.copy(<<0x5A>>, 70), "hi"]), @w, 60)

        RtlCase.cosim!(mod, events)
      end
    end
  end
end
