defmodule ExNet.NetTops do
  @moduledoc false
  # Small top levels for the datapath tests: sources -> TxPath -> MacTx (XGMII out).
  use ExHdl.RTL
  alias ExNet.RTL.{MacTx, TxPath}

  def tx_top(sources \\ 2) do
    module "net_tx_top_n#{sources}" do
      src_mac = input(:src_mac, 48)
      src_ip = input(:src_ip, 32)
      uc_mac = input(:uc_mac, 48)
      txd = output(:xgmii_txd, 64)
      txc = output(:xgmii_txc, 8)
      sof = output(:tx_sof, 1)
      tag = output(:tx_tag, 8)
      drop = output(:drop, sources)

      path_ins =
        for i <- 0..(sources - 1) do
          [
            {:"s#{i}_src_port", input(:"s#{i}_src_port", 16)},
            {:"s#{i}_ttl", input(:"s#{i}_ttl", 8)},
            {:"s#{i}_tos", input(:"s#{i}_tos", 8)},
            {:"s#{i}_tag", input(:"s#{i}_tag", 8)}
          ]
        end
        |> List.flatten()

      path =
        instance(:u_path, TxPath.build(sources: sources),
          connect: [src_mac: src_mac, src_ip: src_ip, uc_mac: uc_mac] ++ path_ins
        )

      mac = instance(:u_mac, MacTx.build(64))
      connect(path.m_axis, mac.s_axis)

      for i <- 0..(sources - 1) do
        s = slave(:"s#{i}_axis", ExNet.RTL.Ifc.udp_tx())
        connect(s, path[:"s#{i}_axis"])
        output(:"s#{i}_level", 10) <~ path[:"s#{i}_level"]
      end

      txd <~ mac.xgmii_txd
      txc <~ mac.xgmii_txc
      sof <~ mac.tx_sof
      tag <~ mac.tx_tag
      drop <~ path.drop
    end
  end
end
