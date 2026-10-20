defmodule ExNet.PCS.Scrambler do
  @moduledoc """
  Self-synchronising scrambler of 10GBASE-R, `G(x) = x^58 + x^39 + 1`.

  Only the 64 payload bits of a block are scrambled, bit 0 first; the sync
  header bypasses it. The state is the last 58 scrambled bits: bit `j` is the
  scrambled bit sent `j + 1` bits ago. Scrambler and descrambler differ only
  in what is shifted in (output of the scrambler, input of the descrambler),
  so a descrambler locks after 58 bits whatever its initial state.

      iex> alias ExNet.PCS.Scrambler, as: S
      iex> {_, scrambled} = S.scramble(S.seed(), 0x0123456789ABCDEF)
      iex> {_, plain} = S.descramble(0, scrambled)
      iex> plain != 0x0123456789ABCDEF and Bitwise.band(Bitwise.bsr(plain, 58), 0x3F) == Bitwise.band(Bitwise.bsr(0x0123456789ABCDEF, 58), 0x3F)
      true
  """
  import Bitwise

  @mask58 (1 <<< 58) - 1

  def seed, do: @mask58

  @doc "One bit; returns `{state, out_bit}`."
  def scramble_bit(s, d) do
    out = bxor(d, bxor(s >>> 38 &&& 1, s >>> 57 &&& 1))
    {(s <<< 1 ||| out) &&& @mask58, out}
  end

  def descramble_bit(s, r) do
    out = bxor(r, bxor(s >>> 38 &&& 1, s >>> 57 &&& 1))
    {(s <<< 1 ||| r) &&& @mask58, out}
  end

  @doc "64-bit word, bit 0 first; returns `{state, scrambled}`."
  def scramble(s, word), do: run(&scramble_bit/2, s, word)

  @doc "64-bit word, bit 0 first; returns `{state, plain}`."
  def descramble(s, word), do: run(&descramble_bit/2, s, word)

  defp run(f, s, word) do
    Enum.reduce(0..63, {s, 0}, fn i, {s, acc} ->
      {s, o} = f.(s, word >>> i &&& 1)
      {s, acc ||| o <<< i}
    end)
  end
end
