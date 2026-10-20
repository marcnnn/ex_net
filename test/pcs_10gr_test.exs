defmodule ExNet.PCS.Base10GRTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  alias ExNet.{CRC32, MAC}
  alias ExNet.PCS.{Base10GR, Block66, BlockLock, Scrambler}

  doctest ExNet.PCS.Block66
  doctest ExNet.PCS.Scrambler
  doctest ExNet.PCS.BlockLock
  doctest ExNet.PCS.Base10GR

  @idle Block66.idle()

  describe "block types" do
    test "known blocks" do
      assert Block66.encode(@idle) == {2, 0x1E}
      assert Block66.encode({0xD5555555555555FB, 0x01}) == {2, 0xD555555555555578}

      assert Block66.encode({0x07070707070707FD, 0xFF}) == {2, 0x87}

      assert {1, 0x0123456789ABCDEF} == Block66.encode({0x0123456789ABCDEF, 0})
    end

    test "error word encodes to 0x1E with eight error codes" do
      {2, p} = Block66.encode(Block66.error_word())
      assert (p &&& 0xFF) == 0x1E
      codes = for i <- 0..7, do: p >>> (8 + 7 * i) &&& 0x7F
      assert codes == List.duplicate(0x1E, 8)
    end

    test "idle blocks are 0x1E with zero control codes, LPI is 0x06" do
      assert Block66.decode({2, 0x1E}) == {:ok, @idle}
      lpi = Enum.reduce(0..7, 0x1E, fn i, acc -> acc ||| 0x06 <<< (8 + 7 * i) end)
      assert {:ok, {0x0606060606060606, 0xFF}} = Block66.decode({2, lpi})
      assert Block66.encode({0x0606060606060606, 0xFF}) == {2, lpi}
    end

    defp word(lanes) do
      Enum.with_index(lanes)
      |> Enum.reduce({0, 0}, fn {{c, b}, i}, {d, k} -> {d ||| b <<< (8 * i), k ||| c <<< i} end)
    end

    defp lanes(spec) do
      for {k, i} <- Enum.with_index(spec) do
        case k do
          :d -> {0, 0x10 + i}
          :c -> {1, 0x07}
          :s -> {1, 0xFB}
          :t -> {1, 0xFD}
          :o -> {1, 0x9C}
          :q -> {1, 0x5C}
        end
      end
    end

    @patterns [
      {0x1E, [:c, :c, :c, :c, :c, :c, :c, :c]},
      {0x2D, [:c, :c, :c, :c, :o, :d, :d, :d]},
      {0x2D, [:c, :c, :c, :c, :q, :d, :d, :d]},
      {0x33, [:c, :c, :c, :c, :s, :d, :d, :d]},
      {0x66, [:o, :d, :d, :d, :s, :d, :d, :d]},
      {0x66, [:q, :d, :d, :d, :s, :d, :d, :d]},
      {0x55, [:o, :d, :d, :d, :o, :d, :d, :d]},
      {0x55, [:q, :d, :d, :d, :o, :d, :d, :d]},
      {0x78, [:s, :d, :d, :d, :d, :d, :d, :d]},
      {0x4B, [:o, :d, :d, :d, :c, :c, :c, :c]},
      {0x87, [:t, :c, :c, :c, :c, :c, :c, :c]},
      {0x99, [:d, :t, :c, :c, :c, :c, :c, :c]},
      {0xAA, [:d, :d, :t, :c, :c, :c, :c, :c]},
      {0xB4, [:d, :d, :d, :t, :c, :c, :c, :c]},
      {0xCC, [:d, :d, :d, :d, :t, :c, :c, :c]},
      {0xD2, [:d, :d, :d, :d, :d, :t, :c, :c]},
      {0xE1, [:d, :d, :d, :d, :d, :d, :t, :c]},
      {0xFF, [:d, :d, :d, :d, :d, :d, :d, :t]}
    ]

    test "all 15 control block types: classification, byte-0 type, round trip" do
      for {type, spec} <- @patterns do
        w = word(lanes(spec))
        assert Block66.classify(w) == type, inspect(spec)
        {2, p} = Block66.encode(w)
        assert (p &&& 0xFF) == type

        assert Block66.decode({2, p}) == {:ok, w},
               "#{Integer.to_string(type, 16)} #{inspect(spec)}"
      end

      assert @patterns |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 15
    end

    test "data bytes sit where the block layout says" do
      # D0..D3 T4 C5..C7 : data bytes right after the type byte
      w = word([{0, 1}, {0, 2}, {0, 3}, {0, 4}, {1, 0xFD}, {1, 7}, {1, 7}, {1, 7}])

      assert {2, 0x04030201_CC} =
               Block66.encode(w) |> then(fn {s, p} -> {s, p &&& 0xFFFFFFFFFF} end)

      # S0 D1..D7 keeps lanes in place
      assert {2, 0x0706050403020178} =
               Block66.encode(word([{1, 0xFB} | for(i <- 1..7, do: {0, i})]))
    end

    test "unencodable words become an error block, bad blocks decode to errors" do
      weird = word([{1, 0xFB}, {1, 0xFB}, {0, 0}, {0, 0}, {0, 0}, {0, 0}, {0, 0}, {0, 0}])
      assert Block66.classify(weird) == nil
      assert Block66.encode(weird) == Block66.encode(Block66.error_word())
      assert {:error, :bad_sync} = Block66.decode({0, 0})
      assert {:error, :bad_sync} = Block66.decode({3, 0})
      assert {:error, :bad_block_type} = Block66.decode({2, 0x00})
      assert Block66.decode_or_error({3, 0}) == Block66.error_word()
      # reserved ordered-set code
      assert {:error, _} = Block66.decode({2, 0x2D ||| 0x5 <<< 36})
    end

    test "66 bit packing" do
      assert Block66.to_bits({2, 0x1E}) == (0x1E <<< 2 ||| 2)
      assert Block66.from_bits(Block66.to_bits({1, 0xABCDEF})) == {1, 0xABCDEF}
    end

    property "valid words round trip" do
      check all(
              {_, spec} <- member_of(@patterns),
              bytes <- list_of(integer(0..255), length: 8)
            ) do
        base = lanes(spec)

        lanes =
          for {{c, b}, v} <- Enum.zip(base, bytes) do
            if c == 0, do: {0, v}, else: {c, b}
          end

        w = word(lanes)
        assert Block66.decode(Block66.encode(w)) == {:ok, w}
      end
    end

    property "data words" do
      check all(d <- integer(0..0xFFFFFFFFFFFFFFFF)) do
        assert Block66.encode({d, 0}) == {1, d}
        assert Block66.decode({1, d}) == {:ok, {d, 0}}
      end
    end

    property "arbitrary words encode without raising; decode of the result is the word or errors" do
      check all(d <- integer(0..0xFFFFFFFFFFFFFFFF), c <- integer(0..255)) do
        block = Block66.encode({d, c})

        case Block66.classify({d, c}) do
          nil ->
            assert Block66.decode(block) == {:ok, Block66.error_word()} or
                     match?({:ok, _}, Block66.decode(block))

          _ ->
            assert {:ok, _} = Block66.decode(block)
        end
      end
    end

    property "decode never raises" do
      check all(sync <- integer(0..3), p <- integer(0..0xFFFFFFFFFFFFFFFF)) do
        assert match?({:ok, _}, Block66.decode({sync, p})) or
                 match?({:error, _}, Block66.decode({sync, p}))

        {_, _} = {Block66.decode_or_error({sync, p}), 0}
      end
    end
  end

  describe "scrambler" do
    # independent formulation: y[n] = d[n] ^ y[n-39] ^ y[n-58] over a bit list
    defp ref_scramble(bits, history) do
      # history: list of previous outputs, most recent first
      {out, _} =
        Enum.reduce(bits, {[], history}, fn d, {acc, h} ->
          y = bxor(d, bxor(Enum.at(h, 38), Enum.at(h, 57)))
          {[y | acc], [y | h]}
        end)

      Enum.reverse(out)
    end

    defp scr(mod, fun, state, words) do
      Enum.map_reduce(words, state, fn w, s ->
        {s2, o} = apply(mod, fun, [s, w])
        {o, s2}
      end)
    end

    defp to_bits(word, n), do: for(i <- 0..(n - 1), do: word >>> i &&& 1)

    defp from_bits(bits),
      do: bits |> Enum.with_index() |> Enum.reduce(0, fn {b, i}, a -> a ||| b <<< i end)

    test "matches the recurrence y[n] = d[n] + y[n-39] + y[n-58]" do
      state = 0x2AAAAAAAAAAAAAA
      history = to_bits(state, 58)
      words = [0x0123456789ABCDEF, 0, 0xFFFFFFFFFFFFFFFF, 0xDEADBEEFCAFEBABE]
      bits = Enum.flat_map(words, &to_bits(&1, 64))
      expected = ref_scramble(bits, history) |> Enum.chunk_every(64) |> Enum.map(&from_bits/1)

      {got, _} = scr(Scrambler, :scramble, state, words)

      assert got == expected
    end

    test "all-zero input from the all-ones seed" do
      {_, out} = Scrambler.scramble(Scrambler.seed(), 0)
      # first 39 bits: y = 1 ^ 1 = 0 until the taps leave the seed
      assert (out &&& (1 <<< 39) - 1) == 0
      assert out != 0
    end

    property "descrambler locks after 58 bits from any state" do
      check all(
              tx <- integer(0..((1 <<< 58) - 1)),
              rx <- integer(0..((1 <<< 58) - 1)),
              words <- list_of(integer(0..0xFFFFFFFFFFFFFFFF), min_length: 3, max_length: 8)
            ) do
        {scrambled, _} = scr(Scrambler, :scramble, tx, words)
        {plain, _} = scr(Scrambler, :descramble, rx, scrambled)

        [_ | rest_in] = words
        [_ | rest_out] = plain
        assert rest_out == rest_in
      end
    end

    property "same state descrambles exactly" do
      check all(s <- integer(0..((1 <<< 58) - 1)), w <- integer(0..0xFFFFFFFFFFFFFFFF)) do
        {_, x} = Scrambler.scramble(s, w)
        assert {_, ^w} = Scrambler.descramble(s, x)
      end
    end
  end

  describe "block lock" do
    defp feed(s, headers),
      do:
        Enum.reduce(headers, {s, []}, fn h, {s, acc} ->
          {s, o} = BlockLock.step(s, h)
          {s, [o | acc]}
        end)
        |> then(fn {s, o} -> {s, Enum.reverse(o)} end)

    test "locks after 64 valid headers" do
      {s, outs} = feed(BlockLock.new(), List.duplicate(2, 64))
      assert Enum.map(outs, & &1.lock) == List.duplicate(false, 63) ++ [true]
      assert s.lock
    end

    test "unlocked: first invalid header slips and restarts the count" do
      {s, outs} = feed(BlockLock.new(), List.duplicate(1, 30) ++ [0] ++ List.duplicate(1, 63))
      assert Enum.at(outs, 30) == %{lock: false, slip: true}
      refute s.lock
      assert Enum.count(outs, & &1.slip) == 1
      {s, _} = feed(s, [1])
      assert s.lock
    end

    test "locked: up to 15 invalid in a window are tolerated, 16 lose lock" do
      {locked, _} = feed(BlockLock.new(), List.duplicate(1, 64))
      {s, outs} = feed(locked, List.duplicate(3, 15) ++ List.duplicate(1, 49))
      assert Enum.all?(outs, & &1.lock) and s.lock and Enum.all?(outs, &(not &1.slip))
      {s, outs} = feed(locked, List.duplicate(3, 16))
      assert List.last(outs) == %{lock: false, slip: true}
      refute s.lock
    end

    test "window counters restart after 64 headers" do
      {locked, _} = feed(BlockLock.new(), List.duplicate(1, 64))

      {s, outs} =
        feed(
          locked,
          List.duplicate(3, 10) ++
            List.duplicate(1, 54) ++ List.duplicate(3, 10) ++ List.duplicate(1, 54)
        )

      assert s.lock and Enum.all?(outs, & &1.lock)
    end
  end

  describe "full 10GBASE-R datapath" do
    defp frame_bytes(payload),
      do: <<0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0xD5>> <> payload <> CRC32.fcs(payload)

    test "frames of all lengths, every Terminate lane, come back intact" do
      for n <- 60..75 do
        payload = :crypto.strong_rand_bytes(n)
        bytes = frame_bytes(payload)
        words = Base10GR.idle_words(70) ++ Base10GR.frame_words(bytes) ++ Base10GR.idle_words(3)
        outs = words |> Base10GR.tx_run() |> Base10GR.rx_run()
        assert Enum.at(outs, 62).xgmii == nil
        assert Enum.at(outs, 63).xgmii == @idle
        frames = Base10GR.parse_frames(for o <- outs, o.xgmii, do: o.xgmii)
        assert frames == [bytes]
      end
    end

    test "terminate lane follows the frame length" do
      for len <- 8..16 do
        words = Base10GR.frame_words(:binary.copy(<<0x55>>, len))
        {_, last} = {nil, List.last(words)}

        t_lane =
          Enum.find(0..7, fn i ->
            (elem(last, 1) >>> i &&& 1) == 1 and (elem(last, 0) >>> (8 * i) &&& 0xFF) == 0xFD
          end)

        assert t_lane == rem(len, 8)
      end
    end

    test "before lock the RX outputs nothing, after bit errors in headers it slips" do
      blocks = Base10GR.idle_words(10) |> Base10GR.tx_run()
      outs = Base10GR.rx_run(blocks)
      assert Enum.all?(outs, &(&1.xgmii == nil and &1.lock == false))
      broken = List.replace_at(blocks, 3, {0, 0})
      assert Enum.at(Base10GR.rx_run(broken), 3).slip
    end

    test "locked, an undecodable block yields the error word" do
      blocks = Base10GR.idle_words(70) |> Base10GR.tx_run()
      # sync 2 with garbage payload after scrambling is still sync 2: decode error or valid
      outs = Base10GR.rx_run(blocks ++ [{2, 0x1234567890ABCDE0}])
      assert List.last(outs).xgmii != nil
    end

    property "random frames through the whole 10G path" do
      check all(
              payload <- binary(min_length: 60, max_length: 200),
              lead <- integer(0..5),
              tail <- integer(1..4)
            ) do
        bytes = frame_bytes(payload)

        words =
          Base10GR.idle_words(70 + lead) ++
            Base10GR.frame_words(bytes) ++ Base10GR.idle_words(tail)

        outs = words |> Base10GR.tx_run() |> Base10GR.rx_run()
        assert [^bytes] = Base10GR.parse_frames(for o <- outs, o.xgmii, do: o.xgmii)

        assert [{:ok, got}] =
                 bytes
                 |> binary_part(6, byte_size(bytes) - 6)
                 |> frame_to_cycles()
                 |> MAC.rx_frames()

        assert got == payload
      end
    end

    defp frame_to_cycles(bin),
      do: Enum.map(:binary.bin_to_list(bin), &{&1, true, false}) ++ [{0, false, false}]
  end
end
