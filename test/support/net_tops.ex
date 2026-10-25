defmodule ExNet.NetTops do
  @moduledoc false
  # Small top levels for the datapath tests: sources -> TxPath -> MacTx (XGMII out).
  use ExHdl.RTL
  alias ExNet.RTL.{Classifier, Igmp, MacRx, MacTx, TxPath}

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

  @doc """
  The wiring of the card for IGMP: XGMII in, `MacRx`, `Classifier`, `Igmp` (frame stream in), and
  `Igmp` as the raw source of `TxPath` next to one UDP source, `MacTx`, XGMII out.
  """
  def igmp_top(opts \\ []) do
    ig = Igmp.build(Keyword.put_new(opts, :hit_bits, Classifier.hit_width(4)))

    module "net_igmp_top" do
      rxd = input(:xgmii_rxd, 64)
      rxc = input(:xgmii_rxc, 8)

      cfg =
        for {n, w} <- [
              src_mac: 48,
              src_ip: 32,
              v2_only: 1,
              robustness: 3,
              unsol_ms: 16,
              cmd_valid: 1,
              cmd_leave: 1,
              cmd_group: 32,
              rd_idx: 2
            ],
            into: %{},
            do: {n, input(n, w)}

      udp_cfg =
        for {n, w} <- [uc_mac: 48, s0_src_port: 16, s0_ttl: 8, s0_tos: 8, s0_tag: 8],
            into: %{},
            do: {n, input(n, w)}

      txd = output(:xgmii_txd, 64)
      txc = output(:xgmii_txc, 8)
      tx_sof = output(:tx_sof, 1)
      dbg = output(:dbg, 8)

      outs =
        for {n, w} <- [
              cmd_ready: 1,
              cmd_done: 1,
              cmd_err: 1,
              member: 4,
              joined: 3,
              rd_group: 32,
              rd_member: 1,
              mode_v2: 1,
              tx_done: 1,
              rx_missed: 1
            ],
            into: %{},
            do: {n, output(n, w)}

      mac = instance(:u_mac_rx, MacRx.build(64), connect: [xgmii_rxd: rxd, xgmii_rxc: rxc])

      cls =
        instance(:u_cls, Classifier.build(entries: 4, stream_bits: 4, slots: 4),
          connect: [cfg_we: const(0, 1), cfg_addr: const(0, 6), cfg_data: const(0, 32)]
        )

      connect(mac.m_axis, cls.s)
      g = instance(:u_igmp, ig, connect: Map.to_list(cfg))
      connect(cls.m, g.s)

      path =
        instance(:u_path, TxPath.build(sources: 1, raw: 1, depth: 64),
          connect: [src_mac: cfg.src_mac, src_ip: cfg.src_ip] ++ Map.to_list(udp_cfg)
        )

      connect(g.m_axis, path.r0_axis)
      s0 = slave(:s0_axis, ExNet.RTL.Ifc.udp_tx())
      connect(s0, path.s0_axis)
      txmac = instance(:u_mac_tx, MacTx.build(64))
      connect(path.m_axis, txmac.s_axis)

      for {n, o} <- outs, do: o <~ g[n]
      txd <~ txmac.xgmii_txd
      txc <~ txmac.xgmii_txc
      tx_sof <~ txmac.tx_sof
      output(:tx_tag, 8) <~ txmac.tx_tag

      dbg
      <~ cat([
        cls.ovf,
        mac.rx_sof,
        mac.frame_end,
        mac.status,
        path.drop[0] or path.drop[1]
      ])

      output(:levels, 14) <~ cat([path.s0_level, path.r0_level])
    end
  end
end
