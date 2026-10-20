defmodule ExNet.PCS.Base1000X do
  @moduledoc """
  1000BASE-X PCS (Clause 36) as code-group step functions: one GMII cycle in,
  one 10-bit code group out, and the reverse.

  Ordered sets: `/I/` (`K28.5` + `D5.6` or `D16.2`, alternating by running
  disparity: `/I1/` after RD+, `/I2/` after RD-), `/C1/` and `/C2/`
  (`K28.5` + `D21.5` or `D2.2`, then two config bytes, low byte first),
  `/S/` K27.7, `/T/` K29.7, `/R/` K23.7, `/V/` K30.7 (error propagation).

  Model choices, none of which the hardware may deviate from silently:

    * the first preamble byte is replaced by `/S/`; if a frame starts while
      the second half of an idle set is on the wire, that half is sent
      first and the GMII byte of that cycle is dropped (the preamble is
      redundant, the idle set stays whole)
    * after `/T/` come `/R/` and, if needed, a second `/R/` so the next idle
      set starts on an even code group
    * the bit-level comma alignment is the serdes' job; `Sync` works on
      aligned code groups

  `tx_run/1` and `rx_run/1` wrap the step functions for whole streams.

      iex> alias ExNet.PCS.Base1000X, as: P
      iex> frame = :binary.copy(<<7>>, 60)
      iex> gmii = List.duplicate({0, false, false}, 20) ++ ExNet.MAC.tx_cycles([frame])
      iex> out = gmii |> P.tx_run() |> P.rx_run() |> Enum.map(& &1.gmii)
      iex> ExNet.MAC.rx_frames(out)
      [{:ok, frame}]
  """
  alias ExNet.PCS.Code8b10b, as: C

  @s C.k(27, 7)
  @t C.k(29, 7)
  @r C.k(23, 7)
  @v C.k(30, 7)
  @comma C.k(28, 5)

  def ordered_set_symbols, do: %{s: @s, t: @t, r: @r, v: @v, comma: @comma}

  defmodule Tx do
    @moduledoc "Transmit: `step(state, {data, en, er}) -> {state, {code10, symbol}}`."
    alias ExNet.PCS.Code8b10b, as: C
    defstruct rd: :neg, phase: :idle, half: :k, count: 0, queue: []

    @doc "Initial state, running disparity negative (as after reset)."
    def new(rd \\ :neg), do: %__MODULE__{rd: rd}

    @i1 C.d(5, 6)
    @i2 C.d(16, 2)

    def step(%{phase: :idle, half: :k} = s, {_, true, _}),
      do: emit(%{s | phase: :frame, count: 1}, C.k(27, 7))

    def step(%{phase: :idle, half: :k} = s, _) do
      d = if s.rd == :pos, do: @i1, else: @i2
      emit(%{s | half: {:d, d}}, C.k(28, 5))
    end

    def step(%{phase: :idle, half: {:d, d}} = s, _), do: emit(%{s | half: :k}, d)

    def step(%{phase: :frame} = s, {_, true, true}),
      do: emit(%{s | count: s.count + 1}, C.k(30, 7))

    def step(%{phase: :frame} = s, {b, true, _}), do: emit(%{s | count: s.count + 1}, {:d, b})

    def step(%{phase: :frame} = s, _) do
      n = s.count + 1
      rs = if rem(n + 1, 2) == 1, do: 2, else: 1
      emit(%{s | phase: :epilog, queue: List.duplicate(C.k(23, 7), rs)}, C.k(29, 7))
    end

    def step(%{phase: :epilog, queue: [r | rest]} = s, _) do
      emit(%{s | queue: rest, phase: if(rest == [], do: :idle, else: :epilog), half: :k}, r)
    end

    defp emit(s, sym) do
      {code, rd} = C.encode(s.rd, sym)
      {%{s | rd: rd}, {code, sym}}
    end
  end

  defmodule Sync do
    @moduledoc """
    Code group synchronisation (Clause 36 Figure 36-9) on aligned groups.
    `step(state, class)` with class `:comma | :data | :invalid`.
    Sync is acquired after three commas, each separated by valid data groups;
    in the acquired states, an invalid group moves down a level and four good
    groups move back up; at the lowest level another invalid group loses sync.
    """
    defstruct st: :loss_of_sync, even: false, good: 0

    def new, do: %__MODULE__{}
    def in_sync?(%__MODULE__{st: st}), do: st in acquired()

    defp acquired,
      do: [
        :sync_acquired_1,
        :sync_acquired_2,
        :sync_acquired_2a,
        :sync_acquired_3,
        :sync_acquired_3a,
        :sync_acquired_4,
        :sync_acquired_4a
      ]

    def step(%{st: :loss_of_sync} = s, :comma), do: %{s | st: :comma_detect_1, even: true}
    def step(%{st: :loss_of_sync} = s, _), do: %{s | even: not s.even}

    for {cd, next} <- [
          comma_detect_1: :acquire_sync_1,
          comma_detect_2: :acquire_sync_2,
          comma_detect_3: :sync_acquired_1
        ] do
      def step(%{st: unquote(cd)} = s, :data), do: %{s | st: unquote(next), even: not s.even}
      def step(%{st: unquote(cd)} = s, _), do: %{s | st: :loss_of_sync, even: not s.even}
    end

    for {as, cd} <- [acquire_sync_1: :comma_detect_2, acquire_sync_2: :comma_detect_3] do
      def step(%{st: unquote(as), even: false} = s, :comma),
        do: %{s | st: unquote(cd), even: true}

      def step(%{st: unquote(as)} = s, :invalid), do: %{s | st: :loss_of_sync, even: not s.even}
      def step(%{st: unquote(as)} = s, _), do: %{s | even: not s.even}
    end

    # level n: invalid goes to level n+1 (or loss), a good group enters the "a" state
    for {n, down} <- [
          {1, :sync_acquired_2},
          {2, :sync_acquired_3},
          {3, :sync_acquired_4},
          {4, :loss_of_sync}
        ] do
      lvl = :"sync_acquired_#{n}"
      lvla = :"sync_acquired_#{n}a"
      up = if n == 1, do: :sync_acquired_1, else: :"sync_acquired_#{n - 1}"

      if n == 1 do
        def step(%{st: :sync_acquired_1} = s, :invalid),
          do: %{s | st: unquote(down), even: not s.even}

        def step(%{st: :sync_acquired_1} = s, _), do: %{s | even: not s.even}
      else
        def step(%{st: unquote(lvl)} = s, :invalid),
          do: %{s | st: unquote(down), even: not s.even}

        def step(%{st: unquote(lvl)} = s, _),
          do: %{s | st: unquote(lvla), good: 1, even: not s.even}

        def step(%{st: unquote(lvla)} = s, :invalid),
          do: %{s | st: unquote(down), even: not s.even}

        def step(%{st: unquote(lvla), good: 3} = s, _),
          do: %{s | st: unquote(up), even: not s.even}

        def step(%{st: unquote(lvla)} = s, _), do: %{s | good: s.good + 1, even: not s.even}
      end
    end
  end

  defmodule Rx do
    @moduledoc """
    Receive: `step(state, code10) -> {state, out}` with
    `out = %{gmii: {data, dv, er}, config: reg | nil, sync: boolean, symbol: sym | nil}`.

    While not in sync the GMII side is idle. `/S/` starts a frame with 0x55,
    data groups pass through, `/T/` ends it, any other control group or code
    violation inside a frame raises `er` (and a stray comma ends the frame).
    A completed `/C/` ordered set is reported once in `config` (the 16 bit
    register, low byte first on the wire).
    """
    alias ExNet.PCS.Base1000X.Sync
    alias ExNet.PCS.Code8b10b, as: C
    defstruct rd: :neg, sync: %Sync{}, phase: :idle, lo: 0

    def new(rd \\ :neg), do: %__MODULE__{rd: rd}

    def step(s, code) do
      {sym, rd} =
        case C.decode(s.rd, code) do
          {:ok, sym, rd} -> {sym, rd}
          {:error, _, rd} -> {:invalid, rd}
        end

      class =
        case sym do
          {:k, b} when b in [0xBC, 0x3C, 0xFC] -> :comma
          :invalid -> :invalid
          _ -> :data
        end

      sync = Sync.step(s.sync, class)
      s = %{s | rd: rd, sync: sync}

      if Sync.in_sync?(sync) do
        {s, gmii, cfg} = symbol(s, sym)
        {s, %{gmii: gmii, config: cfg, sync: true, symbol: sym}}
      else
        {%{s | phase: :idle}, %{gmii: {0, false, false}, config: nil, sync: false, symbol: sym}}
      end
    end

    @idle {0, false, false}
    @err {0, true, true}
    @i_d [0xC5, 0x50]
    @c_d [0xB5, 0x42]

    defp symbol(%{phase: :idle} = s, {:k, 0xFB}),
      do: {%{s | phase: :frame}, {0x55, true, false}, nil}

    defp symbol(%{phase: :idle} = s, {:k, 0xBC}), do: {%{s | phase: :ord1}, @idle, nil}
    defp symbol(%{phase: :idle} = s, _), do: {s, @idle, nil}

    defp symbol(%{phase: :ord1} = s, {:d, b}) when b in @i_d,
      do: {%{s | phase: :idle}, @idle, nil}

    defp symbol(%{phase: :ord1} = s, {:d, b}) when b in @c_d,
      do: {%{s | phase: :cfg_lo}, @idle, nil}

    defp symbol(%{phase: :ord1} = s, sym), do: symbol(%{s | phase: :idle}, sym)

    defp symbol(%{phase: :cfg_lo} = s, {:d, b}), do: {%{s | phase: :cfg_hi, lo: b}, @idle, nil}
    defp symbol(%{phase: :cfg_lo} = s, sym), do: symbol(%{s | phase: :idle}, sym)
    defp symbol(%{phase: :cfg_hi} = s, {:d, b}), do: {%{s | phase: :idle}, @idle, s.lo + b * 256}
    defp symbol(%{phase: :cfg_hi} = s, sym), do: symbol(%{s | phase: :idle}, sym)

    defp symbol(%{phase: :frame} = s, {:d, b}), do: {s, {b, true, false}, nil}
    defp symbol(%{phase: :frame} = s, {:k, 0xFD}), do: {%{s | phase: :after_t}, @idle, nil}
    defp symbol(%{phase: :frame} = s, {:k, 0xBC}), do: {%{s | phase: :ord1}, @err, nil}
    defp symbol(%{phase: :frame} = s, _), do: {s, @err, nil}

    defp symbol(%{phase: :after_t} = s, {:k, 0xF7}), do: {s, @idle, nil}
    defp symbol(%{phase: :after_t} = s, sym), do: symbol(%{s | phase: :idle}, sym)
  end

  @doc "Runs GMII cycles through `Tx`; returns the 10-bit code groups."
  def tx_run(gmii) do
    {_, codes} =
      Enum.reduce(gmii, {Tx.new(), []}, fn c, {s, acc} ->
        {s, {code, _}} = Tx.step(s, c)
        {s, [code | acc]}
      end)

    Enum.reverse(codes)
  end

  @doc """
  Runs code groups through `Rx`; returns the per-group `out` maps. Prepend
  idle sets so `Sync` acquires first (`tx_run/1` output of a leading idle
  stream does that).
  """
  def rx_run(codes) do
    {_, outs} =
      Enum.reduce(codes, {Rx.new(), []}, fn c, {s, acc} ->
        {s, o} = Rx.step(s, c)
        {s, [o | acc]}
      end)

    Enum.reverse(outs)
  end
end
