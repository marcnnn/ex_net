defmodule ExNet.RTL.ClassifierTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag timeout: 300_000

  alias ExNet.{ClassifierGen, Ethernet, Filter, Frames, RtlCase}
  alias ExNet.RTL.Classifier

  @n 16
  @sb 4
  @delay Classifier.delay()

  defp mod, do: Classifier.build(entries: @n, stream_bits: @sb, slots: 4)

  # runs the scenario and checks every output cycle against the models
  defp run_check(filter, frames) do
    {events, starts} = ClassifierGen.stimulus(filter, frames, @n, @sb)
    outs = RtlCase.run(mod(), events)
    verify(filter, frames, starts, events, outs)
    {events, outs}
  end

  defp verify(filter, frames, starts, events, outs) do
    in_valid = Enum.map(events, &Map.get(&1, :s_tvalid, 0))
    out_valid = Enum.map(outs, & &1.m_tvalid)
    assert out_valid == List.duplicate(0, @delay) ++ Enum.drop(in_valid, -@delay)
    assert Enum.all?(outs, &(&1.ovf == 0))

    for {{frame, bad, _}, start} <- Enum.zip(frames, starts) do
      beats = ClassifierGen.beats(frame, bad)
      exp = ClassifierGen.expected(filter, frame, bad)
      last = length(beats) - 1

      for {beat, i} <- Enum.with_index(beats) do
        o = Enum.at(outs, start + i + @delay)
        assert o.m_tdata == beat.s_tdata
        assert o.m_tkeep == beat.s_tkeep
        assert o.m_tlast == beat.s_tlast
        assert o.m_tuser == beat.s_tuser
        assert o.m_sof == if(i == 0, do: 1, else: 0)
        want = if i == last, do: exp.final, else: exp.pre

        assert Map.take(o, Map.keys(want)) == want,
               "frame #{inspect(frame, base: :hex)} beat #{i}"
      end
    end
  end

  defp scenario do
    StreamData.bind(
      StreamData.list_of(ClassifierGen.frame(), min_length: 2, max_length: 6),
      fn frames ->
        StreamData.tuple({
          StreamData.constant(frames),
          ClassifierGen.filter(frames),
          StreamData.list_of(StreamData.tuple({boolean_bad(), StreamData.integer(0..3)}),
            length: length(frames)
          )
        })
      end
    )
  end

  defp boolean_bad, do: StreamData.member_of([false, false, false, true])

  property "verdict, metadata and pass-through match the models on random frames" do
    check all {frames, filter, extra} <- scenario(), max_runs: 15 do
      run_check(filter, for({f, {bad, gap}} <- Enum.zip(frames, extra), do: {f, bad, gap}))
    end
  end

  describe "directed" do
    defp doc_filter do
      Filter.new(default: :drop)
      |> Filter.add(%{ip_dst: {239, 69, 1, 1}, udp_dst_port: 5004}, {:stream, 3})
      |> Filter.add(%{ethertype: 0x0806}, :host)
    end

    test "stream hit, host, default, fragment, bad checksum, FCS error" do
      udp = Frames.udp_frame()

      tagged =
        Frames.udp_frame(
          tags: [
            %{tpid: 0x88A8, pcp: 0, dei: 0, vid: 77},
            %{tpid: 0x8100, pcp: 1, dei: 0, vid: 5}
          ]
        )

      opts = Frames.udp_frame(options: :binary.copy(<<1>>, 40), dst_port: 5004)
      frag = Frames.udp_frame(mf: true)
      other = Frames.udp_frame(dst_port: 9)

      arp =
        Ethernet.encode(%Ethernet{
          dst: Ethernet.broadcast(),
          src: <<2, 0, 0, 0, 0, 1>>,
          ethertype: 0x0806,
          payload: :binary.copy(<<0>>, 46)
        })

      <<h::binary-size(24), c, t::binary>> = udp
      badsum = <<h::binary, Bitwise.bxor(c, 1), t::binary>>

      frames = [
        {udp, false, 0},
        {tagged, false, 0},
        {opts, false, 1},
        {frag, false, 0},
        {other, false, 0},
        {arp, false, 0},
        {badsum, false, 0},
        {udp, true, 0}
      ]

      {_, outs} = run_check(doc_filter(), frames)

      kinds =
        outs
        |> Enum.filter(&(&1.m_tvalid == 1 and &1.m_tlast == 1))
        |> Enum.map(&{&1.m_kind, &1.m_stream})

      assert kinds == [{2, 3}, {2, 3}, {2, 3}, {0, 0}, {0, 0}, {1, 0}, {0, 0}, {0, 0}]
    end

    test "payload offset and fields of a tagged UDP frame with options" do
      f =
        Frames.udp_frame(
          tags: [%{tpid: 0x8100, pcp: 0, dei: 0, vid: 9}],
          options: <<0::64>>,
          src_port: 111,
          dst_port: 222
        )

      {_, outs} = run_check(Filter.new(default: :host), [{f, false, 0}])
      o = Enum.find(outs, &(&1.m_tvalid == 1))
      assert o.m_payload_offset == 14 + 4 + 28 + 8
      assert {o.m_src_port, o.m_dst_port, o.m_vlan_id, o.m_ntags, o.m_kind} == {111, 222, 9, 1, 1}
      assert o.m_src_ip == 0x0A000001
    end

    test "back-to-back frames at the minimum period, lowest index wins" do
      f = Filter.new(default: :drop)

      f =
        f
        |> Filter.add(%{udp_dst_port: 5000..5010}, {:stream, 1})
        |> Filter.add(%{udp_dst_port: 5004}, {:stream, 2})

      frames =
        for p <- [5004, 6000, 5001, 5004],
            do: {Frames.udp_frame(dst_port: p, payload: ""), false, 0}

      run_check(f, frames)
    end

    test "dst_mac mask and multicast flag" do
      f =
        Filter.new(default: :drop)
        |> Filter.add(
          %{dst_mac: {<<1, 0, 0x5E, 0, 0, 0>>, <<255, 255, 255, 0, 0, 0>>}, multicast: true},
          :host
        )
        |> Filter.add(%{multicast: false}, {:stream, 7})

      frames = [
        {Frames.udp_frame(), false, 0},
        {Frames.udp_frame(dst_mac: <<2, 3, 4, 5, 6, 7>>), false, 0},
        {Frames.udp_frame(dst_mac: <<1, 0, 0x5F, 5, 6, 7>>), false, 0}
      ]

      run_check(f, frames)
    end

    test "frames longer than the window with a total length beyond the frame are accepted (deviation)" do
      frame = Frames.udp_frame(payload: :binary.copy(<<7>>, 100))
      cut = binary_part(frame, 0, 110)
      assert %{ip_dst: _, udp_dst_port: nil} = Filter.key(cut)
      f = Filter.new(default: :drop) |> Filter.add(%{udp_dst_port: 5004}, {:stream, 1})
      {events, starts} = ClassifierGen.stimulus(f, [{cut, false, 0}], @n, @sb)
      outs = RtlCase.run(mod(), events)
      o = Enum.at(outs, hd(starts) + @delay)
      assert {o.m_payload_valid, o.m_dst_port, o.m_kind} == {1, 5004, 2}
    end

    test "table can be reprogrammed and the default written" do
      f1 = Filter.new(default: {:stream, 5})
      {ev, st} = ClassifierGen.stimulus(f1, [{Frames.udp_frame(), false, 0}], @n, @sb)
      outs = RtlCase.run(mod(), ev)
      o = Enum.at(outs, hd(st) + @delay)
      assert {o.m_kind, o.m_stream, o.m_hit} == {2, 5, 0}
    end
  end

  @tag :verilator
  test "co-simulates against Verilator" do
    f = Frames.udp_frame()

    tagged =
      Frames.udp_frame(
        tags: [%{tpid: 0x8100, pcp: 0, dei: 0, vid: 9}],
        options: <<0::64>>,
        dst_port: 6000
      )

    cut = binary_part(f, 0, 30)
    filter = doc_filter() |> Filter.add(%{vlan: 9}, :host)

    frames = [
      {f, false, 0},
      {tagged, false, 2},
      {cut, false, 0},
      {f, true, 0},
      {tagged, false, 0}
    ]

    {events, starts} = ClassifierGen.stimulus(filter, frames, @n, @sb, 20)
    outs = RtlCase.run(mod(), events)
    verify(filter, frames, starts, events, outs)
    RtlCase.cosim!(mod(), events)
  end
end
