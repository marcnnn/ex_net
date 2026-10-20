defmodule ExNet.MACTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExNet.{CRC32, Gen, MAC}
  alias ExNet.MAC.{Rx, Tx}

  doctest ExNet.MAC
  doctest ExNet.MAC.Tx
  doctest ExNet.MAC.Rx

  defp valid_bytes(cycles), do: for({b, true, _} <- cycles, do: b)

  test "wire frame: preamble, SFD, padding to 60, FCS" do
    wire = MAC.wire_frame(<<1, 2, 3>>)

    assert <<0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0xD5, 1, 2, 3, pad::binary-size(57),
             fcs::binary-size(4)>> = wire

    assert pad == :binary.copy(<<0>>, 57)
    assert fcs == CRC32.fcs(<<1, 2, 3>> <> pad)
    assert byte_size(MAC.wire_frame(:binary.copy(<<9>>, 100))) == 8 + 100 + 4
  end

  test "tx cycles are the wire frame followed by the gap" do
    for n <- [1, 59, 60, 61, 200] do
      frame = :crypto.strong_rand_bytes(n)
      cycles = MAC.tx_cycles([frame])
      {on, gap} = Enum.split_while(cycles, fn {_, v, _} -> v end)
      assert valid_bytes(on) |> :erlang.list_to_binary() == MAC.wire_frame(frame)
      assert gap == List.duplicate({0, false, false}, 12)
      assert Enum.all?(on, fn {_, _, er} -> er == false end)
    end
  end

  test "back to back frames keep exactly the configured gap" do
    cycles = MAC.tx_cycles([<<1>>, <<2>>, <<3>>], ifg: 20)
    runs = cycles |> Enum.chunk_by(&elem(&1, 1)) |> Enum.map(&{elem(hd(&1), 1), length(&1)})
    assert runs == [{true, 72}, {false, 20}, {true, 72}, {false, 20}, {true, 72}, {false, 20}]
  end

  test "tx step consumes input only while sending client bytes" do
    frame = <<10, 20, 30>>

    {_, readies} =
      Enum.reduce(1..30, {Tx.new(), []}, fn _, {s, acc} ->
        {s, _, ready} = Tx.step(s, {10, false})
        {s, [ready | acc]}
      end)

    # first 8 cycles are preamble, then ready every cycle until underrun handling
    assert Enum.at(Enum.reverse(readies), 8) == true
    assert MAC.tx_cycles([frame]) |> length() == 8 + 60 + 4 + 12
  end

  test "tx underrun aborts with an error cycle" do
    s = Tx.new()
    {s, _, _} = Tx.step(s, {1, false})
    s = Enum.reduce(1..8, s, fn _, s -> elem(Tx.step(s, {1, false}), 0) end)
    assert s.phase == :data
    {s, out, _} = Tx.step(s, nil)
    assert out == {0, true, true}
    assert {:ifg, 12} = s.phase
  end

  test "rx strips preamble and FCS, reports verdicts" do
    frame = :crypto.strong_rand_bytes(100)
    wire = :binary.bin_to_list(MAC.wire_frame(frame))
    cyc = fn bytes -> Enum.map(bytes, &{&1, true, false}) ++ [{0, false, false}] end

    assert MAC.rx_frames(cyc.(wire)) == [{:ok, frame}]

    bad = List.update_at(wire, 50, &Bitwise.bxor(&1, 1))
    assert [{:error, :fcs_error, _}] = MAC.rx_frames(cyc.(bad))

    short = Enum.take(wire, 8 + 40)
    assert [{:error, :runt, _}] = MAC.rx_frames(cyc.(short))

    assert [{:error, :rx_error, _}] =
             MAC.rx_frames(List.update_at(cyc.(wire), 30, fn {b, v, _} -> {b, v, true} end))

    big = :binary.bin_to_list(MAC.wire_frame(:binary.copy(<<1>>, 1600)))
    assert [{:error, :oversize, f}] = MAC.rx_frames(cyc.(big))
    assert byte_size(f) <= 1522
    assert [{:ok, _}] = MAC.rx_frames(cyc.(big), max_len: 2000)
  end

  test "rx ignores garbage without SFD and short preambles" do
    junk = [{0x12, true, false}, {0x34, true, false}, {0, false, false}]
    assert MAC.rx_frames(junk) == []
    assert MAC.rx_frames([{0x55, true, false}, {0x55, true, false}, {0, false, false}]) == []

    assert MAC.rx_frames(
             for(b <- [0x55, 0x55, 0x12], do: {b, true, false}) ++ [{0, false, false}]
           ) == []
  end

  test "rx data of a bad frame is still streamed, with the verdict at the end" do
    frame = :crypto.strong_rand_bytes(80)
    wire = :binary.bin_to_list(MAC.wire_frame(frame))
    bad = List.update_at(wire, 20, &Bitwise.bxor(&1, 0x80))
    cycles = Enum.map(bad, &{&1, true, false}) ++ [{0, false, false}]

    {_, outs} =
      Enum.reduce(cycles, {Rx.new(), []}, fn c, {s, acc} ->
        {s, o} = Rx.step(s, c)
        {s, [o | acc]}
      end)

    outs = outs |> Enum.reverse() |> Enum.reject(&is_nil/1)
    assert {:data, _, true} = hd(outs)
    assert length(outs) == 80 + 1
    assert List.last(outs) == {:end, :fcs_error}
  end

  property "tx then rx recovers padded frames, any number back to back" do
    check all(
            frames <-
              list_of(binary(min_length: 1, max_length: 300), min_length: 1, max_length: 4)
          ) do
      got = frames |> MAC.tx_cycles() |> MAC.rx_frames()
      assert got == Enum.map(frames, &{:ok, MAC.pad(&1)})
    end
  end

  property "rx never raises and ends every frame it starts" do
    check all(cycles <- Gen.cycles(400)) do
      {s, outs} =
        Enum.reduce(cycles ++ [{0, false, false}], {Rx.new(), []}, fn c, {s, acc} ->
          {s, o} = Rx.step(s, c)
          {s, [o | acc]}
        end)

      assert s.phase == :idle
      starts = Enum.count(outs, &match?({:data, _, true}, &1))
      ends = Enum.count(outs, &match?({:end, _}, &1))
      assert ends >= starts
    end
  end

  property "single byte corruption on the wire is never accepted as ok" do
    check all(
            frame <- binary(min_length: 14, max_length: 120),
            pos <- integer(8..200),
            x <- integer(1..255)
          ) do
      wire = MAC.wire_frame(frame) |> :binary.bin_to_list()
      pos = 8 + rem(pos, length(wire) - 8)
      bad = List.update_at(wire, pos, &Bitwise.bxor(&1, x))
      cycles = Enum.map(bad, &{&1, true, false}) ++ [{0, false, false}]
      assert [{:error, _, _}] = MAC.rx_frames(cycles)
    end
  end
end
