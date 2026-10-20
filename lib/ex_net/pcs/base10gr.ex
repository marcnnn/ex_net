defmodule ExNet.PCS.Base10GR do
  @moduledoc """
  10GBASE-R PCS datapath as word-level step functions, one XGMII word per
  block.

    * `tx_step(state, {data, ctl}) -> {state, {sync, scrambled_payload}}`
    * `rx_step(state, {sync, scrambled_payload}) -> {state, out}` with
      `out = %{lock:, slip:, xgmii: word | nil}`; `xgmii` is `nil` until block
      lock, the all-error word for a locked but undecodable block

  Plus helpers to turn frame bytes into XGMII words and back. A frame is
  carried with Start in lane 0 (replacing the first preamble byte), data, Terminate
  in the lane after the last byte, idle fill.

      iex> alias ExNet.PCS.Base10GR, as: P
      iex> words = P.idle_words(80) ++ P.frame_words(<<0x55, 0x55, 1, 2, 3, 4, 5, 6, 7, 8, 9>>) ++ P.idle_words(4)
      iex> blocks = P.tx_run(words)
      iex> outs = P.rx_run(blocks)
      iex> P.parse_frames(for o <- outs, o.xgmii, do: o.xgmii)
      [<<0x55, 0x55, 1, 2, 3, 4, 5, 6, 7, 8, 9>>]
  """
  import Bitwise
  alias ExNet.PCS.{Block66, BlockLock, Scrambler}

  defmodule Tx do
    @moduledoc false
    defstruct scr: ExNet.PCS.Scrambler.seed()
  end

  defmodule Rx do
    @moduledoc false
    defstruct lock: %ExNet.PCS.BlockLock{}, scr: 0
  end

  def new_tx, do: %Tx{}
  def new_rx, do: %Rx{}

  def tx_step(%Tx{} = s, word) do
    {sync, payload} = Block66.encode(word)
    {scr, out} = Scrambler.scramble(s.scr, payload)
    {%{s | scr: scr}, {sync, out}}
  end

  def rx_step(%Rx{} = s, {sync, payload}) do
    {lock, st} = BlockLock.step(s.lock, sync)
    {scr, plain} = Scrambler.descramble(s.scr, payload)
    s = %{s | lock: lock, scr: scr}
    xgmii = if st.lock, do: Block66.decode_or_error({sync, plain})
    {s, %{lock: st.lock, slip: st.slip, xgmii: xgmii}}
  end

  def tx_run(words), do: map_state(words, new_tx(), &tx_step/2)
  def rx_run(blocks), do: map_state(blocks, new_rx(), &rx_step/2)

  defp map_state(list, s, f) do
    {_, out} =
      Enum.reduce(list, {s, []}, fn x, {s, acc} ->
        {s, o} = f.(s, x)
        {s, [o | acc]}
      end)

    Enum.reverse(out)
  end

  def idle_words(n), do: List.duplicate(Block66.idle(), n)

  @doc """
  XGMII words for frame bytes (preamble included, FCS included, at least 8
  bytes): `/S/` replaces byte 0, the Terminate follows the last byte.
  """
  def frame_words(<<_, rest::binary>>) when byte_size(rest) >= 7 do
    lanes = [{1, 0xFB}] ++ for(<<b <- rest>>, do: {0, b}) ++ [{1, 0xFD}]
    pad = rem(8 - rem(length(lanes), 8), 8)
    lanes = lanes ++ List.duplicate({1, 0x07}, pad)
    lanes |> Enum.chunk_every(8) |> Enum.map(&word/1)
  end

  defp word(lanes) do
    lanes
    |> Enum.with_index()
    |> Enum.reduce({0, 0}, fn {{c, b}, i}, {d, k} -> {d ||| b <<< (8 * i), k ||| c <<< i} end)
  end

  @doc "Frame byte lists (S replaced by 0x55) from a word stream; inverse of `frame_words/1`."
  def parse_frames(words) do
    lanes = Enum.flat_map(words, &lanes/1)
    collect(lanes, nil, [])
  end

  defp lanes({d, k}), do: for(i <- 0..7, do: {k >>> i &&& 1, d >>> (8 * i) &&& 0xFF})

  defp collect([], _, acc), do: Enum.reverse(acc)
  defp collect([{1, 0xFB} | r], _, acc), do: collect(r, [0x55], acc)

  defp collect([{1, 0xFD} | r], cur, acc) when is_list(cur),
    do: collect(r, nil, [cur |> Enum.reverse() |> :erlang.list_to_binary() | acc])

  defp collect([{0, b} | r], cur, acc) when is_list(cur), do: collect(r, [b | cur], acc)
  defp collect([_ | r], _, acc), do: collect(r, nil, acc)
end
