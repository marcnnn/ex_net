defmodule ExNet.AxisSource do
  @moduledoc false
  # Closed-loop AXI4-Stream source for `ExNet.RtlCase.drive/4` on a slave port `s_axis`.
  # plan: [{frame_bytes, gap_cycles_before, abort_after_beats | nil}]. A beat is offered until
  # taken (tvalid held). An abort drops tvalid for one cycle after `abort_after` beats and
  # discards the rest of the frame (underrun). `w` is the bus width in bytes (1 or 8).
  use ExUnitProperties
  alias ExNet.MAC.Tx64
  alias ExNet.RtlCase

  def plan(opts \\ []) do
    max = Keyword.get(opts, :max_len, 150)

    gen all(
          len <- one_of([integer(1..70), integer(1..max)]),
          data <- binary(length: len),
          gap <- one_of([constant(0), integer(0..20)]),
          abort <- frequency([{9, constant(nil)}, {1, integer(1..8)}])
        ) do
      {data, gap, if(abort && abort < len, do: abort)}
    end
  end

  def plans(opts \\ []), do: list_of(plan(opts), min_length: 1, max_length: 5)

  @doc "One frame as AXI beats `{data, keep, last?}`."
  def beats(frame, 1), do: for(<<b <- frame>>, do: {b, 0xFF, false}) |> mark_last()
  def beats(frame, 8), do: Tx64.beats(frame)

  defp mark_last(list), do: List.update_at(list, -1, fn {d, k, _} -> {d, k, true} end)

  defp start_next([]), do: :done
  defp start_next([{b, gap, abort} | rest]), do: {rest, gap, b, 0, abort}

  def init(plans, w),
    do: start_next(Enum.map(plans, fn {f, gap, abort} -> {beats(f, w), gap, abort} end))

  def fun(w) do
    fn acc, _i ->
      {offer, upd} =
        case acc do
          :done ->
            {nil, fn _ -> :done end}

          {rest, g, bs, _sent, abort} when g > 0 ->
            {nil, fn _ -> {rest, g - 1, bs, 0, abort} end}

          {rest, 0, [{d, k, l} | tl] = bs, sent, abort} ->
            if abort == sent and sent > 0 do
              {nil, fn _ -> start_next(rest) end}
            else
              {{d, k, l},
               fn outs ->
                 cond do
                   outs.s_axis_tready == 0 -> {rest, 0, bs, sent, abort}
                   l -> start_next(rest)
                   true -> {rest, 0, tl, sent + 1, abort}
                 end
               end}
            end
        end

      {inputs(offer, w), upd}
    end
  end

  defp inputs(nil, _), do: %{s_axis_tvalid: 0}
  defp inputs({d, _, l}, 1), do: %{s_axis_tvalid: 1, s_axis_tdata: d, s_axis_tlast: b(l)}

  defp inputs({d, k, l}, 8),
    do: %{s_axis_tvalid: 1, s_axis_tdata: d, s_axis_tkeep: k, s_axis_tlast: b(l)}

  defp b(true), do: 1
  defp b(false), do: 0

  @doc "Cycles that are enough to send `plans` (and drain)."
  def cycles(plans, extra \\ 40),
    do: Enum.sum(for {f, g, _} <- plans, do: byte_size(f) + g + 100) + extra

  @doc "Runs `plans` through `mod`; returns `{events, outputs, acc}` like `RtlCase.drive/4`."
  def run(mod, plans, w, extra \\ 40),
    do: RtlCase.drive(mod, init(plans, w), cycles(plans, extra), fun(w))
end
