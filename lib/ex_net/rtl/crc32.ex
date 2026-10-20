defmodule ExNet.RTL.CRC32 do
  @moduledoc """
  Ethernet FCS CRC-32 in hardware, generated from `ExNet.CRC32.matrices/1`.

  `next/3` and `next_keep/4` return the next-state expression (usable inside
  other modules, the MACs inline them); `build/1` is a standalone module.

  Standalone module `crc32_<8*bytes>`:

    * inputs `data` (`8*bytes` bits, byte `k` of the stream in bits `8k+7..8k`),
      `keep` (`bytes` bits, only when `bytes > 1`: a contiguous mask from lane 0,
      i.e. 1, 3, 7, ... ; the number of ones is the number of valid bytes),
      `valid`, `init`
    * `init` loads the initial value `0xFFFFFFFF` before the word of the same
      cycle is applied (set it together with `valid` on the first word of a frame)
    * outputs, from the register (one cycle after the word): `state` is the
      reflected register of `ExNet.CRC32.step_word/3`, `crc` its complement (the
      CRC-32 of the bytes so far, `:erlang.crc32/1`; FCS bytes are `crc` little
      endian), `ok` is `state == ExNet.CRC32.residue()` (a frame including its
      FCS was fed)
    * `valid = 0, init = 1` clears the register; `keep = 0` with `valid` is
      treated as one byte
  """
  use ExHdl.RTL

  @init 0xFFFFFFFF

  @doc "Next register value after a full word of `bytes` bytes."
  def next(state, data, bytes) do
    %{state: sm, data: dm} = ExNet.CRC32.matrices(bytes)
    dmask = Bitwise.bsl(1, 8 * bytes) - 1

    rtl do
      bits =
        for j <- 31..0//-1 do
          bxor(
            reduce_xor(state &&& Enum.at(sm, j)),
            reduce_xor(data &&& band(Enum.at(dm, j), dmask))
          )
        end

      cat(bits)
    end
  end

  @doc """
  Next register value for a word of up to `bytes` bytes; `keep` selects how many
  (contiguous from lane 0, at least one).
  """
  def next_keep(state, data, keep, bytes) do
    rtl do
      Enum.reduce(1..bytes//1, nil, fn k, acc ->
        n = next(state, data, k)
        if is_nil(acc), do: n, else: mux(keep[k - 1], n, acc)
      end)
    end
  end

  @doc "Standalone CRC module for `bytes` bytes per cycle (1 for GMII, 8 for XGMII)."
  def build(bytes \\ 1) do
    module "crc32_#{8 * bytes}" do
      data = input(:data, 8 * bytes)
      keep = if bytes > 1, do: input(:keep, bytes)
      valid = input(:valid, 1)
      init = input(:init, 1)
      state_o = output(:state, 32)
      crc = output(:crc, 32)
      ok = output(:ok, 1)
      state = reg(:state_r, 32, reset: @init)
      from = wire(:from, mux(init, const(@init, 32), state))
      nxt = if bytes > 1, do: next_keep(from, data, keep, bytes), else: next(from, data, 1)

      sync do
        if valid do
          state <~ nxt
        else
          if init, do: state <~ @init
        end
      end

      state_o <~ state
      crc <~ ~~~state
      ok <~ (state == ExNet.CRC32.residue())
    end
  end

  @doc false
  def init_value, do: @init
end
