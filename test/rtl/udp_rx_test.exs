defmodule ExNet.RTL.UdpRxTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  alias ExNet.{ClassifierGen, Filter, Frames, RtlCase}
  alias ExNet.RTL.UdpRx

  @moduletag timeout: 300_000

  doctest ExNet.RTL.Ifc

  defp mod, do: UdpRx.build(depth: 64)

  # Frames as the classifier presents them: beats with the metadata the classifier model
  # predicts (every frame is a stream hit unless its FCS is bad).
  defp scenario(frames, filter) do
    for {frame, bad, gap} <- frames do
      exp = ClassifierGen.expected(filter, frame, bad)
      beats = ClassifierGen.beats(frame, bad)
      last = length(beats) - 1

      evs =
        for {b, i} <- Enum.with_index(beats) do
          meta = if i == last, do: exp.final, else: exp.pre

          base =
            for {k, v} <- Map.merge(b, meta), into: %{} do
              {rename(k), v}
            end

          Map.put(base, :s_sof, if(i == 0, do: 1, else: 0))
        end

      evs ++ List.duplicate(%{}, max(gap, 4 - length(beats)))
    end
    |> List.flatten()
  end

  defp rename(k) do
    case Atom.to_string(k) do
      "m_" <> r -> String.to_atom("s_" <> r)
      _ -> k
    end
  end

  defp expected(frames, filter), do: ClassifierGen.udp_packets(filter, frames)

  # runs `events` with the sink ready according to `ready` (cycle -> 0 | 1); returns packets
  defp run(events, ready, tail) do
    n = length(events) + tail
    ev = List.to_tuple(events)

    {inputs, outs, acc} =
      RtlCase.drive(mod(), %{cur: <<>>, user: nil, pk: []}, n, fn acc, i ->
        e = if i < tuple_size(ev), do: elem(ev, i), else: %{}
        r = ready.(i)

        {Map.put(e, :m_axis_tready, r),
         fn o ->
           if o.m_axis_tvalid == 1 and r == 1 do
             d = <<o.m_axis_tdata::little-size(64)>>
             n = Enum.count(0..7, &((o.m_axis_tkeep >>> &1 &&& 1) == 1))
             cur = acc.cur <> binary_part(d, 0, n)

             if o.m_axis_tlast == 1,
               do: %{cur: <<>>, user: nil, pk: [{o.m_axis_tuser, cur} | acc.pk]},
               else: %{acc | cur: cur}
           else
             acc
           end
         end}
      end)

    {inputs, outs, Enum.reverse(acc.pk)}
  end

  defp filter, do: Filter.new(default: {:stream, 1})

  defp plan do
    gen all(
          frames <- list_of(ClassifierGen.frame(), min_length: 1, max_length: 6),
          bads <- list_of(member_of([false, false, false, true]), length: length(frames)),
          gaps <- list_of(integer(0..5), length: length(frames))
        ) do
      Enum.zip([frames, bads, gaps]) |> Enum.map(fn {f, b, g} -> {f, b, g} end)
    end
  end

  property "payloads of stream frames come out whole, aligned, with the metadata; bad frames never" do
    check all(frames <- plan(), max_runs: 12) do
      {_, outs, pk} = run(scenario(frames, filter()), fn _ -> 1 end, 80)
      assert pk == expected(frames, filter())
      assert Enum.all?(outs, &(&1.dbg == 0))
    end
  end

  property "random sink stalls change nothing" do
    check all(frames <- plan(), seed <- integer(1..1000), max_runs: 6) do
      :rand.seed(:exsss, {seed, 1, 1})
      stalls = for _ <- 1..4000, do: if(:rand.uniform(3) == 1, do: 0, else: 1)
      st = List.to_tuple(stalls)
      {_, _, pk} = run(scenario(frames, filter()), &elem(st, rem(&1, 4000)), 400)
      assert pk == expected(frames, filter())
    end
  end

  describe "directed" do
    test "every payload length and lane offset, VLAN tags, IP options, padding" do
      frames =
        for {len, opt, tags} <- [
              {1, 0, 0},
              {5, 4, 1},
              {6, 0, 2},
              {7, 8, 0},
              {8, 0, 1},
              {9, 12, 2},
              {16, 0, 0},
              {17, 20, 1},
              {47, 0, 2},
              {100, 36, 0}
            ] do
          tags =
            [%{tpid: 0x88A8, pcp: 0, dei: 0, vid: 7}, %{tpid: 0x8100, pcp: 0, dei: 0, vid: 8}]
            |> Enum.take(tags)

          payload = :binary.list_to_bin(for i <- 1..len, do: rem(i * 37 + len, 251) + 1)
          f = Frames.udp_frame(payload: payload, tags: tags, options: :binary.copy(<<1>>, opt))
          {f, false, 0}
        end

      {_, _, pk} = run(scenario(frames, filter()), fn _ -> 1 end, 60)
      assert length(pk) == 10
      assert pk == expected(frames, filter())
    end

    test "FCS error, empty payload, host frames, fragment: nothing leaves" do
      ok = Frames.udp_frame(payload: "abcdefghijkl")
      empty = Frames.udp_frame(payload: "")
      frag = Frames.udp_frame(payload: "abcdefghijkl", mf: true)
      frames = [{ok, true, 0}, {empty, false, 0}, {frag, false, 0}, {ok, false, 0}]
      {_, _, pk} = run(scenario(frames, filter()), fn _ -> 1 end, 60)
      assert [{_, "abcdefghijkl"}] = pk
      assert pk == expected(frames, filter())
    end

    test "UDP checksum: a bad one drops the packet, zero means none" do
      ok = Frames.udp_frame(payload: "checksummed payload")
      <<h::binary-size(42), c, rest::binary>> = ok
      corrupt = <<h::binary, Bitwise.bxor(c, 0x40), rest::binary>>
      <<h0::binary-size(40), _::16, rest0::binary>> = corrupt
      none = <<h0::binary, 0::16, rest0::binary>>
      odd = Frames.udp_frame(payload: "odd")
      frames = [{corrupt, false, 0}, {none, false, 0}, {ok, false, 0}, {odd, false, 0}]
      {_, outs, pk} = run(scenario(frames, filter()), fn _ -> 1 end, 60)
      assert Enum.map(pk, &elem(&1, 1)) == ["#hecksummed payload", "checksummed payload", "odd"]
      assert Enum.any?(outs, &(&1.drop_bad == 1))
      assert pk == expected(frames, filter())
    end

    test "FIFO overflow drops whole packets and keeps the next ones intact" do
      big = Frames.udp_frame(payload: :binary.copy(<<0xAB>>, 400))
      small = Frames.udp_frame(payload: "tiny packet bytes")
      frames = [{big, false, 0}, {big, false, 0}, {small, false, 0}]
      # sink stalled long enough for the 64 beat FIFO to fill
      {_, outs, pk} = run(scenario(frames, filter()), fn i -> if i < 150, do: 0, else: 1 end, 300)
      assert Enum.any?(outs, &(&1.drop_full == 1))
      # every packet that comes out is one of the sent ones, complete
      sent = expected(frames, filter())
      assert pk != [] and Enum.all?(pk, &(&1 in sent))
    end
  end

  @tag :verilator
  property "Verilator equals the BEAM simulator" do
    check all(frames <- plan(), max_runs: 4) do
      {inputs, _, _} =
        run(scenario(frames, filter()), fn i -> if rem(i, 7) == 3, do: 0, else: 1 end, 120)

      RtlCase.cosim!(mod(), inputs)
    end
  end
end
