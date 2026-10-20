defmodule ExNet.MAC.Tx64 do
  @moduledoc """
  Transmit side for a 64-bit XGMII interface (10G), derived from `ExNet.MAC.Tx`.

  `step(state, offer)` returns `{state, {data, ctl}, ready}`: one XGMII word per
  call (`ExNet.PCS.Block66` lane convention: lane `i` in bits `8i+7..8i`, `ctl`
  bit `i` marks a control character). `offer` is `nil` or `{data, keep, last?}`,
  an AXI4-Stream beat (`keep` contiguous from lane 0; on beats other than the last
  it must be 0xFF). The beat is consumed when `ready` is true and an offer is made.

    * idle: idle words; an offer starts the frame with the Start word (`/S/` in
      lane 0, six 0x55, SFD 0xD5 in lane 7); `ready` is false
    * data (`ready` true): the offered beat goes out as is, the CRC runs; with `last?`
      the frame is padded with zeros to 60 bytes (extra zero words while the byte count
      is below 56 plus the final word), the FCS follows the last byte directly (little
      endian), then `/T/` and idles; no offer in this phase aborts the frame with a word
      of 8 `/E/` and one idle word
    * the gap after `/T/` is at least 12 bytes counting `/T/` (one idle word when `/T/`
      is in lanes 0 to 4, two otherwise), Start only in lane 0
    * a minimum frame (60 + 4 bytes) occupies Start + 8 + 1 (`/T/` in lane 0) + 1 idle
      = 11 words, 88 of 84 wire bytes

      iex> alias ExNet.MAC.Tx64
      iex> {s, out, ready} = Tx64.step(Tx64.new(), {0x0807060504030201, 0xFF, true})
      iex> {out, ready, s.phase}
      {{0xD5555555555555FB, 0x01}, false, :data}
  """
  import Bitwise
  alias ExNet.CRC32

  @idle {0x0707070707070707, 0xFF}
  @error {0xFEFEFEFEFEFEFEFE, 0xFF}
  @start {0xD5555555555555FB, 0x01}

  defstruct phase: :idle, nb: 0, crc: 0xFFFFFFFF

  def new, do: %__MODULE__{}
  def idle_word, do: @idle
  def start_word, do: @start

  def step(%{phase: :idle} = s, nil), do: {s, @idle, false}

  def step(%{phase: :idle} = s, _),
    do: {%{s | phase: :data, nb: 0, crc: CRC32.init()}, @start, false}

  def step(%{phase: :data} = s, nil), do: {%{s | phase: {:ifg, 1}}, @error, false}

  def step(%{phase: :data} = s, {d, keep, last?}) do
    r = ones(keep)
    dm = d &&& mask(r)

    cond do
      not last? -> {beat(s, d, 8), {d, 0}, true}
      s.nb >= 8 or (s.nb == 7 and r >= 4) -> done(s, dm, r, true)
      s.nb == 7 -> done(s, dm, 4, true)
      true -> {%{beat(s, dm, 8) | phase: :pad}, {dm, 0}, true}
    end
  end

  def step(%{phase: :pad} = s, _) do
    if s.nb == 7, do: done(s, 0, 4, false), else: {beat(s, 0, 8), {0, 0}, false}
  end

  def step(%{phase: {:tail, w}} = s, _), do: {%{s | phase: {:ifg, 1}}, w, false}

  def step(%{phase: {:ifg, k}} = s, _),
    do: {%{s | phase: if(k <= 1, do: :idle, else: {:ifg, k - 1})}, @idle, false}

  # one full data word through the CRC
  defp beat(s, d, n), do: %{s | nb: min(s.nb + 1, 8), crc: CRC32.step_word(s.crc, d, n)}

  # last word: `eff` data bytes (zero padded), FCS, /T/, idles; one or two words
  defp done(s, d, eff, ready) do
    fcs = CRC32.final(CRC32.step_word(s.crc, d, eff))
    bytes = for i <- 0..(eff - 1), do: {0, d >>> (8 * i) &&& 0xFF}
    bytes = bytes ++ for(i <- 0..3, do: {0, fcs >>> (8 * i) &&& 0xFF}) ++ [{1, 0xFD}]
    bytes = bytes ++ List.duplicate({1, 0x07}, rem(8 - rem(length(bytes), 8), 8))

    case bytes |> Enum.chunk_every(8) |> Enum.map(&word/1) do
      [w] -> {%{s | phase: {:ifg, 2}}, w, ready}
      [w, t] -> {%{s | phase: {:tail, t}}, w, ready}
    end
  end

  defp word(lanes) do
    lanes
    |> Enum.with_index()
    |> Enum.reduce({0, 0}, fn {{c, b}, i}, {d, k} -> {d ||| b <<< (8 * i), k ||| c <<< i} end)
  end

  defp mask(r), do: (1 <<< (8 * r)) - 1
  defp ones(keep), do: for(i <- 0..7, reduce: 0, do: (a -> a + (keep >>> i &&& 1)))

  @doc """
  Runs `frames` (binaries without FCS, at least one byte) back to back through the
  model, one AXI beat per ready cycle, until idle again; returns the XGMII words.
  """
  def run(frames) do
    beats = Enum.flat_map(frames, &beats/1)
    loop(new(), beats, [])
  end

  @doc "AXI beats `{data, keep, last?}` of a frame."
  def beats(frame) do
    chunks = for <<c::binary-size(8) <- frame>>, do: c
    rest = binary_part(frame, 8 * length(chunks), byte_size(frame) - 8 * length(chunks))
    all = chunks ++ if(rest == <<>>, do: [], else: [rest])
    n = length(all)

    all
    |> Enum.with_index(1)
    |> Enum.map(fn {c, i} ->
      bits = 8 * byte_size(c)
      <<v::little-size(bits)>> = c
      {v, (1 <<< byte_size(c)) - 1, i == n}
    end)
  end

  defp loop(s, beats, acc) do
    {s2, out, ready} = step(s, List.first(beats))
    beats = if ready and beats != [], do: tl(beats), else: beats
    acc = [out | acc]
    if s2.phase == :idle and beats == [], do: Enum.reverse(acc), else: loop(s2, beats, acc)
  end
end
