defmodule ExNet.MAC.Tx do
  @moduledoc """
  Transmit side: preamble (7 x 0x55), SFD 0xD5, client bytes, zero padding up
  to 60 bytes, FCS (LSB first), interframe gap (default 12 cycles).

  `step(state, input)` returns `{state, {data, valid, error}, ready}`.
  `input` is `nil` (nothing offered) or `{byte, last?}`; the byte is consumed
  in the cycle where `ready` is true. An empty offer while a frame is open
  aborts it: that cycle carries `error = true` and the gap follows.

      iex> alias ExNet.MAC.Tx
      iex> {s, out, ready} = Tx.step(Tx.new(), {7, true})
      iex> {out, ready, s.phase}
      {{0x55, true, false}, false, {:pre, 1}}
  """
  alias ExNet.CRC32

  @pad_to 60

  defstruct phase: :idle, crc: 0xFFFFFFFF, n: 0, ifg: 12

  def new(opts \\ []), do: %__MODULE__{ifg: Keyword.get(opts, :ifg, 12)}

  def step(%__MODULE__{phase: :idle} = s, nil), do: {s, {0, false, false}, false}

  def step(%__MODULE__{phase: :idle} = s, _in),
    do: {%{s | phase: {:pre, 1}}, {0x55, true, false}, false}

  def step(%__MODULE__{phase: {:pre, 7}} = s, _in),
    do: {%{s | phase: :data, crc: CRC32.init(), n: 0}, {0xD5, true, false}, false}

  def step(%__MODULE__{phase: {:pre, k}} = s, _in),
    do: {%{s | phase: {:pre, k + 1}}, {0x55, true, false}, false}

  def step(%__MODULE__{phase: :data} = s, nil),
    do: {%{s | phase: {:ifg, s.ifg}}, {0, true, true}, false}

  def step(%__MODULE__{phase: :data} = s, {b, last?}) do
    crc = CRC32.step_byte(s.crc, b)
    n = s.n + 1
    next = if last?, do: after_data(n), else: :data
    {fcs_or(%{s | phase: next, crc: crc, n: n}), {b, true, false}, true}
  end

  def step(%__MODULE__{phase: :pad} = s, _in) do
    crc = CRC32.step_byte(s.crc, 0)
    n = s.n + 1
    {fcs_or(%{s | phase: after_data(n), crc: crc, n: n}), {0, true, false}, false}
  end

  def step(%__MODULE__{phase: {:fcs, [b]}} = s, _in),
    do: {%{s | phase: {:ifg, s.ifg}}, {b, true, false}, false}

  def step(%__MODULE__{phase: {:fcs, [b | rest]}} = s, _in),
    do: {%{s | phase: {:fcs, rest}}, {b, true, false}, false}

  def step(%__MODULE__{phase: {:ifg, k}} = s, _in) do
    next = if k <= 1, do: :idle, else: {:ifg, k - 1}
    {%{s | phase: next}, {0, false, false}, false}
  end

  defp after_data(n) when n >= @pad_to, do: :fcs
  defp after_data(_), do: :pad

  defp fcs_or(%{phase: :fcs, crc: crc} = s),
    do: %{s | phase: {:fcs, :binary.bin_to_list(<<CRC32.final(crc)::little-32>>)}}

  defp fcs_or(s), do: s

  @doc "Drives `frames` (binaries without FCS) through the MAC; stops when it is idle again."
  def run(frames, opts \\ []), do: loop(new(opts), frames, [])

  defp loop(s, frames, acc) do
    {offer, rest_after} = offer(frames)
    {s2, out, ready} = step(s, offer)
    frames = if ready, do: rest_after, else: frames
    acc = [out | acc]

    if s2.phase == :idle and frames == [],
      do: Enum.reverse(acc),
      else: loop(s2, frames, acc)
  end

  defp offer([]), do: {nil, []}
  defp offer([<<b>> | rest]), do: {{b, true}, rest}
  defp offer([<<b, tail::binary>> | rest]), do: {{b, false}, [tail | rest]}
  defp offer([<<>> | rest]), do: offer(rest)
end
