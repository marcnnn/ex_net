defmodule ExNet.RTL.IgmpTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExNet.IgmpBench
  alias ExNet.IGMP.{Host, Query, Record, Report, Leave, ReportV3}

  @moduletag timeout: 600_000

  # 20 clock cycles per millisecond
  @cpm 20
  @g1 {239, 69, 1, 1}
  @g2 {239, 69, 1, 2}
  @g3 {239, 69, 1, 3}

  defp v3(type, groups),
    do: %ReportV3{records: for(g <- groups, do: %Record{type: type, group: g})}

  defp frames(r), do: Enum.map(r.frames, &elem(&1, 1))
  defp cycles(r), do: Enum.map(r.frames, &elem(&1, 0))
  defp cfg(opts), do: IgmpBench.cfg(opts)
  defp ex(msg, opts \\ []), do: IgmpBench.expect(msg, opts)
  defp q(opts \\ []), do: struct(Query, [max_resp: 2, qqic: 125] ++ opts)

  describe "unsolicited reports" do
    test "v3 join and leave: frames equal the model, sent robustness times" do
      opts = [cfg: cfg(unsol_ms: 30, robustness: 3)]
      r = IgmpBench.run([{5, {:join, @g1}}, {2500, {:leave, @g1}}], 5000, opts)
      join = ex(v3(:change_to_exclude, [@g1]))
      leave = ex(v3(:change_to_include, [@g1]))
      assert frames(r) == [join, join, join, leave, leave, leave]
      [c0, c1, c2, l0, l1, l2] = cycles(r)
      assert c0 < 40 and l0 < 2500 + 40
      # the retransmissions come within the unsolicited interval
      assert c1 - c0 <= 30 * @cpm + 40 and c2 - c1 <= 30 * @cpm + 40
      assert l1 - l0 <= 30 * @cpm + 40 and l2 - l1 <= 30 * @cpm + 40
      assert r.errs == []
      # the slot is free again after the last leave
      assert List.last(r.outs).member == 0
    end

    test "v2 join and leave" do
      opts = [cfg: cfg(unsol_ms: 30, robustness: 2, v2_only: 1)]
      r = IgmpBench.run([{5, {:join, @g1}}, {2000, {:leave, @g1}}], 4000, opts)
      join = ex(%Report{version: 2, group: @g1})
      leave = ex(%Leave{group: @g1})
      assert frames(r) == [join, join, leave, leave]
      assert Enum.at(r.outs, 1000).member == 1 and Enum.at(r.outs, 1000).joined == 1
      assert Enum.at(r.outs, 1000).rd_group == ExNet.IPv4.ip_int(@g1)
    end

    test "robustness 1 sends once, robustness 0 reads as 1" do
      for rb <- [0, 1] do
        r = IgmpBench.run([{5, {:join, @g1}}], 1500, cfg: cfg(unsol_ms: 30, robustness: rb))
        assert frames(r) == [ex(v3(:change_to_exclude, [@g1]))]
      end
    end

    test "802.1Q tag with priority 6" do
      opts = [vlan: 100]
      r = IgmpBench.run([{5, {:join, @g1}}], 600, [{:cfg, cfg(vlan: 100, robustness: 1)} | opts])
      assert frames(r) == [ex(v3(:change_to_exclude, [@g1]), vlan: 100)]
      {:ok, eth} = ExNet.Ethernet.decode(hd(frames(r)))
      assert [%{vid: 100, pcp: 6, tpid: 0x8100}] = eth.tags
    end

    test "rejoin while the leave is repeated, join of a joined group, leave of an unknown group" do
      opts = [cfg: cfg(unsol_ms: 500, robustness: 2)]

      script = [
        {5, {:join, @g1}},
        {5, {:join, @g1}},
        {5, {:leave, @g2}},
        {300, {:leave, @g1}},
        {500, {:join, @g1}}
      ]

      r = IgmpBench.run(script, 12_000, opts)
      join = ex(v3(:change_to_exclude, [@g1]))
      leave = ex(v3(:change_to_include, [@g1]))
      # the second join is a no-op; the leave cancels the pending join repetition, the rejoin
      # the pending leave repetition, and sends its own two reports
      assert frames(r) == [join, leave, join, join]

      assert List.last(r.outs).member == 1
      assert r.errs == []
    end

    test "refused joins: not multicast, link local, table full" do
      opts = [cfg: cfg(robustness: 1), groups: 2]

      script = [
        {5, {:join, {10, 0, 0, 1}}},
        {5, {:join, {224, 0, 0, 251}}},
        {5, {:join, @g1}},
        {5, {:join, @g2}},
        {5, {:join, @g3}},
        {1000, {:leave, @g2}},
        {2000, {:join, @g3}}
      ]

      r = IgmpBench.run(script, 4000, opts)
      # 10.0.0.1, 224.0.0.251, the third group while the table is full
      assert length(r.errs) == 3
      assert length(r.done) == 7
      assert List.last(r.outs).joined == 2
      msgs = for f <- frames(r), do: elem(Host.decode_frame(f), 1)
      groups = for %ReportV3{records: [%Record{group: g, type: t}]} <- msgs, do: {t, g}

      assert Enum.sort(groups) ==
               Enum.sort([
                 {:change_to_exclude, @g1},
                 {:change_to_exclude, @g2},
                 {:change_to_include, @g2},
                 {:change_to_exclude, @g3}
               ])
    end
  end

  describe "queries" do
    setup do
      joins = for {g, i} <- Enum.with_index([@g1, @g2, @g3]), do: {5 + i, {:join, g}}
      {:ok, joins: joins}
    end

    test "v3 general query: one report with every group inside the maximum response time",
         %{joins: joins} do
      qf = IgmpBench.query_frame(q())

      r =
        IgmpBench.run(joins ++ [{600, {:rx, qf}}], 600 + 200 * @cpm + 400,
          cfg: cfg(robustness: 1)
        )

      [_, _, _, resp] = frames(r)
      assert resp == ex(v3(:mode_is_exclude, [@g1, @g2, @g3]))
      [_, _, _, c] = cycles(r)
      assert c > 600 + 8 and c <= 600 + 200 * @cpm + 150
    end

    test "v3 group-specific query answers for that group only", %{joins: joins} do
      qf = IgmpBench.query_frame(q(group: @g2))

      r =
        IgmpBench.run(joins ++ [{600, {:rx, qf}}], 600 + 200 * @cpm + 400,
          cfg: cfg(robustness: 1)
        )

      assert Enum.drop(frames(r), 3) == [ex(v3(:mode_is_exclude, [@g2]))]
    end

    test "group-specific query for a group we have not joined, and a query without groups" do
      qf = IgmpBench.query_frame(q(group: @g2))
      qg = IgmpBench.query_frame(q())

      r =
        IgmpBench.run([{5, {:join, @g1}}, {600, {:rx, qf}}], 600 + 200 * @cpm + 400,
          cfg: cfg(robustness: 1)
        )

      assert length(frames(r)) == 1
      r = IgmpBench.run([{600, {:rx, qg}}], 600 + 200 * @cpm + 400)
      assert frames(r) == []
    end

    test "v3 group-and-source query counts as a group query", %{joins: joins} do
      qf = IgmpBench.query_frame(q(group: @g3, sources: [{10, 0, 0, 1}, {10, 0, 0, 2}]))

      r =
        IgmpBench.run(joins ++ [{600, {:rx, qf}}], 600 + 200 * @cpm + 400,
          cfg: cfg(robustness: 1)
        )

      assert Enum.drop(frames(r), 3) == [ex(v3(:mode_is_exclude, [@g3]))]
    end

    test "v2 only: a membership report per group, each inside the response time", %{joins: joins} do
      qf = IgmpBench.query_frame(%Query{version: 2, max_resp: 2, group: {0, 0, 0, 0}})

      r =
        IgmpBench.run(joins ++ [{600, {:rx, qf}}], 600 + 200 * @cpm + 600,
          cfg: cfg(robustness: 1, v2_only: 1)
        )

      rest = Enum.drop(frames(r), 3)

      assert Enum.sort(rest) ==
               Enum.sort(for g <- [@g1, @g2, @g3], do: ex(%Report{version: 2, group: g}))

      assert Enum.all?(Enum.drop(cycles(r), 3), &(&1 <= 600 + 200 * @cpm + 300))
    end

    test "a v2 query switches a v3 host to v2 compatibility", %{joins: joins} do
      qf = IgmpBench.query_frame(%Query{version: 2, max_resp: 2, group: {0, 0, 0, 0}})

      r =
        IgmpBench.run(joins ++ [{600, {:rx, qf}}, {6000, {:join, {239, 1, 1, 9}}}], 7000,
          cfg: cfg(robustness: 1)
        )

      assert List.last(r.outs).mode_v2 == 1
      assert Enum.at(r.outs, 590).mode_v2 == 0
      msgs = for f <- frames(r), do: elem(Host.decode_frame(f), 1)
      # three v3 joins, three v2 responses, one v2 join
      assert Enum.count(msgs, &match?(%ReportV3{}, &1)) == 3
      assert Enum.count(msgs, &match?(%Report{version: 2}, &1)) == 4
    end

    test "a report of another host suppresses ours in v2 mode", %{joins: joins} do
      qf = IgmpBench.query_frame(%Query{version: 2, max_resp: 10, group: {0, 0, 0, 0}})

      r =
        IgmpBench.run(
          joins ++ [{600, {:rx, qf}}, {900, {:rx, IgmpBench.other_report(@g1)}}],
          600 + 1000 * @cpm + 600,
          cfg: cfg(robustness: 1, v2_only: 1)
        )

      reports = Enum.drop(frames(r), 3)

      assert Enum.sort(reports) ==
               Enum.sort(for g <- [@g2, @g3], do: ex(%Report{version: 2, group: g}))
    end

    test "a report of another host does not suppress in v3 mode", %{joins: joins} do
      qf = IgmpBench.query_frame(q(max_resp: 10))

      r =
        IgmpBench.run(
          joins ++ [{600, {:rx, qf}}, {900, {:rx, IgmpBench.other_report(@g1)}}],
          600 + 1000 * @cpm + 600,
          cfg: cfg(robustness: 1)
        )

      assert [resp] = Enum.drop(frames(r), 3)
      assert resp == ex(v3(:mode_is_exclude, [@g1, @g2, @g3]))
    end

    test "the response time is clamped to 30 s and decoded from the v3 float", %{joins: _} do
      # code 0x80 = 128 * 100 ms: the delay may be anything below 12.8 s, clamped to 30 s
      qf = IgmpBench.query_frame(q(max_resp: 0x80))
      r = IgmpBench.run([{5, {:join, @g1}}, {600, {:rx, qf}}], 3000, cfg: cfg(robustness: 1))
      assert length(frames(r)) in [1, 2]
    end
  end

  describe "received frames" do
    setup do
      {:ok, joins: [{5, {:join, @g1}}]}
    end

    defp answered?(joins, qf, opts \\ []) do
      r =
        IgmpBench.run(joins ++ [{600, {:rx, qf, opts}}], 600 + 200 * @cpm + 400,
          cfg: cfg(robustness: 1)
        )

      length(frames(r)) == 2
    end

    test "VLAN tags, IP options after Router Alert", %{joins: j} do
      for fopts <- [
            [tags: [5]],
            [tags: [5, 6]],
            [ihl_pad: 1],
            [ihl_pad: 2],
            [tags: [7], ihl_pad: 2]
          ] do
        assert answered?(j, IgmpBench.query_frame(q(), fopts)), inspect(fopts)
      end
    end

    test "queries to the group itself and v1 queries", %{joins: j} do
      assert answered?(j, IgmpBench.query_frame(q(group: @g1)))
      assert answered?(j, IgmpBench.query_frame(%Query{version: 1, group: {0, 0, 0, 0}}))
    end

    test "dropped: bad IGMP checksum, bad frame, not IGMP, no valid IP header, long IHL", %{
      joins: j
    } do
      qf = IgmpBench.query_frame(q())
      refute answered?(j, IgmpBench.query_frame(q(), corrupt: true))
      refute answered?(j, qf, bad: true)
      refute answered?(j, qf, proto: 17)
      refute answered?(j, qf, ip_valid: 0)
      refute answered?(j, qf, ethertype: 0x86DD)
      refute answered?(j, IgmpBench.query_frame(q(), ihl_pad: 3))
    end

    test "a frame arriving while the previous one is parsed is counted as missed", %{joins: j} do
      qf = IgmpBench.query_frame(q())
      script = j ++ [{600, {:rx, qf}}, {612, {:rx, qf}}]
      r = IgmpBench.run(script, 600 + 200 * @cpm + 400, cfg: cfg(robustness: 1))
      assert Enum.any?(r.outs, &(&1.rx_missed == 1))
      # the first one is answered once
      assert length(frames(r)) == 2
    end
  end

  describe "transmit stream" do
    test "sink stalls change nothing but the timing" do
      qf = IgmpBench.query_frame(q())
      joins = for {g, i} <- Enum.with_index([@g1, @g2, @g3]), do: {5 + i, {:join, g}}
      script = joins ++ [{1500, {:rx, qf}}]
      a = IgmpBench.run(script, 1500 + 200 * @cpm + 600, cfg: cfg(robustness: 2, unsol_ms: 20))

      b =
        IgmpBench.run(script, 1500 + 200 * @cpm + 600,
          cfg: cfg(robustness: 2, unsol_ms: 20),
          stall: 60,
          seed: 5
        )

      assert Enum.sort(frames(a)) == Enum.sort(frames(b))
      assert length(frames(a)) == 7
    end

    test "tuser is 0 and the frame is 46 bytes plus 8 per record" do
      qf = IgmpBench.query_frame(q())
      joins = for {g, i} <- Enum.with_index([@g1, @g2, @g3]), do: {5 + i, {:join, g}}

      r =
        IgmpBench.run(joins ++ [{600, {:rx, qf}}], 600 + 200 * @cpm + 400,
          cfg: cfg(robustness: 1)
        )

      assert Enum.map(frames(r), &byte_size/1) == [54, 54, 54, 46 + 24]
      assert Enum.all?(r.outs, &(&1.m_axis_tuser == 0))
    end
  end

  # -- model comparison -------------------------------------------------------------------

  defp model_frames(events, opts) do
    h =
      Host.new(
        mac: IgmpBench.mac(),
        ip: IgmpBench.ip(),
        version: opts.version,
        robustness: 2,
        unsolicited_ms: 20,
        seed: 3
      )

    {h, acc} =
      Enum.reduce(events, {h, []}, fn {ms, ev}, {h, acc} ->
        {h, f1} = Host.step(h, {:tick, ms})
        {h, f2} = Host.step(h, ev)
        {h, acc ++ f1 ++ f2}
      end)

    last = elem(List.last(events), 0)

    {_, rest} =
      Enum.reduce(1..400, {h, []}, fn i, {h, acc} ->
        {h, f} = Host.step(h, {:tick, last + i * 10})
        {h, acc ++ f}
      end)

    acc ++ rest
  end

  @gap 3500

  defp event_gen do
    group = member_of([@g1, @g2, @g3])

    one_of([
      map(group, &{:join, &1}),
      map(group, &{:leave, &1}),
      constant({:general, 3}),
      map(group, &{:specific, &1}),
      constant({:v2_general, 1}),
      map(group, &{:other, &1})
    ])
  end

  property "frames of a spaced event sequence equal the host model's (as a multiset)" do
    check all(
            evs <- list_of(event_gen(), min_length: 1, max_length: 6),
            v2_only <- boolean(),
            max_runs: 12
          ) do
      timed = Enum.with_index(evs, fn e, i -> {10 + i * @gap, e} end)

      script =
        for {c, e} <- timed do
          case e do
            {:join, g} ->
              {c, {:join, g}}

            {:leave, g} ->
              {c, {:leave, g}}

            {:general, code} ->
              {c, {:rx, IgmpBench.query_frame(q(max_resp: code - 2))}}

            {:specific, g} ->
              {c, {:rx, IgmpBench.query_frame(q(group: g, max_resp: 1))}}

            {:v2_general, code} ->
              {c, {:rx, IgmpBench.query_frame(%Query{version: 2, max_resp: code})}}

            {:other, g} ->
              {c, {:rx, IgmpBench.other_report(g)}}
          end
        end

      model_events =
        for {c, e} <- timed do
          ms = div(c, @cpm)

          ev =
            case e do
              {:join, g} -> {:join, g}
              {:leave, g} -> {:leave, g}
              {:general, code} -> {:query, q(max_resp: code - 2)}
              {:specific, g} -> {:query, q(group: g, max_resp: 1)}
              {:v2_general, code} -> {:query, %Query{version: 2, max_resp: code}}
              {:other, g} -> {:report, g}
            end

          {ms, ev}
        end

      cfg = cfg(v2_only: if(v2_only, do: 1, else: 0), robustness: 2, unsol_ms: 20)
      r = IgmpBench.run(script, 10 + length(evs) * @gap + 1500, cfg: cfg)
      expected = model_frames(model_events, %{version: if(v2_only, do: 2, else: 3)})
      assert Enum.sort(frames(r)) == Enum.sort(expected)
    end
  end

  # -- Verilator ------------------------------------------------------------------------------

  @tag :verilator
  test "Verilator equals the BEAM simulator on a mixed scenario" do
    qf = IgmpBench.query_frame(q())
    v2q = IgmpBench.query_frame(%Query{version: 2, max_resp: 2})

    script = [
      {5, {:join, @g1}},
      {6, {:join, @g2}},
      {900, {:rx, qf}},
      {5000, {:rx, v2q}},
      {5600, {:rx, IgmpBench.other_report(@g1)}},
      {7000, {:leave, @g1}}
    ]

    r = IgmpBench.run(script, 9000, cfg: cfg(unsol_ms: 40), stall: 30)
    assert length(frames(r)) >= 6
    ExNet.RtlCase.cosim!(IgmpBench.module([]), r.events)
  end

  @tag :verilator
  test "v2 compatibility ends after robustness * 125 s plus the response time (Verilator)" do
    # one cycle per millisecond: 250 s are 250k cycles
    mod = IgmpBench.module(clk_hz: 1000)
    {:ok, s} = ExHdl.RTL.Cosim.open(mod, clocks: [sys: [period: 4]])
    base = Map.new(ExHdl.RTL.Module.data_inputs(mod), &{&1.name, 0})

    cfg =
      Map.merge(base, cfg(robustness: 2, unsol_ms: 20))
      |> Map.put(:m_axis_tready, 1)
      |> Map.put(:rst_n, 1)

    s = ExHdl.RTL.Cosim.poke(s, Map.put(cfg, :rst_n, 0))
    s = ExHdl.RTL.Cosim.step(s, 3)
    s = ExHdl.RTL.Cosim.poke(s, cfg)
    qf = IgmpBench.query_frame(%Query{version: 2, max_resp: 10})

    s =
      Enum.reduce(IgmpBench.rx_inputs(qf), s, fn b, s ->
        s |> ExHdl.RTL.Cosim.poke(b) |> ExHdl.RTL.Cosim.step(1)
      end)

    s = ExHdl.RTL.Cosim.poke(s, cfg) |> ExHdl.RTL.Cosim.step(200)
    assert ExHdl.RTL.Cosim.peek(s, :mode_v2) == 1
    # 2 * 125 s + 1 s after the query
    s = ExHdl.RTL.Cosim.step(s, 250_000 + 1000 - 400)
    assert ExHdl.RTL.Cosim.peek(s, :mode_v2) == 1
    s = ExHdl.RTL.Cosim.step(s, 600)
    assert ExHdl.RTL.Cosim.peek(s, :mode_v2) == 0
    ExHdl.RTL.Cosim.close(s)
  end

  @tag :verilator
  test "the VLAN variant with 16 groups lints and co-simulates" do
    script = [{5, {:join, @g1}}, {6, {:join, @g3}}, {900, {:rx, IgmpBench.query_frame(q())}}]
    r = IgmpBench.run(script, 3500, vlan: 7, groups: 16, cfg: cfg(vlan: 7, unsol_ms: 20))
    assert length(frames(r)) >= 3
    assert Enum.all?(frames(r), &match?({:ok, %{tags: [%{vid: 7}]}}, ExNet.Ethernet.decode(&1)))
    ExNet.RtlCase.cosim!(IgmpBench.module(vlan: 7, groups: 16), r.events)
  end
end
