defmodule ExNet.MAC64ModelTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExNet.MAC
  alias ExNet.MAC.{Rx, Rx64, Tx64}
  alias ExNet.PCS.Base10GR
  alias ExNet.XgmiiGen

  property "Rx64 gives the same frames and verdicts as the byte-serial Rx on clean traffic" do
    for max_len <- [1522, 100] do
      check all(items <- XgmiiGen.traffic(max_len: 300, frames: 6), max_runs: 60) do
        words = XgmiiGen.words([{:idle, 2}] ++ items ++ [{:idle, 2}])
        expect = words |> XgmiiGen.byte_cycles() |> Rx.run(max_len: max_len)

        expect =
          for r <- expect do
            case r do
              {:ok, b} -> {:ok, b}
              {:error, st, b} -> {st, b}
            end
          end

        got =
          for {st, b} <- Rx64.frames(words, max_len: max_len),
              do: if(st == :ok, do: {:ok, b}, else: {st, b})

        assert got == expect
      end
    end
  end

  property "Tx64 words carry the byte model's wire frame and keep the gap" do
    check all(
            frames <-
              list_of(binary(min_length: 1, max_length: 150), min_length: 1, max_length: 5)
          ) do
      words = Tx64.run(frames)
      assert Base10GR.parse_frames(words) == Enum.map(frames, &MAC.wire_frame/1)
      # idle bytes between /T/ and the next /S/ (counting /T/) are at least 12
      lanes = Enum.flat_map(words, &XgmiiGen.lanes/1)

      gaps =
        lanes
        |> Enum.chunk_by(fn {c, b} -> c == 1 and b in [0xFD, 0x07] end)
        |> Enum.filter(fn [{c, b} | _] -> c == 1 and b in [0xFD, 0x07] end)
        |> Enum.map(&length/1)

      assert Enum.all?(Enum.slice(gaps, 0..-2//1), &(&1 >= 12))
    end
  end
end
