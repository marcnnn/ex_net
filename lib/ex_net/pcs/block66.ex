defmodule ExNet.PCS.Block66 do
  @moduledoc """
  64b/66b block encoding of XGMII words (IEEE 802.3 Clause 49).

  An XGMII word is `{data, ctl}`: `data` is 64 bits with lane `i` in bits
  `8i+7..8i`, `ctl` has bit `i` set for a control character in lane `i`
  (Idle 0x07, LPI 0x06, Start 0xFB, Terminate 0xFD, Error 0xFE, Sequence
  0x9C, Signal 0x5C).

  A block is `{sync, payload}`: `sync` is 1 for a data block (`01`) or 2 for a
  control block (`10`), bit 0 of it goes on the wire first; `payload` is 64
  bits, bit 0 first on the wire. Control blocks carry the block type in bits
  7..0. Layout of the 56 bits above it:

    * C lanes are 7-bit control codes (Idle 0x00, LPI 0x06, Error 0x1E), packed
      from bit 8 in lane order (`0x1E`, `0x33`, `0x2D` for lanes 0-3; lanes 4-7
      of `0x1E` and `0x4B` continue at bit 36 or 8+28)
    * D lanes keep their lane position (bits `8i`), `O` codes are 4 bits
      (Sequence 0x0, Signal 0xF) at bits 32-35 (lane 0) and 36-39 (lane 4)
    * Terminate blocks `0x87` .. `0xFF` (T in lane 0..7) hold the data bytes of
      lanes below T in bytes 1.., followed by the 7-bit codes of the lanes above

  The layout is written from the Clause 49 block format table (Figure 49-7)
  from memory; the block type values and known frames (idle `0x1E`, start
  `0x78`) are covered by tests, the intra-block bit positions are the part to
  re-verify against the standard before relying on them.

      iex> alias ExNet.PCS.Block66
      iex> Block66.encode(Block66.idle())
      {2, 0x1E}
      iex> Block66.encode({0xD5555555555555FB, 0x01})
      {2, 0xD555555555555578}
  """
  import Bitwise

  @idle_char 0x07
  @lpi_char 0x06
  @start 0xFB
  @term 0xFD
  @error_char 0xFE
  @seq 0x9C
  @sig 0x5C

  @t_types [0x87, 0x99, 0xAA, 0xB4, 0xCC, 0xD2, 0xE1, 0xFF]

  def idle, do: {0x0707070707070707, 0xFF}
  def error_word, do: {0xFEFEFEFEFEFEFEFE, 0xFF}

  @doc "Block type of a word, or `nil` if the word has no valid encoding."
  def classify({data, ctl}) do
    lanes = for i <- 0..7, do: {ctl >>> i &&& 1, data >>> (8 * i) &&& 0xFF}
    kinds = Enum.map(lanes, &kind/1)
    pattern(kinds)
  end

  defp kind({0, _}), do: :d
  defp kind({1, @start}), do: :s
  defp kind({1, @term}), do: :t
  defp kind({1, o}) when o in [@seq, @sig], do: :o
  defp kind({1, _}), do: :c

  defp pattern(k) do
    case k do
      [:d, :d, :d, :d, :d, :d, :d, :d] -> :data
      [:c, :c, :c, :c, :c, :c, :c, :c] -> 0x1E
      [:s, :d, :d, :d, :d, :d, :d, :d] -> 0x78
      [:c, :c, :c, :c, :s, :d, :d, :d] -> 0x33
      [:o, :d, :d, :d, :s, :d, :d, :d] -> 0x66
      [:o, :d, :d, :d, :o, :d, :d, :d] -> 0x55
      [:c, :c, :c, :c, :o, :d, :d, :d] -> 0x2D
      [:o, :d, :d, :d, :c, :c, :c, :c] -> 0x4B
      _ -> terminate(k)
    end
  end

  defp terminate(k) do
    case Enum.find_index(k, &(&1 == :t)) do
      nil ->
        nil

      i ->
        {before, [_ | after_t]} = Enum.split(k, i)

        if Enum.all?(before, &(&1 == :d)) and Enum.all?(after_t, &(&1 == :c)),
          do: Enum.at(@t_types, i)
    end
  end

  @doc "Encodes a word; words with no valid encoding become an error block."
  def encode({data, ctl} = w) do
    case classify(w) do
      :data -> {1, data}
      nil -> encode_ctl(0x1E, error_word())
      type -> encode_ctl(type, {data, ctl})
    end
  end

  defp encode_ctl(type, {data, _ctl} = w) do
    lane = fn i -> data >>> (8 * i) &&& 0xFF end
    ccode = fn i -> ccode(lane.(i)) end
    ocode = fn i -> if lane.(i) == @sig, do: 0xF, else: 0x0 end
    nat = fn lo, hi -> for i <- lo..hi, reduce: 0, do: (acc -> acc ||| lane.(i) <<< (8 * i)) end
    cs = fn lanes, start -> pack7(Enum.map(lanes, ccode), start) end
    _ = w

    body =
      case type do
        0x1E -> cs.(0..7, 8)
        0x78 -> nat.(1, 7)
        0x33 -> cs.(0..3, 8) ||| nat.(5, 7)
        0x66 -> nat.(1, 3) ||| ocode.(0) <<< 32 ||| nat.(5, 7)
        0x55 -> nat.(1, 3) ||| ocode.(0) <<< 32 ||| ocode.(4) <<< 36 ||| nat.(5, 7)
        0x2D -> cs.(0..3, 8) ||| ocode.(4) <<< 36 ||| nat.(5, 7)
        0x4B -> nat.(1, 3) ||| ocode.(0) <<< 32 ||| cs.(4..7, 36)
        t -> terminate_body(t, lane, ccode)
      end

    {2, (body &&& ~~~0xFF) ||| type}
  end

  defp terminate_body(type, lane, ccode) do
    k = Enum.find_index(@t_types, &(&1 == type))
    data = for i <- 0..(k - 1)//1, reduce: 0, do: (acc -> acc ||| lane.(i) <<< (8 + 8 * i))
    data ||| pack7(for(j <- (k + 1)..7//1, do: ccode.(j)), 8 + 8 * k)
  end

  defp pack7(codes, start) do
    codes
    |> Enum.with_index()
    |> Enum.reduce(0, fn {c, i}, acc -> acc ||| c <<< (start + 7 * i) end)
  end

  defp ccode(@idle_char), do: 0x00
  defp ccode(@lpi_char), do: 0x06
  defp ccode(_), do: 0x1E

  defp cchar(0x00), do: @idle_char
  defp cchar(0x06), do: @lpi_char
  defp cchar(_), do: @error_char

  @doc "Decodes a block; `{:error, reason}` for a bad sync header or block type."
  def decode({1, payload}) when payload in 0..0xFFFFFFFFFFFFFFFF, do: {:ok, {payload, 0}}

  def decode({2, payload}) when payload in 0..0xFFFFFFFFFFFFFFFF do
    type = payload &&& 0xFF

    with {:ok, lanes} <- lanes(type, payload) do
      {:ok,
       Enum.reduce(Enum.with_index(lanes), {0, 0}, fn {{c, b}, i}, {d, k} ->
         {d ||| b <<< (8 * i), k ||| c <<< i}
       end)}
    end
  end

  def decode({sync, _}) when sync in [0, 3], do: {:error, :bad_sync}
  def decode(_), do: {:error, :bad_block}

  @doc "Like `decode/1` but returns the all-error word for an invalid block (RX behaviour)."
  def decode_or_error(b) do
    case decode(b) do
      {:ok, w} -> w
      {:error, _} -> error_word()
    end
  end

  defp lanes(type, p) do
    d = fn i -> {0, p >>> (8 * i) &&& 0xFF} end
    c = fn start -> {1, cchar(p >>> start &&& 0x7F)} end
    cs = fn n, start -> for j <- 0..(n - 1), do: c.(start + 7 * j) end
    o = fn start -> o4(p >>> start &&& 0xF) end

    case type do
      0x1E ->
        {:ok, cs.(8, 8)}

      0x78 ->
        {:ok, [{1, @start} | for(i <- 1..7, do: d.(i))]}

      0x33 ->
        {:ok, cs.(4, 8) ++ [{1, @start}, d.(5), d.(6), d.(7)]}

      0x66 ->
        with {:ok, o0} <- o.(32),
             do: {:ok, [o0, d.(1), d.(2), d.(3), {1, @start}, d.(5), d.(6), d.(7)]}

      0x55 ->
        both(o.(32), o.(36), fn o0, o4 -> [o0, d.(1), d.(2), d.(3), o4, d.(5), d.(6), d.(7)] end)

      0x2D ->
        with {:ok, o4} <- o.(36), do: {:ok, cs.(4, 8) ++ [o4, d.(5), d.(6), d.(7)]}

      0x4B ->
        with {:ok, o0} <- o.(32), do: {:ok, [o0, d.(1), d.(2), d.(3)] ++ cs.(4, 36)}

      t when t in @t_types ->
        {:ok, terminate_lanes(t, p)}

      _ ->
        {:error, :bad_block_type}
    end
  end

  defp both({:ok, a}, {:ok, b}, f), do: {:ok, f.(a, b)}
  defp both(_, _, _), do: {:error, :bad_ordered_set}

  defp terminate_lanes(type, p) do
    k = Enum.find_index(@t_types, &(&1 == type))
    data = for i <- 0..(k - 1)//1, do: {0, p >>> (8 + 8 * i) &&& 0xFF}
    ctl = for j <- 0..(6 - k)//1, do: {1, cchar(p >>> (8 + 8 * k + 7 * j) &&& 0x7F)}
    data ++ [{1, @term}] ++ ctl
  end

  defp o4(0x0), do: {:ok, {1, @seq}}
  defp o4(0xF), do: {:ok, {1, @sig}}
  defp o4(_), do: {:error, :bad_ordered_set}

  @doc "The 66 bits as an integer, sync header in bits 1..0 (the first bit sent is bit 0)."
  def to_bits({sync, payload}), do: payload <<< 2 ||| sync
  def from_bits(v), do: {v &&& 3, v >>> 2}
end
