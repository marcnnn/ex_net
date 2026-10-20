defmodule ExNet.RTL.PCS10GRBlock66Test do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise
  alias ExNet.PCS.Block66
  alias ExNet.RTL.Block66, as: Hw
  alias ExNet.RtlCase

  @specials [0x07, 0x06, 0xFE, 0xFB, 0xFD, 0x9C, 0x5C, 0x00, 0x1E]

  defp lane_gen(:d), do: StreamData.map(StreamData.integer(0..255), &{&1, 0})
  defp lane_gen(:s), do: StreamData.constant({0xFB, 1})
  defp lane_gen(:t), do: StreamData.constant({0xFD, 1})
  defp lane_gen(:o), do: StreamData.member_of([{0x9C, 1}, {0x5C, 1}])

  defp lane_gen(:c),
    do:
      StreamData.map(
        StreamData.one_of([StreamData.member_of([0x07, 0x06, 0xFE]), StreamData.integer(0..255)]),
        &{&1, 1}
      )

  defp pack(lanes) do
    lanes
    |> Enum.with_index()
    |> Enum.reduce({0, 0}, fn {{b, c}, i}, {d, k} -> {d ||| b <<< (8 * i), k ||| c <<< i} end)
  end

  defp structured do
    StreamData.bind(StreamData.member_of(Enum.map(Hw.patterns(), &elem(&1, 1))), fn pat ->
      pat |> Enum.map(&lane_gen/1) |> StreamData.fixed_list() |> StreamData.map(&pack/1)
    end)
  end

  defp mutated do
    StreamData.bind(structured(), fn {d, k} ->
      StreamData.bind(StreamData.integer(0..7), fn i ->
        byte = StreamData.one_of([StreamData.member_of(@specials), StreamData.integer(0..255)])

        StreamData.map(StreamData.tuple({byte, StreamData.integer(0..1)}), fn {b, c} ->
          {(d &&& ~~~(0xFF <<< (8 * i))) ||| b <<< (8 * i), (k &&& ~~~(1 <<< i)) ||| c <<< i}
        end)
      end)
    end)
  end

  defp random_word,
    do: StreamData.tuple({StreamData.integer(0..0xFFFFFFFFFFFFFFFF), StreamData.integer(0..255)})

  defp words,
    do:
      StreamData.list_of(
        StreamData.frequency([{5, structured()}, {3, mutated()}, {1, random_word()}]),
        min_length: 10,
        max_length: 120
      )

  defp enc_events(ws), do: for({d, c} <- ws, do: %{data: d, ctl: c})

  defp enc_expected(ws) do
    for w <- ws do
      {h, p} = Block66.encode(w)
      %{hdr: h, payload: p}
    end
  end

  test "encoder matches the model on structured, mutated and random words" do
    mod = Hw.encoder(clocked: true)

    check all(ws <- words(), max_runs: 40) do
      assert RtlCase.run(mod, enc_events(ws)) == enc_expected(ws)
    end
  end

  test "encoder, every pattern with every control character variant" do
    mod = Hw.encoder(clocked: true)

    ws =
      for {_, pat} <- Hw.patterns(),
          c <- [0x07, 0x06, 0xFE, 0x55, 0x9C, 0xFB],
          o <- [0x9C, 0x5C] do
        pat
        |> Enum.map(fn
          :d -> {0xA5, 0}
          :s -> {0xFB, 1}
          :t -> {0xFD, 1}
          :o -> {o, 1}
          :c -> {c, 1}
        end)
        |> pack()
      end

    assert RtlCase.run(mod, enc_events(ws)) == enc_expected(ws)
  end

  test "encoder, all lane-kind combinations of the four lanes 0, 1, 4, 5 (others idle)" do
    mod = Hw.encoder(clocked: true)
    kinds = [{0x11, 0}, {0xFB, 1}, {0xFD, 1}, {0x9C, 1}, {0x07, 1}]

    ws =
      for a <- kinds, b <- kinds, c <- kinds, d <- kinds, e <- kinds do
        pack([a, b, {0x07, 1}, e, c, d, {0x07, 1}, {0x07, 1}])
      end

    assert RtlCase.run(mod, enc_events(ws)) == enc_expected(ws)
  end

  test "decoder matches the model, exhaustive over header and block type" do
    mod = Hw.decoder(clocked: true)

    blocks =
      for hdr <- 0..3, type <- 0..255, nib <- [0x0, 0xF, 0x3], c <- [0, 6, 0x55] do
        base = 0x0123456789ABCDEF &&& ~~~0xFF
        base = (base &&& ~~~(0xFF <<< 32)) ||| (nib ||| nib <<< 4) <<< 32
        base = base ||| c <<< 8 ||| c <<< 15 ||| c <<< 36 ||| c <<< 43
        {hdr, base ||| type}
      end

    evs = for {h, p} <- blocks, do: %{hdr: h, payload: p}

    exp =
      for b <- blocks do
        {d, c} = Block66.decode_or_error(b)
        %{data: d, ctl: c}
      end

    assert RtlCase.run(mod, evs) == exp
  end

  test "encode then decode of valid words is the identity (hardware both)" do
    check all(ws <- words(), max_runs: 20) do
      blocks = for w <- ws, do: Block66.encode(w)
      evs = for {h, p} <- blocks, do: %{hdr: h, payload: p}

      exp =
        for w <- ws do
          {d, c} = Block66.decode_or_error(Block66.encode(w))
          %{data: d, ctl: c}
        end

      assert RtlCase.run(Hw.decoder(clocked: true), evs) == exp
    end
  end

  @tag :verilator
  test "encoder and decoder co-simulate" do
    [ws] = Enum.take(StreamData.resize(words(), 100), 1)
    RtlCase.cosim!(Hw.encoder(clocked: true), enc_events(ws))
    blocks = for w <- ws, do: Block66.encode(w)
    junk = for i <- 0..60, do: {rem(i, 4), i * 0x9E3779B97F4A7C15 &&& 0xFFFFFFFFFFFFFFFF}

    RtlCase.cosim!(
      Hw.decoder(clocked: true),
      for({h, p} <- blocks ++ junk, do: %{hdr: h, payload: p})
    )
  end
end
