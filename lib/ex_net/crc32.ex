defmodule ExNet.CRC32 do
  @moduledoc """
  Ethernet FCS (CRC-32, IEEE 802.3) as a reference for the hardware CRC.

  The register is kept reflected, as in LSB-first serial hardware: `init/0`
  is 0xFFFFFFFF, the FCS is the complemented register, sent least significant
  byte first. Three equivalent formulations:

    * `step_bit/2`: one serial LFSR step, the definition
    * `step_byte/2`: one byte, bit 0 first
    * `step_word/3`: `n` bytes per cycle as a GF(2) matrix product,
      `crc' = S_n * crc xor D_n * data`. `matrices/1` returns the rows as
      bit masks, which is exactly what a parallel XOR network implements.

  `data` for `step_word/3` holds byte `k` of the stream in bits `8k+7..8k`
  (little-endian), the first byte on the wire in the lowest lanes.

      iex> ExNet.CRC32.crc32("123456789") == 0xCBF43926
      true
      iex> ExNet.CRC32.init() |> ExNet.CRC32.step_word(0x34333231, 4)
      ...> |> ExNet.CRC32.step_word(0x38373635, 4) |> ExNet.CRC32.step_byte(?9)
      ...> |> ExNet.CRC32.final()
      0xCBF43926
  """
  import Bitwise

  @poly 0xEDB88320
  @residue 0xDEBB20E3

  def init, do: 0xFFFFFFFF
  def final(crc), do: bxor(crc, 0xFFFFFFFF)

  @doc "Register value (reflected; 0xC704DD7B in MSB-first notation) after running a frame including its FCS through the CRC."
  def residue, do: @residue

  @doc "One serial step with input bit `bit` (0 or 1)."
  def step_bit(crc, bit) do
    shifted = crc >>> 1
    if (bxor(crc, bit) &&& 1) == 1, do: bxor(shifted, @poly), else: shifted
  end

  @doc "One byte, least significant bit first."
  def step_byte(crc, byte) do
    Enum.reduce(0..7, crc, fn i, c -> step_bit(c, byte >>> i &&& 1) end)
  end

  @doc "Runs all bytes of `bin` through `step_byte/2`."
  def step_bytes(crc, <<b, rest::binary>>), do: step_bytes(step_byte(crc, b), rest)
  def step_bytes(crc, <<>>), do: crc

  @doc "`n` bytes (1..8 typical) in one step using the matrix form."
  def step_word(crc, data, n) do
    %{state: sm, data: dm} = matrices(n)

    sm
    |> Enum.zip(dm)
    |> Enum.with_index()
    |> Enum.reduce(0, fn {{s, d}, i}, acc ->
      acc ||| parity(bxor(crc &&& s, data &&& d)) <<< i
    end)
  end

  @doc """
  Row masks of the `n`-byte parallel CRC. `%{state: [m0..m31], data: [m0..m31]}`:
  next-state bit `i` is `parity(crc & state[i]) xor parity(data & data[i])`.
  Memoised.
  """
  def matrices(n) when n >= 1 do
    key = {__MODULE__, n}

    case :persistent_term.get(key, nil) do
      nil ->
        m = build(n)
        :persistent_term.put(key, m)
        m

      m ->
        m
    end
  end

  defp build(n) do
    f = fn crc, data -> step_bytes(crc, <<data::little-size(8 * n)>>) end
    scols = for j <- 0..31, do: f.(1 <<< j, 0)
    dcols = for j <- 0..(8 * n - 1), do: f.(0, 1 <<< j)
    %{state: rows(scols, 32), data: rows(dcols, 32)}
  end

  defp rows(cols, nout) do
    for i <- 0..(nout - 1) do
      cols
      |> Enum.with_index()
      |> Enum.reduce(0, fn {c, j}, acc -> acc ||| (c >>> i &&& 1) <<< j end)
    end
  end

  @doc "XOR of all bits."
  def parity(x) when x < 0x100000000 do
    x = bxor(x, x >>> 16)
    x = bxor(x, x >>> 8)
    x = bxor(x, x >>> 4)
    x = bxor(x, x >>> 2)
    bxor(x, x >>> 1) &&& 1
  end

  def parity(x), do: parity(bxor(x &&& 0xFFFFFFFF, x >>> 32))

  @doc "CRC-32 of `bin`, equal to `:erlang.crc32/1`."
  def crc32(bin), do: init() |> step_bytes(bin) |> final()

  @doc "The 4 FCS bytes for `frame`, in transmission order."
  def fcs(frame), do: <<crc32(frame)::little-32>>

  @doc "True if `frame_with_fcs` (last 4 bytes are the FCS) is intact."
  def valid?(frame_with_fcs) when byte_size(frame_with_fcs) >= 4,
    do: step_bytes(init(), frame_with_fcs) == @residue

  def valid?(_), do: false
end
