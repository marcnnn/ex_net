defmodule ExNet.RTL.CRC32Test do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise
  alias ExNet.CRC32
  alias ExNet.RTL.CRC32, as: Hw
  alias ExNet.RtlCase

  # one random cycle: {data, nbytes, valid, init}
  defp cycles(bytes) do
    gen =
      StreamData.tuple({
        StreamData.integer(0..((1 <<< (8 * bytes)) - 1)),
        StreamData.integer(1..bytes),
        StreamData.boolean(),
        StreamData.boolean()
      })

    StreamData.list_of(gen, min_length: 5, max_length: 80)
  end

  defp events(cycles, bytes) do
    for {d, n, v, i} <- cycles do
      keep = (1 <<< n) - 1
      base = %{data: d, valid: b(v), init: b(i)}
      if bytes > 1, do: Map.put(base, :keep, keep), else: base
    end
  end

  defp b(true), do: 1
  defp b(false), do: 0

  # model: the register after each cycle, as the outputs show it one cycle later
  defp expected(cycles) do
    {rev, _} =
      Enum.reduce(cycles, {[], CRC32.init()}, fn {d, n, v, i}, {acc, s} ->
        out = %{state: s, crc: CRC32.final(s), ok: b(s == CRC32.residue())}
        s0 = if i, do: CRC32.init(), else: s
        s1 = if v, do: CRC32.step_word(s0, d &&& (1 <<< (8 * n)) - 1, n), else: s0
        {[out | acc], s1}
      end)

    Enum.reverse(rev)
  end

  for bytes <- [1, 8] do
    describe "#{8 * bytes}-bit" do
      @bytes bytes
      test "matches the model cycle by cycle" do
        mod = Hw.build(@bytes)

        check all(cs <- cycles(@bytes), max_runs: 25) do
          assert RtlCase.run(mod, events(cs, @bytes)) == expected(cs)
        end
      end

      test "frame with FCS gives the residue" do
        mod = Hw.build(@bytes)
        frame = for i <- 1..61, into: <<>>, do: <<rem(i * 37, 256)>>
        wire = frame <> CRC32.fcs(frame)

        evs =
          wire
          |> :binary.bin_to_list()
          |> Enum.chunk_every(@bytes)
          |> Enum.with_index()
          |> Enum.map(fn {ch, i} ->
            n = length(ch)
            d = ch |> Enum.with_index() |> Enum.reduce(0, fn {x, k}, a -> a ||| x <<< (8 * k) end)
            ev = %{data: d, valid: 1, init: b(i == 0)}
            if @bytes > 1, do: Map.put(ev, :keep, (1 <<< n) - 1), else: ev
          end)

        out = RtlCase.run(mod, evs ++ [%{}]) |> List.last()
        assert out.ok == 1
        assert out.state == CRC32.residue()
        assert CRC32.final(out.state) == CRC32.final(CRC32.residue())
      end

      @tag :verilator
      test "co-simulates" do
        mod = Hw.build(@bytes)
        [cs] = Enum.take(StreamData.resize(cycles(@bytes), 80), 1)
        RtlCase.cosim!(mod, events(cs, @bytes))
      end
    end
  end
end
