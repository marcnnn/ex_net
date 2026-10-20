defmodule ExNet.RTL.Loopback do
  @moduledoc """
  Bring-up and test top levels: MAC TX, PCS TX, PCS RX and MAC RX in one module, the
  PCS transmit output wired to the PCS receive input.

    * `build(:gbe)`, module `net_loopback_1g`: `ExNet.RTL.MacTx` (8 bit), `pcs1000x_tx`,
      `pcs1000x_rx`, `ExNet.RTL.MacRx` (8 bit). Code groups travel as aligned 10-bit
      words (the receiver is also correct for any bit offset, see `ExNet.RTL.PCS1000X`).
    * `build(:xgbe)`, module `net_loopback_10g`: `mac_tx_64`, `pcs10gr_tx`, `pcs10gr_rx`
      (one block per cycle), `mac_rx_64`. While the PCS has no block lock the MAC receives
      idle words.

  Ports: slave `s_axis` (MAC TX stream: 8 bit with `tdata/tlast/tvalid/tready`, or
  64 bit with `tkeep`), master `m_axis` (MAC RX stream, `tuser` 4 bits, no `tready`),
  `sof_tx`, `sof_rx`, `frame_end`, `status` (MAC RX), `pcs_sync` (1G: code group sync; 10G:
  block lock), `pcs_dbg` (the remaining PCS status bits, 1G 34, 10G 1).

  Frames come out padded to 60 bytes with the FCS removed. The receiver needs its
  synchronisation first (1G: three commas, a few dozen idle groups; 10G: 64 valid headers),
  traffic sent earlier is lost. The idle code groups and blocks are sent from reset, so
  waiting about 100 cycles after reset is enough. Cycles from the first `s_axis_tvalid` of a frame
  (idle transmitter, frame of at least 16 bytes) to: `sof_tx` 8 (1G) or 1 (10G), `sof_rx` 14
  (1G) or 4 (10G), first `m_axis_tvalid` 20 (1G) or 6 (10G). After that the stream runs at the
  wire rate: 1G one byte per cycle, 10G one beat per cycle.
  """
  use ExHdl.RTL
  alias ExNet.RTL.{MacRx, MacTx, PCS10GR, PCS1000X}

  def build(:gbe) do
    module "net_loopback_1g" do
      s = slave(:s_axis, Interface.axi_stream(data: 8, keep: false))
      m = master(:m_axis, Interface.axi_stream(data: 8, keep: false, user: 4, ready: false))
      sof_tx = output(:sof_tx, 1)
      sof_rx = output(:sof_rx, 1)
      frame_end = output(:frame_end, 1)
      status = output(:status, 3)
      pcs_sync = output(:pcs_sync, 1)
      pcs_dbg = output(:pcs_dbg, 34)

      mtx = instance(:u_mac_tx, MacTx.build(8))
      connect(s, mtx.s_axis)

      ptx =
        instance(:u_pcs_tx, PCS1000X.build_tx(),
          connect: [
            txd: mtx.gmii_txd,
            tx_en: mtx.gmii_tx_en,
            tx_er: mtx.gmii_tx_er,
            tx_config: 0,
            tx_config_reg: 0
          ]
        )

      prx = instance(:u_pcs_rx, PCS1000X.build_rx(), connect: [rx_code10: ptx.code10])

      mrx =
        instance(:u_mac_rx, MacRx.build(8),
          connect: [gmii_rxd: prx.rxd, gmii_rx_dv: prx.rx_dv, gmii_rx_er: prx.rx_er]
        )

      connect(mrx.m_axis, m)
      sof_tx <~ mtx.sof
      sof_rx <~ mrx.sof
      frame_end <~ mrx.frame_end
      status <~ mrx.status
      pcs_sync <~ prx.sync

      dbg =
        cat([
          prx.config_valid,
          prx.idle_valid,
          prx.bad_valid,
          prx.config_reg,
          prx.shift,
          prx.dbg_state,
          prx.dbg_even,
          prx.dbg_good,
          prx.dbg_phase
        ])

      pcs_dbg <~ dbg
    end
  end

  def build(:xgbe) do
    module "net_loopback_10g" do
      s = slave(:s_axis, Interface.axi_stream(data: 64))
      m = master(:m_axis, Interface.axi_stream(data: 64, user: 4, ready: false))
      sof_tx = output(:sof_tx, 1)
      sof_rx = output(:sof_rx, 1)
      frame_end = output(:frame_end, 1)
      status = output(:status, 3)
      pcs_sync = output(:pcs_sync, 1)
      pcs_dbg = output(:pcs_dbg, 1)

      mtx = instance(:u_mac_tx, MacTx.build(64))
      connect(s, mtx.s_axis)

      ptx =
        instance(:u_pcs_tx, PCS10GR.tx(),
          connect: [data: mtx.xgmii_txd, ctl: mtx.xgmii_txc, en: const(1, 1)]
        )

      prx =
        instance(:u_pcs_rx, PCS10GR.rx(),
          connect: [rx_data: ptx.tx_data, rx_header: ptx.tx_header, en: ptx.tx_valid]
        )

      mrx =
        instance(:u_mac_rx, MacRx.build(64),
          connect: [
            xgmii_rxd: mux(prx.xgmii_valid, prx.xgmii_data, const(0x0707070707070707, 64)),
            xgmii_rxc: mux(prx.xgmii_valid, prx.xgmii_ctl, const(0xFF, 8))
          ]
        )

      connect(mrx.m_axis, m)
      sof_tx <~ mtx.sof
      sof_rx <~ mrx.sof
      frame_end <~ mrx.frame_end
      status <~ mrx.status
      pcs_sync <~ prx.lock
      pcs_dbg <~ (prx.out_valid and prx.rx_bitslip)
    end
  end
end
