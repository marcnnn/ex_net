defmodule ExNet.MAC do
  @moduledoc """
  Ethernet MAC framing reference on a GMII-style byte interface.

  One interface cycle is `{data, valid, error}` (`data` 0..255, `valid` and
  `error` booleans), one byte per clock. The hardware MAC is checked cycle by
  cycle against `ExNet.MAC.Tx.step/2` and `ExNet.MAC.Rx.step/2`; the helpers
  here run whole frames through them.

      iex> frame = :binary.copy(<<0xAA>>, 60)
      iex> cycles = ExNet.MAC.tx_cycles([frame])
      iex> [{:ok, ^frame}] = ExNet.MAC.rx_frames(cycles)
      iex> length(cycles)  # 8 preamble/SFD + 60 + 4 FCS + 12 gap
      84
  """
  alias ExNet.MAC.{Rx, Tx}

  @min_frame 60
  def min_frame, do: @min_frame

  @doc """
  The bytes between the interframe gaps: preamble, SFD, frame padded to 60
  bytes, FCS.
  """
  def wire_frame(frame) do
    padded = pad(frame)

    <<0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0xD5, padded::binary,
      ExNet.CRC32.fcs(padded)::binary>>
  end

  @doc "Frame padded with zeros to the 60 byte minimum (before FCS)."
  def pad(frame) when byte_size(frame) >= @min_frame, do: frame
  def pad(frame), do: frame <> :binary.copy(<<0>>, @min_frame - byte_size(frame))

  @doc "Runs frames back to back through `Tx`, returning every interface cycle including the final gap."
  def tx_cycles(frames, opts \\ []), do: Tx.run(frames, opts)

  @doc """
  Runs interface cycles through `Rx`. Returns `{:ok, frame}` (FCS stripped)
  or `{:error, status, frame}` per frame.
  """
  def rx_frames(cycles, opts \\ []), do: Rx.run(cycles, opts)
end
