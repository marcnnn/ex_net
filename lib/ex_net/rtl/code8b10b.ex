defmodule ExNet.RTL.Code8b10b do
  @moduledoc """
  8b/10b encoder and decoder (IEEE 802.3 Clause 36) in hardware, generated at
  elaboration time from `ExNet.PCS.Code8b10b` (`encode/2`, `decode/2`,
  `symbol/1`): a ROM-like `mux` over the symbol (encoder, 512 words) or the
  code group (decoder, 1024 words), plus a few gates for the running
  disparity. Bit order as in the model: a 10-bit code is `abcdei fghj` with
  `a` in bit 9. Running disparity is one bit, 1 = RD+.

  `encode/3` and `decode/3` return expressions for use inside other modules
  (the PCS inlines them); `build_enc/0` and `build_dec/0` are the standalone
  modules, purely combinational (outputs of a cycle depend on that cycle's
  inputs only, no latency, no registers).

  Module `enc8b10b`:

    * inputs `k` (1), `data` (8, `y * 32 + x` as `D.x.y`), `rd` (1)
    * outputs `code` (10), `rd_next` (1), `bad` (1: `k` set for a byte that is
      not one of the 12 valid control characters; `code` is 0 and `rd_next` = `rd`)

  Module `dec8b10b`:

    * inputs `code` (10), `rd` (1)
    * outputs `data` (8), `k` (1), `code_err` (1: not a code group at either
      disparity; `data` and `k` are 0), `disp_err` (1: a valid group of the
      other disparity column; `data` and `k` are the symbol it stands for),
      `rd_next` (1: RD+ after a group with more ones, RD- with more zeros,
      unchanged if balanced; also after errors, as in `ExNet.PCS.Code8b10b.decode/2`)
  """
  use ExHdl.RTL

  alias ExNet.PCS.Code8b10b, as: C

  # one word per symbol {k, byte}: bad | nrd_pos | nrd_neg | code_pos(10) | code_neg(10)
  defp enc_word(k, byte) do
    sym = {if(k == 1, do: :k, else: :d), byte}

    if k == 1 and byte not in C.valid_k() do
      1 * Bitwise.bsl(1, 22)
    else
      {cn, rn} = C.encode(:neg, sym)
      {cp, rp} = C.encode(:pos, sym)

      Bitwise.bsl(b(rp == :pos), 21) + Bitwise.bsl(b(rn == :pos), 20) + Bitwise.bsl(cp, 10) + cn
    end
  end

  defp b(true), do: 1
  defp b(false), do: 0

  @doc "Encoder expressions `%{code, rd_next, bad}` for `k` (1), `data` (8), `rd` (1); `prefix` names the ROM wire."
  def encode(k, data, rd, prefix \\ "enc") do
    words = for kk <- 0..1, byte <- 0..255, do: const(enc_word(kk, byte), 23)

    rtl do
      rom = wire(:"#{prefix}_rom", mux(cat([k, data]), words))
      sel = fn pos, neg -> mux(rd, pos, neg) end

      %{
        code: sel.(slice(rom, 10, 10), slice(rom, 0, 10)),
        rd_next: mux(rom[22], rd, sel.(rom[21], rom[20])),
        bad: rom[22]
      }
    end
  end

  # one word per code: byte(8) | k | valid_neg | valid_pos | dpos | dneg
  defp dec_word(code) do
    {vn, sn} = valid(:neg, code)
    {vp, sp} = valid(:pos, code)

    {byte, k} =
      case sn || sp || C.symbol(code) do
        {:d, x} -> {x, 0}
        {:k, x} -> {x, 1}
        nil -> {0, 0}
      end

    d = C.disparity(code)

    Bitwise.bsl(byte, 5) + Bitwise.bsl(k, 4) + Bitwise.bsl(vn, 3) + Bitwise.bsl(vp, 2) +
      Bitwise.bsl(b(d > 0), 1) + b(d < 0)
  end

  defp valid(rd, code) do
    case C.decode(rd, code) do
      {:ok, sym, _} -> {1, sym}
      _ -> {0, nil}
    end
  end

  @doc "Decoder expressions `%{data, k, code_err, disp_err, rd_next}` for `code` (10) and `rd` (1)."
  def decode(code, rd, prefix \\ "dec") do
    words = for c <- 0..1023, do: const(dec_word(c), 13)

    rtl do
      rom = wire(:"#{prefix}_rom", mux(code, words))
      vn = rom[3]
      vp = rom[2]
      ok = mux(rd, vp, vn)

      %{
        data: slice(rom, 5, 8),
        k: rom[4],
        code_err: not (vn or vp),
        disp_err: (vn or vp) and not ok,
        rd_next: mux(rom[1], 1, mux(rom[0], 0, rd))
      }
    end
  end

  @doc "Standalone encoder module `enc8b10b`."
  def build_enc do
    module "enc8b10b" do
      domain(:sys)
      k = input(:k, 1)
      data = input(:data, 8)
      rd = input(:rd, 1)
      code = output(:code, 10)
      rd_next = output(:rd_next, 1)
      bad = output(:bad, 1)
      e = encode(k, data, rd)
      code <~ e.code
      rd_next <~ e.rd_next
      bad <~ e.bad
    end
  end

  @doc "Standalone decoder module `dec8b10b`."
  def build_dec do
    module "dec8b10b" do
      domain(:sys)
      code = input(:code, 10)
      rd = input(:rd, 1)
      data = output(:data, 8)
      k = output(:k, 1)
      code_err = output(:code_err, 1)
      disp_err = output(:disp_err, 1)
      rd_next = output(:rd_next, 1)
      d = decode(code, rd)
      data <~ d.data
      k <~ d.k
      code_err <~ d.code_err
      disp_err <~ d.disp_err
      rd_next <~ d.rd_next
    end
  end
end
