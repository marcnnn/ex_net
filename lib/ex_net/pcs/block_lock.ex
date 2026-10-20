defmodule ExNet.PCS.BlockLock do
  @moduledoc """
  Block lock state machine (Clause 49 Figure 49-12), one step per received
  sync header.

  A header is valid if it is `01` or `10` (1 or 2). Unlocked, the first invalid
  header slips the alignment (the serdes shifts by one bit, `slip: true`).
  Locked, 16 invalid headers inside a window of 64 slip. A window of 64 valid
  headers sets the lock; windows restart after 64 headers. The intermediate
  states (TEST_SH, VALID_SH, INVALID_SH, GOOD_64, SLIP, RESET_CNT) are folded
  into one step; `step/2` returns `{state, %{lock: bool, slip: bool}}`.

      iex> alias ExNet.PCS.BlockLock, as: L
      iex> {s, out} = Enum.reduce(1..64, {L.new(), nil}, fn _, {s, _} -> L.step(s, 1) end)
      iex> {out.lock, L.step(s, 3) |> elem(1)}
      {true, %{lock: true, slip: false}}
  """
  defstruct lock: false, sh_cnt: 0, invalid: 0

  def new, do: %__MODULE__{}

  def step(s, sh) when sh in [1, 2] do
    cnt = s.sh_cnt + 1

    cond do
      cnt < 64 -> {%{s | sh_cnt: cnt}, out(s.lock, false)}
      s.invalid == 0 -> {%{s | lock: true, sh_cnt: 0, invalid: 0}, out(true, false)}
      true -> {%{s | sh_cnt: 0, invalid: 0}, out(s.lock, false)}
    end
  end

  def step(s, _invalid) do
    cnt = s.sh_cnt + 1
    inv = s.invalid + 1

    cond do
      inv >= 16 or not s.lock -> {%__MODULE__{lock: false}, out(false, true)}
      cnt >= 64 -> {%{s | sh_cnt: 0, invalid: 0}, out(s.lock, false)}
      true -> {%{s | sh_cnt: cnt, invalid: inv}, out(s.lock, false)}
    end
  end

  defp out(lock, slip), do: %{lock: lock, slip: slip}
end
