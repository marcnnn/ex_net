defmodule ExNet.PCS1000XRef do
  @moduledoc """
  Reference model of the 1000BASE-X transmitter with configuration ordered
  sets, used by the `ExNet.RTL.PCS1000X` tests (`ExNet.PCS.Base1000X.Tx` has no
  `/C/` support and keeps its semantics; with `tx_config` false this model is
  `Tx` exactly).

  `step(state, {gmii, {tx_config, reg}})` returns `{state, code10}` for one cycle.
  A `/C/` set (`K28.5`, `D21.5` for `/C1/` or `D2.2` for `/C2/`, `reg` low byte,
  `reg` high byte; `/C1/` and `/C2/` alternate, `/C1/` first) starts when
  `tx_config` is set and `Tx` is on an ordered-set boundary (phase idle,
  first half); `reg` is sampled in the cycle of `K28.5`; a started set is
  always completed, and `Tx` is not stepped meanwhile (its GMII input is lost).
  """
  alias ExNet.PCS.Base1000X.Tx
  alias ExNet.PCS.Code8b10b, as: C

  defstruct tx: Tx.new(), pos: 0, c2: false, reg: 0

  def new, do: %__MODULE__{}

  def step(%{pos: 0, tx: %{phase: :idle, half: :k}} = s, {_gmii, {true, reg}}) do
    emit(%{s | pos: 1, reg: reg}, C.k(28, 5))
  end

  def step(%{pos: 1} = s, _), do: emit(%{s | pos: 2}, if(s.c2, do: C.d(2, 2), else: C.d(21, 5)))
  def step(%{pos: 2} = s, _), do: emit(%{s | pos: 3}, {:d, Bitwise.band(s.reg, 0xFF)})

  def step(%{pos: 3} = s, _),
    do: emit(%{s | pos: 0, c2: not s.c2}, {:d, Bitwise.bsr(s.reg, 8)})

  def step(s, {gmii, _}) do
    {tx, {code, _}} = Tx.step(s.tx, gmii)
    {%{s | tx: tx}, code}
  end

  defp emit(s, sym) do
    {code, rd} = C.encode(s.tx.rd, sym)
    {%{s | tx: %{s.tx | rd: rd}}, code}
  end

  @doc "Runs `{gmii, {tx_config?, reg}}` cycles; returns the code groups."
  def run(inputs) do
    {_, rev} =
      Enum.reduce(inputs, {new(), []}, fn i, {s, acc} ->
        {s, c} = step(s, i)
        {s, [c | acc]}
      end)

    Enum.reverse(rev)
  end
end
