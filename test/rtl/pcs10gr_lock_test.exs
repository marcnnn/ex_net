defmodule ExNet.RTL.PCS10GRLockTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExNet.PCS.BlockLock, as: Model
  alias ExNet.RTL.BlockLock, as: Hw
  alias ExNet.RtlCase

  # header runs: valid runs (some long), invalid bursts, mixed noise, unlocked slips
  defp segment do
    StreamData.one_of([
      StreamData.bind(StreamData.integer(1..200), &run(&1, [1, 2])),
      StreamData.bind(StreamData.integer(1..40), &run(&1, [0, 3])),
      StreamData.bind(StreamData.integer(1..140), &run(&1, [1, 2, 1, 2, 1, 2, 0, 3])),
      StreamData.bind(StreamData.integer(60..70), &run(&1, [1, 2])),
      StreamData.bind(StreamData.integer(1..20), &run(&1, [1, 2, 1, 2, 1, 2, 1, 2, 0]))
    ])
  end

  defp run(n, pool), do: StreamData.list_of(StreamData.member_of(pool), length: n)

  defp headers do
    StreamData.map(StreamData.list_of(segment(), min_length: 1, max_length: 8), &Enum.concat/1)
  end

  defp events(cs), do: for({h, v} <- cs, do: %{sh: h, valid: v})

  defp expected(cs) do
    {rev, _} =
      Enum.reduce(cs, {[], Model.new()}, fn {sh, v}, {acc, s} ->
        if v,
          do:
            (
              {s1, o} = Model.step(s, sh)
              {[b(o) | acc], s1}
            ),
          else: {[%{lock: b(s.lock), slip: 0} | acc], s}
      end)

    Enum.reverse(rev)
  end

  defp b(%{lock: l, slip: s}), do: %{lock: b(l), slip: b(s)}
  defp b(true), do: 1
  defp b(false), do: 0

  test "matches the model, always valid" do
    mod = Hw.build()

    check all(hs <- headers(), max_runs: 40) do
      cs = Enum.map(hs, &{&1, true})

      assert RtlCase.run(mod, for(h <- hs, do: %{sh: h, valid: 1})) ==
               expected(cs)
    end
  end

  test "matches the model with random valid gaps" do
    mod = Hw.build()

    check all(
            hs <- headers(),
            gaps <-
              StreamData.list_of(StreamData.member_of([true, true, true, false]),
                length: length(hs)
              ),
            max_runs: 30
          ) do
      cs = Enum.zip(hs, gaps)
      assert RtlCase.run(mod, events(cs)) == expected(cs)
    end
  end

  test "locks after 64 valid headers, loses lock after 16 invalid in a window" do
    mod = Hw.build()
    hs = List.duplicate(1, 70) ++ List.duplicate(0, 16) ++ List.duplicate(2, 3) ++ [3]
    out = RtlCase.run(mod, for(h <- hs, do: %{sh: h, valid: 1}))
    assert Enum.map(out, & &1.lock) |> Enum.find_index(&(&1 == 1)) == 63
    assert Enum.at(out, 85).lock == 0 and Enum.at(out, 85).slip == 1
    assert Enum.at(out, 69).slip == 0
    assert Enum.at(out, 70).slip == 0 and Enum.at(out, 70).lock == 1
    assert out == expected(Enum.map(hs, &{&1, true}))
  end

  test "slip while unlocked on every invalid header" do
    mod = Hw.build()
    hs = [1, 3, 0, 2, 3]
    out = RtlCase.run(mod, for(h <- hs, do: %{sh: h, valid: 1}))
    assert Enum.map(out, & &1.slip) == [0, 1, 1, 0, 1]
  end

  @tag :verilator
  test "co-simulates" do
    [hs] = Enum.take(StreamData.resize(headers(), 100), 1)
    hs = Enum.take(hs ++ List.duplicate(1, 70) ++ List.duplicate(0, 20) ++ Enum.take(hs, 50), 400)

    [gaps] =
      Enum.take(
        StreamData.list_of(StreamData.member_of([true, true, false]), length: length(hs)),
        1
      )

    RtlCase.cosim!(Hw.build(), events(Enum.zip(hs, gaps)))
  end
end
