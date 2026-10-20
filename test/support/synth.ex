defmodule ExNet.Synth do
  @moduledoc false
  # Yosys synth_xilinx with -flatten (ExHdl.Synth.Yosys does not flatten, which undercounts
  # hierarchical designs). UltraScale+ (XCKU3P) by default.
  alias ExHdl.Backends.SystemVerilog.RTL, as: SV

  def utilization(mod, family \\ "xcup") do
    tmp = Path.join(System.tmp_dir!(), "exnet_yosys_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      files =
        for {name, src} <- Enum.sort(SV.generate(mod)) do
          path = Path.join(tmp, name)
          File.write!(path, src)
          path
        end

      stat = Path.join(tmp, "stat.json")

      script =
        "read_verilog -sv #{Enum.join(files, " ")}; " <>
          "synth_xilinx -flatten -family #{family} -noiopad -top #{mod.name}; " <>
          "tee -q -o #{stat} stat -json"

      case System.cmd(System.find_executable("yosys"), ["-q", "-p", script],
             stderr_to_stdout: true
           ) do
        {_, 0} -> {:ok, summarize(stat |> File.read!() |> JSON.decode!())}
        {log, status} -> {:error, "yosys exited with #{status}:\n#{log}"}
      end
    after
      File.rm_rf!(tmp)
    end
  end

  defp summarize(%{"design" => %{"num_cells_by_type" => cells}}) do
    count = fn pred ->
      cells |> Enum.filter(fn {t, _} -> pred.(t) end) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    end

    %{
      lut: count.(&String.match?(&1, ~r/^LUT\d$/)),
      ff: count.(&String.match?(&1, ~r/^FD[A-Z]*$/)),
      carry: count.(&(&1 in ["CARRY4", "CARRY8"])),
      bram18:
        count.(&(&1 in ["RAMB18E2", "RAMB18E1"])) + 2 * count.(&(&1 in ["RAMB36E2", "RAMB36E1"])),
      dsp: count.(&String.starts_with?(&1, "DSP48")),
      muxf: count.(&String.starts_with?(&1, "MUXF")),
      lutram: count.(&String.match?(&1, ~r/^RAM\d+[MX]/)),
      srl: count.(&String.starts_with?(&1, "SRL"))
    }
  end
end
