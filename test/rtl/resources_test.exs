defmodule ExNet.RTL.ResourcesTest do
  @moduledoc """
  Yosys `synth_xilinx` (UltraScale+, flattened, no I/O buffers) size of every RTL design,
  with upper bounds about 25 % above the numbers in the README; a failure means the
  logic got bigger. Slow (minutes), so excluded by default: `mix test --include resources`.
  """
  use ExUnit.Case, async: true

  alias ExNet.RTL.{
    AutoNeg,
    Classifier,
    CRC32,
    Loopback,
    MacRx,
    MacTx,
    PCS10GR,
    PCS1000X,
    RxPath,
    TxPath,
    UdpRx,
    UdpTx
  }

  alias ExNet.Synth

  @moduletag :resources
  @moduletag :yosys
  @moduletag timeout: 1_200_000

  # {name, {module, function, args}, max LUT, max FF, max BRAM18}
  @designs [
    {"crc32_8", {CRC32, :build, [1]}, 130, 40, 1},
    {"crc32_64", {CRC32, :build, [8]}, 1980, 40, 1},
    {"mac_tx_8", {MacTx, :build, [8]}, 210, 75, 1},
    {"mac_rx_8", {MacRx, :build, [8]}, 180, 135, 1},
    {"mac_tx_64", {MacTx, :build, [64]}, 2550, 240, 1},
    {"mac_rx_64", {MacRx, :build, [64]}, 2400, 350, 1},
    {"pcs1000x_tx", {PCS1000X, :build_tx, []}, 120, 50, 1},
    {"pcs1000x_rx", {PCS1000X, :build_rx, []}, 190, 92, 1},
    {"pcs1000x", {PCS1000X, :build, [10, 1]}, 410, 215, 1},
    {"autoneg", {AutoNeg, :build, [10]}, 160, 75, 1},
    {"pcs10gr_tx", {PCS10GR, :tx, []}, 680, 160, 1},
    {"pcs10gr_rx", {PCS10GR, :rx, []}, 690, 185, 1},
    {"rxcls_n16", {Classifier, :build, []}, 4900, 6200, 1},
    {"net_loopback_1g", {Loopback, :build, [:gbe]}, 640, 330, 1},
    {"net_loopback_10g", {Loopback, :build, [:xgbe]}, 6200, 930, 1},
    {"udp_rx_d512", {UdpRx, :build, []}, 540, 380, 5},
    {"udp_tx", {UdpTx, :build, []}, 520, 100, 0},
    {"tx_path_n2", {TxPath, :build, []}, 1300, 290, 6},
    {"rx_path_n16", {RxPath, :build, []}, 7900, 7000, 5}
  ]

  for {name, {m, f, a}, lut, ff, bram} <- @designs do
    test "#{name} synthesises within budget" do
      {:ok, u} = Synth.utilization(apply(unquote(m), unquote(f), unquote(a)))

      IO.puts(
        "#{unquote(name)}: lut #{u.lut} ff #{u.ff} carry #{u.carry} bram18 #{u.bram18} srl #{u.srl}"
      )

      assert u.lut <= unquote(lut), "LUT #{u.lut}"
      assert u.ff <= unquote(ff), "FF #{u.ff}"
      assert u.dsp == 0 and u.bram18 <= unquote(bram)
    end
  end
end
