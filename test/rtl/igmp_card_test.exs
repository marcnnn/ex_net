defmodule ExNet.RTL.IgmpCardTest do
  use ExUnit.Case, async: true

  alias ExNet.{IgmpBench, NetTops, RtlCase, UdpSource, XgmiiGen}
  alias ExNet.IGMP.{Query, Record, ReportV3}
  alias ExNet.MAC.Rx64

  @moduletag timeout: 600_000
  @g1 {239, 69, 1, 1}
  @g2 {239, 69, 1, 2}
  @idle {0x0707070707070707, 0xFF}

  defp mod, do: NetTops.igmp_top(groups: 4, clk_hz: 20_000)

  defp pad60(f) when byte_size(f) < 60, do: f <> :binary.copy(<<0>>, 60 - byte_size(f))
  defp pad60(f), do: f

  # Closed loop: XGMII words from `rx` (a list of {start_cycle, frame}), commands from
  # `cmds`, one UDP packet source on s0.
  defp run(rx, cmds, packets, cycles) do
    words =
      Enum.reduce(Enum.sort_by(rx, &elem(&1, 0)), {[], 0}, fn {at, f}, {acc, pos} ->
        pre = List.duplicate(@idle, max(at - pos, 0))
        w = XgmiiGen.words([{:idle, 2}, {:frame, XgmiiGen.wire(f, :good), 0}, {:idle, 2}])
        {acc ++ [pre, w], max(at, pos) + length(w)}
      end)
      |> elem(0)
      |> List.flatten()

    init = %{words: words, cmds: Enum.sort(cmds), cur: nil, src: UdpSource.new(packets)}
    cfg = IgmpBench.cfg(robustness: 1)

    {events, outs, acc} =
      RtlCase.drive(mod(), init, cycles, fn acc, i ->
        {rxd, rxc, words} =
          case acc.words do
            [{d, c} | rest] -> {d, c, rest}
            [] -> {elem(@idle, 0), elem(@idle, 1), []}
          end

        {cmd, acc} =
          case {acc.cur, acc.cmds} do
            {nil, [{t, k, g} | more]} when t <= i ->
              {%{
                 cmd_valid: 1,
                 cmd_leave: if(k == :leave, do: 1, else: 0),
                 cmd_group: ExNet.IPv4.ip_int(g)
               }, %{acc | cur: {k, g}, cmds: more}}

            {{k, g}, _} ->
              {%{
                 cmd_valid: 1,
                 cmd_leave: if(k == :leave, do: 1, else: 0),
                 cmd_group: ExNet.IPv4.ip_int(g)
               }, acc}

            _ ->
              {%{}, acc}
          end

        {src_in, offer} = UdpSource.offer(acc.src, "s0_axis", 0)

        inputs =
          cfg
          |> Map.merge(cmd)
          |> Map.merge(src_in)
          |> Map.merge(%{
            xgmii_rxd: rxd,
            xgmii_rxc: rxc,
            uc_mac: 0x0A0102030405,
            s0_src_port: 5004,
            s0_ttl: 8
          })

        {inputs,
         fn o ->
           acc = %{acc | words: words, src: UdpSource.settle(acc.src, offer, o.s0_axis_tready)}

           if Map.get(inputs, :cmd_valid) == 1 and o.cmd_ready == 1,
             do: %{acc | cur: nil},
             else: acc
         end}
      end)

    frames = Rx64.frames(for o <- outs, do: {o.xgmii_txd, o.xgmii_txc})
    {events, outs, frames, acc}
  end

  defp igmp_msgs(frames) do
    for {:ok, bytes} <- frames, {:ok, m} <- [ExNet.IGMP.Host.decode_frame(bytes)], do: m
  end

  test "joins, a query on the wire and the answer, next to UDP traffic" do
    qf = IgmpBench.query_frame(%Query{version: 3, max_resp: 2})
    packets = for i <- 1..4, do: {:binary.copy(<<i>>, 60), {{239, 69, 2, i}, 5004}}

    {_, outs, frames, acc} =
      run([{1500, qf}], [{5, :join, @g1}, {6, :join, @g2}], packets, 1500 + 400 * 20 + 800)

    assert Enum.all?(frames, fn {st, _} -> st == :ok end)
    assert UdpSource.done?(acc.src)

    igmp =
      for {_, b} <- frames, match?({:ok, _}, ExNet.IGMP.Host.decode_frame(b)), do: b

    expected =
      [
        IgmpBench.expect(%ReportV3{records: [%Record{type: :change_to_exclude, group: @g1}]}),
        IgmpBench.expect(%ReportV3{records: [%Record{type: :change_to_exclude, group: @g2}]}),
        IgmpBench.expect(%ReportV3{
          records: [
            %Record{type: :mode_is_exclude, group: @g1},
            %Record{type: :mode_is_exclude, group: @g2}
          ]
        })
      ]
      |> Enum.map(&pad60/1)

    assert Enum.sort(igmp) == Enum.sort(expected)
    assert length(frames) == 3 + 4
    assert List.last(outs).member == 3
    # the MAC appended a valid frame check sequence (Rx64 says :ok); tx_sof once per frame
    assert Enum.count(outs, &(&1.tx_sof == 1)) == length(frames)
    assert length(igmp_msgs(frames)) == 3
  end

  @tag :verilator
  test "Verilator equals the BEAM simulator on the card wiring" do
    qf = IgmpBench.query_frame(%Query{version: 3, max_resp: 1})
    packets = for i <- 1..2, do: {:binary.copy(<<i>>, 30), {{239, 69, 2, i}, 5004}}
    {events, _, _, _} = run([{900, qf}], [{5, :join, @g1}], packets, 3500)
    RtlCase.cosim!(mod(), events)
  end
end
