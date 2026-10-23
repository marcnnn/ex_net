defmodule ExNet.RTL.DatapathTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  alias ExNet.MAC.Rx64
  alias ExNet.RTL.{RxPath, UdpTx}
  alias ExNet.{ClassifierGen, Filter, Frames, NetTops, RtlCase, UdpSource, XgmiiGen}

  @moduletag timeout: 600_000
  @n 4
  @sb 4

  defp keep_count(k), do: Enum.count(0..7, &((k >>> &1 &&& 1) == 1))

  # -- receive: XGMII -> MacRx -> Classifier -> UdpRx ----------------------------------------

  defp rx_events(filter, frames) do
    cfg =
      for {a, d} <- ClassifierGen.program(filter, @n, @sb),
          do: %{cfg_we: 1, cfg_addr: a, cfg_data: d}

    items =
      Enum.flat_map(frames, fn {f, bad, gap} ->
        [{:frame, XgmiiGen.wire(f, if(bad, do: :bad, else: :good)), 0}, {:idle, gap + 1}]
      end)

    words = XgmiiGen.words([{:idle, 2} | items] ++ [{:idle, 90}])

    cfg ++
      List.duplicate(%{}, 4) ++
      for {d, c} <- words, do: %{xgmii_rxd: d, xgmii_rxc: c}
  end

  defp collect_frames(outs, prefix) do
    p = fn k -> :"#{prefix}_#{k}" end

    {frames, _} =
      Enum.reduce(outs, {[], {<<>>, nil}}, fn o, {done, {cur, first}} ->
        if o[p.(:tvalid)] == 1 do
          cur =
            cur <> binary_part(<<o[p.(:tdata)]::little-size(64)>>, 0, keep_count(o[p.(:tkeep)]))

          first = first || o

          if o[p.(:tlast)] == 1,
            do: {[{cur, first, o} | done], {<<>>, nil}},
            else: {done, {cur, first}}
        else
          {done, {cur, first}}
        end
      end)

    Enum.reverse(frames)
  end

  defp rx_check(frames, filter, outs) do
    # the MAC flags runts as bad, which the classifier turns into a drop
    sent = for {f, bad, g} <- frames, do: {f, bad or byte_size(f) < 60, g}

    # all frames come out of the classified stream with their metadata
    got = collect_frames(outs, :frame)
    assert Enum.map(got, &elem(&1, 0)) == Enum.map(sent, &elem(&1, 0))

    for {{f, bad, _}, {_, first, last}} <- Enum.zip(sent, got) do
      exp = ClassifierGen.expected(filter, f, bad)

      want =
        Map.new(exp.pre, fn {k, v} ->
          {:"frame_#{String.slice(Atom.to_string(k), 2..-1//1)}", v}
        end)

      assert Map.take(first, Map.keys(want)) == want

      assert (last.frame_tuser &&& 1) == if(bad, do: 1, else: 0)
    end

    # the stream engine gets the payloads
    udp =
      for {payload, _first, last} <- collect_frames(outs, :m_axis),
          do: {last.m_axis_tuser, payload}

    assert udp == ClassifierGen.udp_packets(filter, sent)
    assert Enum.all?(outs, &(&1.ovf == 0 and &1.drop_full == 0 and &1.dbg == 0))
    {got, udp}
  end

  defp rx_filter do
    Filter.new(default: :host)
    |> Filter.add(%{ip_dst: {239, 69, 1, 1}, udp_dst_port: 5004}, {:stream, 1})
    |> Filter.add(%{udp_dst_port: 5005..5010}, {:stream, 2})
    |> Filter.add(%{ethertype: 0x0806}, :drop)
  end

  defp rx_frames do
    tagged =
      Frames.udp_frame(
        payload: :binary.copy("t", 90),
        tags: [%{tpid: 0x88A8, pcp: 0, dei: 0, vid: 7}, %{tpid: 0x8100, pcp: 3, dei: 0, vid: 9}]
      )

    [
      {Frames.udp_frame(payload: "first stream packet........"), false, 0},
      {tagged, false, 3},
      {Frames.udp_frame(payload: :binary.copy("o", 33), options: :binary.copy(<<1>>, 20)), false,
       0},
      {Frames.udp_frame(payload: "other port", dst_port: 9), false, 1},
      {Frames.udp_frame(payload: "bad fcs ...................."), true, 0},
      {Frames.udp_frame(payload: "range stream", dst_port: 5007), false, 2},
      {Frames.udp_frame(payload: :binary.copy("z", 400)), false, 0}
    ]
  end

  @tag timeout: 900_000
  test "RX: frames through MacRx, Classifier and UdpRx: stream, metadata and payloads" do
    frames = rx_frames()
    events = rx_events(rx_filter(), frames)
    mod = RxPath.build(entries: @n, stream_bits: @sb, depth: 256)
    outs = RtlCase.run(mod, Enum.map(events, &Map.put(&1, :m_axis_tready, 1)))
    {got, udp} = rx_check(frames, rx_filter(), outs)
    assert length(got) == length(frames)
    assert length(udp) == 4
  end

  @tag :verilator
  test "RX path: Verilator equals the BEAM simulator" do
    events =
      rx_events(rx_filter(), Enum.take(rx_frames(), 3))
      |> Enum.map(&Map.put(&1, :m_axis_tready, 1))

    RtlCase.cosim!(RxPath.build(entries: @n, stream_bits: @sb, depth: 256), events)
  end

  property "RX: random frames, VLAN tags, IP options, bad FCS" do
    check all(
            frames <-
              list_of(
                tuple({ClassifierGen.frame(), member_of([false, false, true]), integer(0..3)}),
                min_length: 1,
                max_length: 5
              ),
            filter <- ClassifierGen.filter(Enum.map(frames, &elem(&1, 0)), 4),
            max_runs: 4
          ) do
      frames = for {f, b, g} <- frames, byte_size(f) >= 14, do: {f, b, g}
      events = rx_events(filter, frames)
      mod = RxPath.build(entries: @n, stream_bits: @sb, depth: 256)
      outs = RtlCase.run(mod, Enum.map(events, &Map.put(&1, :m_axis_tready, 1)))
      rx_check(frames, filter, outs)
    end
  end

  # -- transmit: UdpTx -> FIFO -> merge -> MacTx -> XGMII -----------------------------------

  @cfg %{
    src_mac: <<2, 0, 0, 0, 0, 0x42>>,
    src_ip: {10, 1, 2, 3},
    uc_mac: <<0xA0, 1, 2, 3, 4, 5>>,
    ttl: 32,
    tos: 0xB8
  }

  defp tx_inputs(ports, tags) do
    base = %{
      src_mac: :binary.decode_unsigned(@cfg.src_mac),
      src_ip: ExNet.IPv4.ip_int(@cfg.src_ip),
      uc_mac: :binary.decode_unsigned(@cfg.uc_mac)
    }

    for {{port, tag}, i} <- Enum.with_index(Enum.zip(ports, tags)), reduce: base do
      acc ->
        Map.merge(acc, %{
          :"s#{i}_src_port" => port,
          :"s#{i}_ttl" => @cfg.ttl,
          :"s#{i}_tos" => @cfg.tos,
          :"s#{i}_tag" => tag
        })
    end
  end

  # runs the sources into the TX path; returns the XGMII words, per-cycle outputs
  defp tx_run(packets_per_source, ports, tags, seed, pause, ready_pct) do
    :rand.seed(:exsss, {seed, 1, 4})
    n_src = length(packets_per_source)
    srcs = Enum.map(packets_per_source, &UdpSource.new/1)
    total_beats = srcs |> Enum.map(&length(&1.q)) |> Enum.sum()
    cycles = total_beats * 8 + 400
    inputs0 = tx_inputs(ports, tags)

    {_, outs, acc} =
      RtlCase.drive(NetTops.tx_top(n_src), srcs, cycles, fn srcs, _ ->
        res =
          for {st, i} <- Enum.with_index(srcs), do: {i, UdpSource.offer(st, "s#{i}_axis", pause)}

        inputs = Enum.reduce(res, inputs0, fn {_, {m, _}}, a -> Map.merge(a, m) end)

        {inputs,
         fn o ->
           for {{i, {_, offer}}, st} <- Enum.zip(res, srcs),
               do: UdpSource.settle(st, offer, o[:"s#{i}_axis_tready"])
         end}
      end)

    _ = ready_pct
    {outs, acc}
  end

  defp tx_decode(outs) do
    words = for o <- outs, do: {o.xgmii_txd, o.xgmii_txc}
    Rx64.frames(words)
  end

  defp pad60(f) when byte_size(f) < 60, do: f <> :binary.copy(<<0>>, 60 - byte_size(f))
  defp pad60(f), do: f

  defp tx_payloads do
    for len <- [1, 6, 7, 8, 9, 47, 100, 313],
        do: :binary.list_to_bin(for i <- 1..len, do: rem(i * 7 + len, 250) + 1)
  end

  test "TX: two UDP sources through UdpTx, packet FIFOs, merge and MacTx decode back to the models" do
    pl = tx_payloads()

    s0 = for {p, i} <- Enum.with_index(Enum.take(pl, 5)), do: {p, {{239, 69, 1, 1 + i}, 5004}}

    s1 =
      for {p, i} <- Enum.with_index(Enum.drop(pl, 3)),
          do: {p, {{224, 0, 1, 129}, 319 + rem(i, 2)}}

    ports = [1000, 2000]
    tags = [0x11, 0x22]
    {outs, srcs} = tx_run([s0, s1], ports, tags, 5, 25, 100)
    assert Enum.all?(srcs, &UdpSource.done?/1)
    frames = tx_decode(outs)

    assert Enum.all?(frames, fn {st, _} -> st == :ok end)
    assert length(frames) == length(s0) + length(s1)
    assert Enum.all?(outs, &(&1.drop == 0))

    # the order between sources is up to the arbiter, within a source it is fixed
    decoded =
      for {_, bytes} <- frames do
        {:ok, eth} = ExNet.Ethernet.decode(bytes)
        {:ok, ip} = ExNet.IPv4.decode(eth.payload)
        {:ok, udp} = ExNet.UDP.decode(ip.payload)
        {udp.src_port, bytes}
      end

    for {{port, pk}, i} <- [{{1000, s0}, 0}, {{2000, s1}, 1}] do
      cfg = Map.put(@cfg, :src_port, port)

      expect =
        for {{payload, dest}, id} <- Enum.with_index(pk),
            do: pad60(UdpTx.model(payload, dest, cfg, id))

      got = for {^port, b} <- decoded, do: b
      assert got == expect, "source #{i}"
    end

    # tx_sof once per frame, the tag of the frame's source is valid in that cycle
    sofs = for o <- outs, o.tx_sof == 1, do: o.tx_tag
    assert length(sofs) == length(frames)

    assert Enum.sort(sofs) ==
             Enum.sort(List.duplicate(0x11, length(s0)) ++ List.duplicate(0x22, length(s1)))

    # a frame is an unbroken burst of words on the wire (no underrun: all `:ok` above, and
    # no /E/ in the stream)
    refute Enum.any?(outs, fn o -> o.xgmii_txd == 0xFEFEFEFEFEFEFEFE and o.xgmii_txc == 0xFF end)
  end

  @tag :verilator
  test "TX path: Verilator equals the BEAM simulator" do
    s0 = [{"abcdefghij", {{239, 69, 1, 1}, 5004}}, {"klmnopq", {{239, 69, 1, 2}, 5004}}]
    s1 = [{:binary.copy("p", 50), {{224, 0, 1, 129}, 319}}]
    srcs = [UdpSource.new(s0), UdpSource.new(s1)]
    :rand.seed(:exsss, {1, 2, 3})
    inputs0 = tx_inputs([1000, 2000], [1, 2])

    {events, _, _} =
      RtlCase.drive(NetTops.tx_top(2), srcs, 220, fn srcs, _ ->
        res = for {st, i} <- Enum.with_index(srcs), do: {i, UdpSource.offer(st, "s#{i}_axis", 20)}
        inputs = Enum.reduce(res, inputs0, fn {_, {m, _}}, a -> Map.merge(a, m) end)

        {inputs,
         fn o ->
           for {{i, {_, offer}}, st} <- Enum.zip(res, srcs),
               do: UdpSource.settle(st, offer, o[:"s#{i}_axis_tready"])
         end}
      end)

    RtlCase.cosim!(NetTops.tx_top(2), events)
  end
end
