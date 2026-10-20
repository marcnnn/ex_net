defmodule ExNet.CRC32Test do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise
  alias ExNet.CRC32

  doctest ExNet.CRC32

  test "check value" do
    assert CRC32.crc32("123456789") == 0xCBF43926
    assert CRC32.crc32("") == 0
    assert CRC32.crc32(<<0, 0, 0, 0>>) == 0x2144DF1C
    assert CRC32.crc32(:binary.copy(<<0>>, 32)) == 0x190A55AD
  end

  test "bit-serial equals byte step" do
    for b <- [0, 1, 0x55, 0xFF] do
      serial = Enum.reduce(0..7, CRC32.init(), fn i, c -> CRC32.step_bit(c, b >>> i &&& 1) end)
      assert serial == CRC32.step_byte(CRC32.init(), b)
    end
  end

  test "residue: frame plus FCS leaves a constant register" do
    for n <- [0, 1, 59, 60, 1500] do
      frame = :crypto.strong_rand_bytes(n)
      assert CRC32.step_bytes(CRC32.init(), frame <> CRC32.fcs(frame)) == CRC32.residue()
      assert CRC32.valid?(frame <> CRC32.fcs(frame))
    end

    # the standard quotes it MSB-first: bit-reversed register
    rev =
      for(i <- 0..31, reduce: 0, do: (acc -> acc ||| (CRC32.residue() >>> i &&& 1) <<< (31 - i)))

    assert rev == 0xC704DD7B
  end

  test "matrices are 32 rows of masks that fit the word" do
    for n <- [1, 2, 4, 8] do
      %{state: s, data: d} = CRC32.matrices(n)
      assert length(s) == 32 and length(d) == 32
      assert Enum.all?(s, &(&1 < 1 <<< 32))
      assert Enum.all?(d, &(&1 < 1 <<< (8 * n)))
    end
  end

  test "column j of the state matrix is the response to register bit j" do
    %{state: rows} = CRC32.matrices(1)

    for j <- 0..31 do
      col =
        for {m, i} <- Enum.with_index(rows),
            (m >>> j &&& 1) == 1,
            reduce: 0,
            do: (acc -> acc ||| 1 <<< i)

      assert col == CRC32.step_bytes(1 <<< j, <<0>>)
    end
  end

  property "matches :erlang.crc32/1" do
    check all(bin <- binary(max_length: 300)) do
      assert CRC32.crc32(bin) == :erlang.crc32(bin)
    end
  end

  property "n-byte parallel step equals n byte steps" do
    check all(n <- integer(1..8), crc <- integer(0..0xFFFFFFFF), data <- binary(length: n)) do
      <<word::little-size(n * 8)>> = data
      assert CRC32.step_word(crc, word, n) == CRC32.step_bytes(crc, data)
    end
  end

  property "8-byte words plus a byte tail equal the serial CRC" do
    check all(bin <- binary(max_length: 200)) do
      assert words(CRC32.init(), bin) |> CRC32.final() == :erlang.crc32(bin)
    end
  end

  defp words(crc, <<w::little-64, rest::binary>>), do: words(CRC32.step_word(crc, w, 8), rest)
  defp words(crc, tail), do: CRC32.step_bytes(crc, tail)

  property "single bit errors are detected" do
    check all(bin <- binary(min_length: 1, max_length: 100), pos <- integer(0..799)) do
      framed = bin <> CRC32.fcs(bin)
      bit = rem(pos, bit_size(framed))
      <<pre::bitstring-size(bit), b::1, post::bitstring>> = framed
      refute CRC32.valid?(<<pre::bitstring, 1 - b::1, post::bitstring>>)
    end
  end
end
