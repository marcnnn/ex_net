defmodule ExNet.MAC.Rx64 do
  @moduledoc """
  Receive side for a 64-bit XGMII interface (10G), word-level reference derived from
  `ExNet.MAC.Rx`.

  `step(state, {data, ctl})` takes one XGMII word (lane `i` in bits `8i+7..8i`, `ctl`
  bit `i` for a control character) and returns `{state, ev}` with
  `ev = %{sof: boolean, beat: nil | {data, keep, last?, user}, end: nil | status}`.
  The RTL shows `ev` one cycle later (registered outputs).

    * a frame starts in a word whose Start (`0xFB` control) sits in lane 0 or lane 4,
      followed by `0x55` data lanes and the SFD `0xD5` in lane 7; any other word while
      idle is ignored. The data starts in the next word, lane 0. `sof` is the event of
      that word. A word that carries a Terminate cannot start a new frame.
    * data words are scanned lane by lane; the first control lane ends the frame:
      `/T/` (0xFD) normally, anything else (idle, `/E/`, a Start) is a receive error.
      The bytes before it count as frame bytes, the rest of the word is ignored
    * the last 4 bytes of the frame are the FCS and are removed; the payload goes out
      as AXI4-Stream beats `{data, keep, last?, user}`, `keep` contiguous from lane 0 and
      `data` zero beyond `keep`. The decision is made one word late: a beat goes out in
      the step after its word arrived (and when the frame ends, the last beat goes out in
      the step of the word with `/T/`; a short tail of up to 3 bytes in the following
      step). Frames with at most 4 bytes give no beat
    * `user` is `code * 2 + (code != 0)` with code 0 ok, 1 FCS error, 2 receive error,
      3 runt (under 64 bytes with FCS), 4 oversize (more than `max_len`, default 1522);
      it is set on the last beat only. `end` is the status atom of
      `ExNet.MAC.Rx`, same priority (error, runt, oversize, FCS)
    * oversize frames are cut after `max_len - 4` payload bytes; the cut beat is
      flagged when the first excess byte arrives (oversize, or receive error if one was
      seen before), the exact status follows in `end`

  `frames/2` runs words and returns `{status, bytes}` per frame, comparable with
  `ExNet.MAC.Rx.run/2` on the byte-serial version of the same traffic.
  """
  import Bitwise
  alias ExNet.CRC32

  defstruct phase: :idle,
            hv: false,
            h: 0,
            k: 0,
            cnt: 0,
            crc: 0xFFFFFFFF,
            err: false,
            trunc: false,
            tail: nil,
            max_len: 1522

  def new(opts \\ []), do: %__MODULE__{max_len: Keyword.get(opts, :max_len, 1522)}

  @doc "Status code of the `user` field."
  def code(:ok), do: 0
  def code(:fcs_error), do: 1
  def code(:rx_error), do: 2
  def code(:runt), do: 3
  def code(:oversize), do: 4
  def user(st), do: code(st) * 2 + if(st == :ok, do: 0, else: 1)

  def step(s, word) do
    {tail, s} = take_tail(s)
    {s, ev} = word(s, word)
    if tail && ev.beat, do: raise("Rx64: two beats in one step")
    {s, %{ev | beat: tail || ev.beat}}
  end

  defp take_tail(%{tail: nil} = s), do: {nil, s}
  defp take_tail(%{tail: {d, keep, u}} = s), do: {{d, keep, true, u}, %{s | tail: nil}}

  defp ev(opts), do: Map.merge(%{sof: false, beat: nil, end: nil}, Map.new(opts))

  defp word(%{phase: :idle} = s, {d, c}) do
    if start?(d, c),
      do:
        {%{
           s
           | phase: :data,
             hv: false,
             k: 0,
             cnt: 0,
             crc: CRC32.init(),
             err: false,
             trunc: false
         }, ev(sof: true)},
      else: {s, ev([])}
  end

  defp word(%{phase: :data} = s, {d, c}) do
    m = first_ctl(c)
    term? = m < 8
    t? = term? and (d >>> (8 * m) &&& 0xFF) == 0xFD
    dm = d &&& (1 <<< (8 * m)) - 1
    k8 = 8 * s.k
    n = k8 + m
    cnt = min(s.cnt + m, s.max_len + 1)
    crc = if m > 0, do: CRC32.step_word(s.crc, dm, m), else: s.crc
    err = s.err or (term? and not t?)
    s = %{s | cnt: cnt, crc: crc, err: err}
    lim = s.max_len - 4

    cond do
      not term? and s.trunc ->
        {%{s | k: s.k + 1}, ev([])}

      not term? and lim <= k8 ->
        u = user(if err, do: :rx_error, else: :oversize)

        {%{s | trunc: true, hv: false, k: s.k + 1},
         ev(beat: {s.h &&& mask(lim - 8 * (s.k - 1)), keep(lim - 8 * (s.k - 1)), true, u})}

      not term? ->
        beat = if s.hv, do: {s.h, 0xFF, false, 0}
        {%{s | hv: true, h: d, k: s.k + 1}, ev(beat: beat)}

      s.trunc ->
        {%{s | phase: :idle, hv: false}, ev(end: status(s, cnt, crc, err))}

      true ->
        st = status(s, cnt, crc, err)
        u = user(st)
        f = (n - 4) |> min(lim) |> max(0)
        s2 = %{s | phase: :idle, hv: false}

        if f <= k8 do
          n_last = f - 8 * (s.k - 1)
          beat = if s.hv, do: {s.h &&& mask(n_last), keep(n_last), true, u}
          {s2, ev(end: st, beat: beat)}
        else
          beat = if s.hv, do: {s.h, 0xFF, false, 0}
          tail = {d &&& mask(f - k8), keep(f - k8), u}
          {%{s2 | tail: tail}, ev(end: st, beat: beat)}
        end
    end
  end

  defp status(s, cnt, crc, err) do
    cond do
      err -> :rx_error
      cnt < 64 -> :runt
      cnt > s.max_len -> :oversize
      crc != CRC32.residue() -> :fcs_error
      true -> :ok
    end
  end

  defp first_ctl(0), do: 8
  defp first_ctl(c), do: Enum.find(0..7, &((c >>> &1 &&& 1) == 1))

  defp mask(n), do: (1 <<< (8 * n)) - 1
  defp keep(n), do: (1 <<< n) - 1

  defp start?(d, c) do
    lane = fn i -> d >>> (8 * i) &&& 0xFF end
    ctl = fn i -> c >>> i &&& 1 end

    (c == 0x01 and lane.(0) == 0xFB and Enum.all?(1..6, &(lane.(&1) == 0x55)) and lane.(7) == 0xD5) or
      (ctl.(4) == 1 and c >>> 5 == 0 and lane.(4) == 0xFB and lane.(5) == 0x55 and
         lane.(6) == 0x55 and lane.(7) == 0xD5)
  end

  @doc """
  Runs `words` (plus one idle word to flush the last beat) and returns
  `{status, bytes}` per frame, in order.
  """
  def frames(words, opts \\ []) do
    idle = {0x0707070707070707, 0xFF}

    {_, _, acc, _} =
      Enum.reduce(words ++ [idle], {new(opts), <<>>, [], nil}, fn w, {s, cur, acc, pend} ->
        {s2, ev} = step(s, w)
        cur = add(cur, ev.beat)

        cond do
          ev.end && s2.tail == nil -> {s2, <<>>, [{ev.end, cur} | acc], nil}
          ev.end -> {s2, cur, acc, ev.end}
          pend -> {s2, <<>>, [{pend, cur} | acc], nil}
          true -> {s2, cur, acc, pend}
        end
      end)

    Enum.reverse(acc)
  end

  defp add(cur, nil), do: cur

  defp add(cur, {d, keep, _, _}) do
    n = ones(keep)
    cur <> <<d::little-size(8 * n)>>
  end

  defp ones(keep), do: for(i <- 0..7, reduce: 0, do: (a -> a + (keep >>> i &&& 1)))
end
