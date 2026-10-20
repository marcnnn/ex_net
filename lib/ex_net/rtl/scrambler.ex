defmodule ExNet.RTL.Scrambler do
  @moduledoc """
  10GBASE-R self-synchronising scrambler and descrambler, `x^58 + x^39 + 1`, 64
  bits per cycle. The XOR network comes from `ExNet.PCS.Scrambler` by unit
  vectors at elaboration (`masks/1`); state is the last 58 scrambled bits.

  Modules `pcs10gr_scr` (`build(:scramble)`) and `pcs10gr_descr`
  (`build(:descramble)`): inputs `data` (64, bit 0 first on the wire), `en`;
  output `out` (64), combinational from the state register and `data` (latency
  0). With `en` the state advances at the clock edge, without it the state
  holds. Reset state: all ones for the scrambler (`ExNet.PCS.Scrambler.seed/0`),
  0 for the descrambler. The sync header bypasses the scrambler; that is
  wiring in the tops, not part of this module.
  """
  use ExHdl.RTL
  import Bitwise, only: [band: 2, bsl: 2, bsr: 2, bor: 2]

  @doc """
  Row masks of the 64-bit step: `%{ns_s:, ns_d:, o_s:, o_d:}`, lists of 58, 58, 64
  and 64 integers; bit `k` of the next state (output) is the parity of
  `state & ns_s[k]` xor `data & ns_d[k]` (`o_s[k]`, `o_d[k]`).
  """
  def masks(mode) when mode in [:scramble, :descramble] do
    f = fn s, w -> apply(ExNet.PCS.Scrambler, mode, [s, w]) end
    cs = for j <- 0..57, do: f.(bsl(1, j), 0)
    cd = for i <- 0..63, do: f.(0, bsl(1, i))

    row = fn cols, pick, k ->
      cols
      |> Enum.with_index()
      |> Enum.reduce(0, fn {col, j}, acc ->
        if band(bsr(pick.(col), k), 1) == 1, do: bor(acc, bsl(1, j)), else: acc
      end)
    end

    %{
      ns_s: for(k <- 0..57, do: row.(cs, &elem(&1, 0), k)),
      ns_d: for(k <- 0..57, do: row.(cd, &elem(&1, 0), k)),
      o_s: for(k <- 0..63, do: row.(cs, &elem(&1, 1), k)),
      o_d: for(k <- 0..63, do: row.(cd, &elem(&1, 1), k))
    }
  end

  @doc "Expressions `{next_state, out}` for `state` (58 bits) and `data` (64 bits)."
  def next(state, data, mode) do
    m = masks(mode)

    rtl do
      net = fn ms, md, n ->
        cat(
          for k <- (n - 1)..0//-1 do
            bxor(reduce_xor(state &&& Enum.at(ms, k)), reduce_xor(data &&& Enum.at(md, k)))
          end
        )
      end

      {net.(m.ns_s, m.ns_d, 58), net.(m.o_s, m.o_d, 64)}
    end
  end

  @doc "Scrambler (`:scramble`) or descrambler (`:descramble`) module."
  def build(mode) do
    {name, reset} =
      case mode do
        :scramble -> {"pcs10gr_scr", ExNet.PCS.Scrambler.seed()}
        :descramble -> {"pcs10gr_descr", 0}
      end

    module name do
      data = input(:data, 64)
      en = input(:en, 1)
      out = output(:out, 64)
      st = reg(:st, 58, reset: reset)
      {ns, o} = next(st, data, mode)

      sync do
        if en, do: st <~ ns
      end

      out <~ o
    end
  end
end
