defmodule ExNet.PCS.Code8b10b do
  @moduledoc """
  8b/10b block code of IEEE 802.3 Clause 36 (Widmer and Franaszek).

  Symbols are `{:d, byte}` or `{:k, byte}` with `byte = y * 32 + x` for
  `D.x.y` / `K.x.y`; build them with `d/2` and `k/2`. Running disparity is
  `:neg` or `:pos`. A 10-bit code group is an integer with bit `a` as the
  MSB, so it reads like the tables (`abcdei fghj`, `a` is sent first).

      iex> alias ExNet.PCS.Code8b10b, as: C
      iex> {code, rd} = C.encode(:neg, C.k(28, 5))
      iex> {Integer.to_string(code, 2) |> String.pad_leading(10, "0"), rd}
      {"0011111010", :pos}
      iex> C.decode(:neg, code)
      {:ok, {:k, 0xBC}, :pos}
  """
  import Bitwise

  # D.x 6b sub-blocks: {RD-, RD+}, abcdei
  @six %{
    0 => {"100111", "011000"},
    1 => {"011101", "100010"},
    2 => {"101101", "010010"},
    3 => {"110001", "110001"},
    4 => {"110101", "001010"},
    5 => {"101001", "101001"},
    6 => {"011001", "011001"},
    7 => {"111000", "000111"},
    8 => {"111001", "000110"},
    9 => {"100101", "100101"},
    10 => {"010101", "010101"},
    11 => {"110100", "110100"},
    12 => {"001101", "001101"},
    13 => {"101100", "101100"},
    14 => {"011100", "011100"},
    15 => {"010111", "101000"},
    16 => {"011011", "100100"},
    17 => {"100011", "100011"},
    18 => {"010011", "010011"},
    19 => {"110010", "110010"},
    20 => {"001011", "001011"},
    21 => {"101010", "101010"},
    22 => {"011010", "011010"},
    23 => {"111010", "000101"},
    24 => {"110011", "001100"},
    25 => {"100110", "100110"},
    26 => {"010110", "010110"},
    27 => {"110110", "001001"},
    28 => {"001110", "001110"},
    29 => {"101110", "010001"},
    30 => {"011110", "100001"},
    31 => {"101011", "010100"}
  }
  @six_k28 {"001111", "110000"}

  # D.x.y 4b sub-blocks: {RD-, RD+}, fghj; 7 is the primary P7
  @four_d %{
    0 => {"1011", "0100"},
    1 => {"1001", "1001"},
    2 => {"0101", "0101"},
    3 => {"1100", "0011"},
    4 => {"1101", "0010"},
    5 => {"1010", "1010"},
    6 => {"0110", "0110"},
    7 => {"1110", "0001"}
  }
  @four_a7 {"0111", "1000"}
  @four_k %{
    0 => {"1011", "0100"},
    1 => {"0110", "1001"},
    2 => {"1010", "0101"},
    3 => {"1100", "0011"},
    4 => {"1101", "0010"},
    5 => {"0101", "1010"},
    6 => {"1001", "0110"},
    7 => {"0111", "1000"}
  }

  @valid_k [0x1C, 0x3C, 0x5C, 0x7C, 0x9C, 0xBC, 0xDC, 0xFC, 0xF7, 0xFB, 0xFD, 0xFE]

  def d(x, y) when x in 0..31 and y in 0..7, do: {:d, y * 32 + x}
  def k(x, y) when x in 0..31 and y in 0..7, do: {:k, y * 32 + x}

  @doc "Control symbols that have a valid code: K28.0 to K28.7, K23.7, K27.7, K29.7, K30.7."
  def valid_k, do: @valid_k

  @doc """
  Encodes one symbol for running disparity `rd`; returns `{code, next_rd}`.
  Raises `ArgumentError` for an invalid K character.
  """
  def encode(rd, {:d, byte}) when byte in 0..255 do
    x = byte &&& 31
    y = byte >>> 5
    {six, rd1} = pick(rd, Map.fetch!(@six, x))

    four =
      if y == 7 and ((rd1 == :neg and x in [17, 18, 20]) or (rd1 == :pos and x in [11, 13, 14])),
        do: @four_a7,
        else: Map.fetch!(@four_d, y)

    {four_bits, rd2} = pick(rd1, four)
    {join(six, four_bits), rd2}
  end

  def encode(rd, {:k, byte}) when byte in @valid_k do
    x = byte &&& 31
    y = byte >>> 5
    six = if x == 28, do: @six_k28, else: Map.fetch!(@six, x)
    {six_bits, rd1} = pick(rd, six)
    {four_bits, rd2} = pick(rd1, Map.fetch!(@four_k, y))
    {join(six_bits, four_bits), rd2}
  end

  def encode(_, sym), do: raise(ArgumentError, "invalid 8b/10b symbol #{inspect(sym)}")

  # chooses the column for the running disparity, tracks disparity of the sub-block
  defp pick(rd, {neg, pos}) do
    {bits, width} = if rd == :neg, do: {neg, String.length(neg)}, else: {pos, String.length(pos)}
    v = String.to_integer(bits, 2)
    {{v, width}, flip(rd, 2 * ones(v) - width)}
  end

  defp join({a, _}, {b, wb}), do: a <<< wb ||| b

  defp flip(rd, 0), do: rd
  defp flip(_, n) when n > 0, do: :pos
  defp flip(_, _), do: :neg

  @doc "Number of one bits."
  def ones(v), do: for(<<b::1 <- :binary.encode_unsigned(v)>>, reduce: 0, do: (acc -> acc + b))

  @doc "Disparity (ones minus zeros) of a 10-bit code."
  def disparity(code), do: 2 * ones(code) - 10

  # decode table: code => [{rd_required, symbol}], built on first use
  defp lookup(code) do
    tab =
      case :persistent_term.get({__MODULE__, :table}, nil) do
        nil ->
          t =
            for(
              rd <- [:neg, :pos],
              sym <- Enum.map(0..255, &{:d, &1}) ++ Enum.map(@valid_k, &{:k, &1})
            ) do
              {code, _} = encode(rd, sym)
              {code, rd, sym}
            end
            |> Enum.group_by(&elem(&1, 0), fn {_, rd, sym} -> {rd, sym} end)

          :persistent_term.put({__MODULE__, :table}, t)
          t

        t ->
          t
      end

    Map.get(tab, code)
  end

  @doc """
  Decodes a code group at running disparity `rd`.

  Returns `{:ok, symbol, rd'}`, or `{:error, reason, rd'}` with reason
  `:invalid_code` or `:disparity_error` (valid code in the other disparity
  column). `rd'` follows the received code's disparity either way.
  """
  def decode(rd, code) when code in 0..1023 do
    rd2 = flip(rd, disparity(code))

    case lookup(code) do
      nil ->
        {:error, :invalid_code, rd2}

      entries ->
        case Enum.find(entries, fn {r, _} -> r == rd end) do
          {_, sym} -> {:ok, sym, rd2}
          nil -> {:error, :disparity_error, rd2}
        end
    end
  end

  def decode(_, _), do: {:error, :invalid_code, :neg}

  @doc "All `{code, rd_required, symbol}` entries (for generating hardware tables)."
  def table do
    lookup(0)

    :persistent_term.get({__MODULE__, :table})
    |> Enum.flat_map(fn {c, es} -> for {rd, s} <- es, do: {c, rd, s} end)
  end

  @doc "Symbol of a code group ignoring running disparity, or `nil`."
  def symbol(code) do
    case lookup(code) do
      [{_, sym} | _] -> sym
      nil -> nil
    end
  end
end
