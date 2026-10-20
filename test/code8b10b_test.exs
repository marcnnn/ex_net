defmodule ExNet.PCS.Code8b10bTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExNet.PCS.Code8b10b, as: C

  doctest ExNet.PCS.Code8b10b

  @all Enum.map(0..255, &{:d, &1}) ++ Enum.map(C.valid_k(), &{:k, &1})

  defp bits(code), do: code |> Integer.to_string(2) |> String.pad_leading(10, "0")

  # {name, symbol, RD- code, RD+ code}, IEEE 802.3 Clause 36 Tables 36-1 and 36-2
  @known [
    {"D0.0", C.d(0, 0), "1001110100", "0110001011"},
    {"D0.1", C.d(0, 1), "1001111001", "0110001001"},
    {"D1.0", C.d(1, 0), "0111010100", "1000101011"},
    {"D3.3", C.d(3, 3), "1100011100", "1100010011"},
    {"D5.6", C.d(5, 6), "1010010110", "1010010110"},
    {"D7.0", C.d(7, 0), "1110001011", "0001110100"},
    {"D10.2", C.d(10, 2), "0101010101", "0101010101"},
    {"D16.2", C.d(16, 2), "0110110101", "1001000101"},
    {"D17.7", C.d(17, 7), "1000110111", "1000110001"},
    {"D11.7", C.d(11, 7), "1101001110", "1101001000"},
    {"D21.5", C.d(21, 5), "1010101010", "1010101010"},
    {"D2.2", C.d(2, 2), "1011010101", "0100100101"},
    {"D30.3", C.d(30, 3), "0111100011", "1000011100"},
    {"D31.7", C.d(31, 7), "1010110001", "0101001110"},
    {"K28.0", C.k(28, 0), "0011110100", "1100001011"},
    {"K28.1", C.k(28, 1), "0011111001", "1100000110"},
    {"K28.2", C.k(28, 2), "0011110101", "1100001010"},
    {"K28.3", C.k(28, 3), "0011110011", "1100001100"},
    {"K28.4", C.k(28, 4), "0011110010", "1100001101"},
    {"K28.5", C.k(28, 5), "0011111010", "1100000101"},
    {"K28.6", C.k(28, 6), "0011110110", "1100001001"},
    {"K28.7", C.k(28, 7), "0011111000", "1100000111"},
    {"K23.7", C.k(23, 7), "1110101000", "0001010111"},
    {"K27.7", C.k(27, 7), "1101101000", "0010010111"},
    {"K29.7", C.k(29, 7), "1011101000", "0100010111"},
    {"K30.7", C.k(30, 7), "0111101000", "1000010111"}
  ]

  test "known code groups from the standard tables" do
    for {name, sym, neg, pos} <- @known do
      assert bits(elem(C.encode(:neg, sym), 0)) == neg, "#{name} RD-"
      assert bits(elem(C.encode(:pos, sym), 0)) == pos, "#{name} RD+"
    end
  end

  test "each symbol has the right disparity for its column and flips RD accordingly" do
    for rd <- [:neg, :pos], sym <- @all do
      {code, rd2} = C.encode(rd, sym)
      d = C.disparity(code)
      assert d in [-2, 0, 2]
      if rd == :neg, do: assert(d >= 0), else: assert(d <= 0)

      expected =
        cond do
          d > 0 -> :pos
          d < 0 -> :neg
          true -> rd
        end

      assert rd2 == expected
    end
  end

  test "code groups are unique per symbol, 268 symbols" do
    assert length(@all) == 256 + 12

    for {code, entries} <- Enum.group_by(C.table(), &elem(&1, 0), &elem(&1, 2)) do
      assert entries |> Enum.uniq() |> length() == 1, "collision at #{bits(code)}"
    end
  end

  test "no code has more than five equal bits in a row or a 7-bit comma outside K28.1/5/7" do
    for {code, _, sym} <- C.table() do
      refute String.contains?(bits(code), ["000000", "111111"])

      comma? = String.contains?(bits(code), ["0011111", "1100000"])
      assert comma? == sym in [{:k, 0x3C}, {:k, 0xBC}, {:k, 0xFC}], "#{inspect(sym)}"
    end
  end

  test "decode inverts encode, wrong column is a disparity error" do
    for rd <- [:neg, :pos], sym <- @all do
      {code, rd2} = C.encode(rd, sym)
      assert C.decode(rd, code) == {:ok, sym, rd2}
    end

    {code, _} = C.encode(:neg, C.d(0, 0))
    assert {:error, :disparity_error, _} = C.decode(:pos, code)
    assert {:error, :invalid_code, _} = C.decode(:neg, 0b0000000000)
    assert {:error, :invalid_code, _} = C.decode(:neg, 0b1111111111)
  end

  test "invalid K characters are rejected" do
    assert_raise ArgumentError, fn -> C.encode(:neg, {:k, 0x00}) end
    assert_raise ArgumentError, fn -> C.encode(:neg, {:d, 256}) end
  end

  property "streams of data decode without errors, RD stays balanced, commas never appear" do
    check all(bytes <- list_of(integer(0..255), min_length: 1, max_length: 200)) do
      {codes, _} =
        Enum.map_reduce(bytes, :neg, fn b, rd -> C.encode(rd, {:d, b}) end)

      stream = Enum.map_join(codes, &bits/1)
      refute String.contains?(stream, ["0011111", "1100000"])
      refute String.contains?(stream, ["000000", "111111"])

      {decoded, _} =
        Enum.map_reduce(codes, :neg, fn c, rd ->
          {:ok, sym, rd} = C.decode(rd, c)
          {sym, rd}
        end)

      assert decoded == Enum.map(bytes, &{:d, &1})

      ones = stream |> String.graphemes() |> Enum.count(&(&1 == "1"))
      assert abs(2 * ones - String.length(stream)) <= 2
    end
  end

  property "decode never raises" do
    check all(rd <- member_of([:neg, :pos]), code <- integer(0..1023)) do
      assert {tag, _, _} = C.decode(rd, code)
      assert tag in [:ok, :error]
    end
  end
end
