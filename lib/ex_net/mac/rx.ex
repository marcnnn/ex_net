defmodule ExNet.MAC.Rx do
  @moduledoc """
  Receive side: finds preamble and SFD, passes the frame through a 4 byte
  delay line so the FCS is held back, and reports the verdict at the end of
  the frame.

  `step(state, {data, valid, error})` returns `{state, out}` with `out`:

    * `nil`: nothing this cycle
    * `{:data, byte, first?}`: frame byte, FCS excluded; data of a frame with a
      bad verdict is still delivered, the consumer must discard it on `:end`
      (this is why audio write commit has to wait, see PROJECT_REVIEW CRIT-04)
    * `{:end, status}` in the first cycle with `valid = false` after a frame:
      `:ok | :fcs_error | :rx_error | :runt | :oversize`

  Runt: fewer than 64 bytes including FCS. Oversize: more than `max_len`
  (default 1522, a tagged frame) bytes including FCS; bytes beyond the limit
  are not forwarded.

      iex> frame = :binary.copy(<<1>>, 60)
      iex> ExNet.MAC.rx_frames(ExNet.MAC.tx_cycles([frame]))
      [{:ok, frame}]
  """
  alias ExNet.CRC32

  defstruct phase: :idle, win: [], crc: 0xFFFFFFFF, count: 0, err: false, max_len: 1522

  def new(opts \\ []), do: %__MODULE__{max_len: Keyword.get(opts, :max_len, 1522)}

  def step(%__MODULE__{phase: :idle} = s, {0x55, true, _}), do: {%{s | phase: {:pre, 1}}, nil}
  def step(%__MODULE__{phase: :idle} = s, {_, true, _}), do: {%{s | phase: :skip}, nil}
  def step(%__MODULE__{phase: :idle} = s, _), do: {s, nil}

  def step(%__MODULE__{phase: :skip} = s, {_, true, _}), do: {s, nil}
  def step(%__MODULE__{phase: :skip} = s, _), do: {%{s | phase: :idle}, nil}

  def step(%__MODULE__{phase: {:pre, n}} = s, {d, true, _}) do
    case d do
      0x55 -> {%{s | phase: {:pre, n + 1}}, nil}
      0xD5 -> {%{s | phase: :frame, win: [], crc: CRC32.init(), count: 0, err: false}, nil}
      _ -> {%{s | phase: :skip}, nil}
    end
  end

  def step(%__MODULE__{phase: {:pre, _}} = s, _), do: {%{s | phase: :idle}, nil}

  def step(%__MODULE__{phase: :frame} = s, {d, true, er}) do
    count = s.count + 1
    crc = CRC32.step_byte(s.crc, d)
    win = s.win ++ [d]
    s = %{s | count: count, crc: crc, err: s.err or er}

    if count > 4 do
      [oldest | rest] = win
      out = if count <= s.max_len, do: {:data, oldest, count == 5}
      {%{s | win: rest}, out}
    else
      {%{s | win: win}, nil}
    end
  end

  def step(%__MODULE__{phase: :frame} = s, _) do
    status =
      cond do
        s.err -> :rx_error
        s.count < 64 -> :runt
        s.count > s.max_len -> :oversize
        s.crc != CRC32.residue() -> :fcs_error
        true -> :ok
      end

    {%{s | phase: :idle, win: []}, {:end, status}}
  end

  @doc "Runs all cycles; returns `{:ok, frame}` or `{:error, status, frame}` per frame."
  def run(cycles, opts \\ []) do
    {_, _, frames} =
      Enum.reduce(cycles, {new(opts), [], []}, fn c, {s, cur, frames} ->
        case step(s, c) do
          {s, nil} -> {s, cur, frames}
          {s, {:data, b, _}} -> {s, [b | cur], frames}
          {s, {:end, st}} -> {s, [], [finish(st, cur) | frames]}
        end
      end)

    Enum.reverse(frames)
  end

  defp finish(st, rev) do
    bin = rev |> Enum.reverse() |> :erlang.list_to_binary()
    if st == :ok, do: {:ok, bin}, else: {:error, st, bin}
  end
end
