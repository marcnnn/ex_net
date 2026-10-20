defmodule ExNet.RtlCase do
  @moduledoc false
  # Cycle-level harness for ExHdl.RTL modules: drive a module with one input map per
  # cycle (inputs not mentioned are 0, nothing is sticky), compare with a model, and
  # replay the recorded stimulus in Verilator against the BEAM simulator.
  alias ExHdl.RTL.{Cosim, Module, Sim}

  @reset_cycles 2

  @doc "Stimulus with the reset prefix and all data inputs defaulted to 0."
  def stimulus(mod, events) do
    zeros = Map.new(Module.data_inputs(mod), &{&1.name, 0})
    rst = for _ <- 1..@reset_cycles, do: Map.put(zeros, :rst_n, 0)
    rst ++ Enum.map(events, &(zeros |> Map.merge(Map.new(&1)) |> Map.put(:rst_n, 1)))
  end

  @doc "Runs `events` after reset; returns one output map per event (outputs sampled before the edge)."
  def run(mod, events) do
    {_, outs} = mod |> Sim.new() |> Sim.run(stimulus(mod, events))
    Enum.drop(outs, @reset_cycles)
  end

  @doc """
  Closed-loop run: `fun.(acc, i)` returns `{inputs, update}` where `update.(outputs)` gives
  the next acc. Returns `{events, outputs, acc}`; `events` can be replayed with `cosim!/2`.
  """
  def drive(mod, acc, n, fun) do
    zeros = Map.new(Module.data_inputs(mod), &{&1.name, 0})

    sim =
      Sim.new(mod) |> Sim.run(for _ <- 1..@reset_cycles, do: Map.put(zeros, :rst_n, 0)) |> elem(0)

    {rev, acc, _} =
      Enum.reduce(0..(n - 1)//1, {[], acc, sim}, fn i, {rows, acc, sim} ->
        {inputs, update} = fun.(acc, i)
        inputs = zeros |> Map.merge(Map.new(inputs)) |> Map.put(:rst_n, 1)
        sim = Sim.poke(sim, inputs)
        outs = Sim.outputs(sim)
        {[{inputs, outs} | rows], update.(outs), Sim.step(sim)}
      end)

    rows = Enum.reverse(rev)
    {Enum.map(rows, &elem(&1, 0)), Enum.map(rows, &elem(&1, 1)), acc}
  end

  @doc "BEAM simulator and Verilator agree on every output at every cycle of `events` (already full maps from `drive/4` or plain)."
  def cosim!(mod, events) do
    stim = stimulus(mod, events)
    Cosim.assert_equivalent(mod, stim)
  end
end
