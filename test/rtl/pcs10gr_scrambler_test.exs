defmodule ExNet.RTL.PCS10GRScramblerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise
  alias ExNet.PCS.Scrambler, as: Model
  alias ExNet.RTL.Scrambler, as: Hw
  alias ExNet.RtlCase

  defp cycles do
    word = StreamData.integer(0..0xFFFFFFFFFFFFFFFF)
    special = StreamData.member_of([0, 0xFFFFFFFFFFFFFFFF, 1, 0x8000000000000000])
    cyc = StreamData.tuple({StreamData.one_of([word, word, special]), StreamData.boolean()})
    StreamData.list_of(cyc, min_length: 5, max_length: 100)
  end

  defp events(cs), do: for({d, en} <- cs, do: %{data: d, en: if(en, do: 1, else: 0)})

  defp expected(mode, seed, cs) do
    f = fn s, w -> apply(Model, mode, [s, w]) end

    {rev, _} =
      Enum.reduce(cs, {[], seed}, fn {d, en}, {acc, s} ->
        {s1, o} = f.(s, d)
        {[%{out: o} | acc], if(en, do: s1, else: s)}
      end)

    Enum.reverse(rev)
  end

  for {mode, seed} <- [scramble: Model.seed(), descramble: 0] do
    @mode mode
    @seed seed
    test "#{mode} matches the model cycle by cycle (random enables)" do
      mod = Hw.build(@mode)

      check all(cs <- cycles(), max_runs: 30) do
        assert RtlCase.run(mod, events(cs)) == expected(@mode, @seed, cs)
      end
    end

    test "#{mode} unit vectors" do
      mod = Hw.build(@mode)
      cs = for i <- 0..63, do: {1 <<< i, false}
      assert RtlCase.run(mod, events(cs)) == expected(@mode, @seed, cs)
      cs = for i <- 0..63, do: {1 <<< i, true}
      assert RtlCase.run(mod, events(cs)) == expected(@mode, @seed, cs)
    end

    @tag :verilator
    test "#{mode} co-simulates" do
      [cs] = Enum.take(StreamData.resize(cycles(), 100), 1)
      RtlCase.cosim!(Hw.build(@mode), events(cs ++ Enum.map(cs, fn {d, _} -> {d, true} end)))
    end
  end

  test "hardware descrambler recovers scrambler output after 58 bits (loopback)" do
    words = for i <- 1..30, do: i * 0x9E3779B97F4A7C15 &&& 0xFFFFFFFFFFFFFFFF
    scr = RtlCase.run(Hw.build(:scramble), for(w <- words, do: %{data: w, en: 1}))
    dsc = RtlCase.run(Hw.build(:descramble), for(%{out: o} <- scr, do: %{data: o, en: 1}))
    assert Enum.drop(Enum.map(dsc, & &1.out), 1) == Enum.drop(words, 1)
  end
end
