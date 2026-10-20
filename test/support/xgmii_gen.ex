defmodule ExNet.XgmiiGen do
  @moduledoc false
  # XGMII word streams from frame bytes, and generators for random traffic.
  import Bitwise
  use ExUnitProperties
  import StreamData
  alias ExNet.CRC32

  @idle {1, 0x07}

  @doc """
  Words for `items`: `{:frame, body, start_lane}` (`body` = data and FCS bytes; the Start word
  is `/S/ 6x55 SFD` for start lane 0 and `/S/ 2x55 SFD` for lane 4), `{:idle, words}`,
  `{:lanes, lane_list}` (raw lanes, `{ctl, byte}`). A frame is followed by idle lanes up to the
  word boundary.
  """
  def words(items) do
    items
    |> Enum.reduce([], fn
      {:idle, n}, acc ->
        acc ++ List.duplicate(@idle, 8 * n)

      {:lanes, l}, acc ->
        acc ++ l

      {:frame, body, lane}, acc ->
        acc |> align(lane) |> Kernel.++(frame_lanes(preamble(lane) <> body)) |> boundary()
    end)
    |> boundary()
    |> Enum.chunk_every(8)
    |> Enum.map(&word/1)
  end

  defp preamble(0), do: <<0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0xD5>>
  defp preamble(4), do: <<0x55, 0x55, 0xD5>>

  defp align(acc, lane) do
    acc = boundary(acc)
    acc ++ List.duplicate(@idle, lane)
  end

  defp boundary(acc), do: acc ++ List.duplicate(@idle, rem(8 - rem(length(acc), 8), 8))

  def frame_lanes(wire),
    do: [{1, 0xFB}] ++ for(<<b <- wire>>, do: {0, b}) ++ [{1, 0xFD}]

  def word(lanes) do
    lanes
    |> Enum.with_index()
    |> Enum.reduce({0, 0}, fn {{c, b}, i}, {d, k} -> {d ||| b <<< (8 * i), k ||| c <<< i} end)
  end

  def lanes({d, c}), do: for(i <- 0..7, do: {c >>> i &&& 1, d >>> (8 * i) &&& 0xFF})

  @doc "Byte-serial GMII-style cycles `{byte, dv, er}` of an XGMII word list (clean traffic only)."
  def byte_cycles(words) do
    Enum.flat_map(words, fn w ->
      for {c, b} <- lanes(w) do
        cond do
          c == 0 -> {b, true, false}
          b == 0xFB -> {0x55, true, false}
          true -> {0, false, false}
        end
      end
    end)
  end

  @doc "Frame body: `data` and FCS; `fcs`: :good or :bad (flipped CRC)."
  def wire(data, fcs \\ :good) do
    f = CRC32.fcs(data)

    f =
      if fcs == :bad, do: <<bxor(:binary.first(f), 0x5A), binary_part(f, 1, 3)::binary>>, else: f

    <<data::binary, f::binary>>
  end

  @doc "Random traffic items for `words/1`."
  def traffic(opts \\ []) do
    max = Keyword.get(opts, :max_len, 200)

    frame =
      gen all(
            len <- one_of([integer(0..70), integer(0..max)]),
            data <- binary(length: len),
            fcs <- frequency([{7, constant(:good)}, {1, constant(:bad)}]),
            lane <- member_of([0, 4]),
            flip <- frequency([{8, constant(nil)}, {1, integer(0..(len + 20))}]),
            gap <- integer(0..3)
          ) do
        w = wire(data, fcs)

        w =
          case flip do
            nil -> w
            i when i < byte_size(w) -> flip_byte(w, i)
            _ -> w
          end

        [{:frame, w, lane}, {:idle, gap}]
      end

    list_of(frame, min_length: 1, max_length: Keyword.get(opts, :frames, 8))
    |> map(&List.flatten/1)
  end

  defp flip_byte(bin, i) do
    <<a::binary-size(i), b, c::binary>> = bin
    <<a::binary, bxor(b, 0x10), c::binary>>
  end
end
