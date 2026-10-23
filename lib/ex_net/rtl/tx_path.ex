defmodule ExNet.RTL.TxPath do
  @moduledoc """
  Transmit datapath up to the MAC: `n` UDP sources (`ExNet.RTL.Ifc.udp_tx/0`), each through
  `ExNet.RTL.UdpTx` and a store-and-forward packet FIFO (`ExHdlCores.FIFO.packet/1`), merged
  packet by packet (`ExHdlCores.AXIS.merge/2`, round robin) into one stream
  (`ExNet.RTL.Ifc.mac_tx/1`) that obeys the MAC contract: once the first beat of a frame is
  offered the following beats follow without a gap whenever `m_axis_tready` is high, because
  a FIFO only releases complete frames. Put `ExPtp.RTL.TxInsert` and `ExNet.RTL.MacTx` behind it.

  Ports: `s<i>_axis_*` (UDP payload source `i`), `m_axis_*` (MAC stream), shared `src_mac`,
  `src_ip`, `uc_mac`, and per source `s<i>_src_port`, `s<i>_ttl`, `s<i>_tos`, `s<i>_tag`
  (see `UdpTx`; the tag reaches `MacTx` in the `tuser` of the first beat), `drop`
  (a bit per FIFO: pulses when it dropped a frame, always 0 here), and `s<i>_level` (FIFO fill in beats).

  The FIFO stalls its source when full (`drop_on_full: false`), so a frame never has to be
  dropped; a frame larger than `depth` beats (default 512, 4 KB) would block, which the
  Ethernet MTU rules out.

  Options: `sources:` (2), `depth:` (512), `style:` (`:block`).
  """
  use ExHdl.RTL
  alias ExHdlCores.{AXIS, FIFO}
  alias ExNet.RTL.{Ifc, UdpTx}

  def build(opts \\ []) do
    n = Keyword.get(opts, :sources, 2)
    depth = Keyword.get(opts, :depth, 512)
    style = Keyword.get(opts, :style, :block)
    aw = ExHdl.RTL.Builder.ceil_log2(depth) + 1
    fifo = FIFO.packet(data: 64, user: 8, depth: depth, style: style, drop_on_full: false)
    merge = AXIS.merge(n, data: 64, user: 8)

    module "tx_path_n#{n}_d#{depth}_#{style}" do
      src_mac = input(:src_mac, 48)
      src_ip = input(:src_ip, 32)
      uc_mac = input(:uc_mac, 48)
      m = master(:m_axis, Ifc.mac_tx(64))
      drop = output(:drop, n)
      mg = instance(:u_merge, merge)

      drops =
        for i <- 0..(n - 1) do
          s = slave(:"s#{i}_axis", Ifc.udp_tx())

          tx =
            instance(:"u_tx#{i}", UdpTx.build(),
              connect: [
                src_mac: src_mac,
                src_ip: src_ip,
                uc_mac: uc_mac,
                src_port: input(:"s#{i}_src_port", 16),
                ttl: input(:"s#{i}_ttl", 8),
                tos: input(:"s#{i}_tos", 8),
                tag: input(:"s#{i}_tag", 8)
              ]
            )

          f = instance(:"u_fifo#{i}", fifo)
          connect(s, tx.s_axis)
          connect(tx.m_axis, f.s_axis)
          connect(f.m_axis, mg[:"s#{i}_axis"])
          output(:"s#{i}_level", aw) <~ f.level
          f.drop_bad or f.drop_full
        end

      connect(mg.m_axis, m)
      drop <~ cat(Enum.reverse(drops))
    end
  end
end
