defmodule ExNet.RTL.RxPath do
  @moduledoc """
  Receive datapath on one clock: `ExNet.RTL.MacRx` (64 bit XGMII) into
  `ExNet.RTL.Classifier` into `ExNet.RTL.UdpRx`.

  Ports: `xgmii_rxd`, `xgmii_rxc` in; the table write port `cfg_we`, `cfg_addr`, `cfg_data`
  of the classifier; `rx_sof` (timestamp strobe, `ExNet.RTL.Ifc.ts_rx/0`, 1 cycle after the
  Start word) and `frame_end`, `status` of the MAC; the classified frame stream `frame_*`
  (`ExNet.RTL.Ifc.rx_frame/3`: every frame, 14 cycles behind the MAC beats, metadata,
  no `tready`) for the host path and the PTP timestamp stage; `m_axis_*`
  (`ExNet.RTL.Ifc.udp_rx/0`) with the UDP payloads of the frames the table steers to a stream
  engine; the counters' pulses `ovf` (classifier queue), `drop_bad`, `drop_full`, `level`
  of `UdpRx`, and `dbg` (always 0).

  Timing, MAC pins to `rx_sof`: 1 cycle; `rx_sof` to `frame_sof`: the first stream beat of
  the frame leaves the MAC about 2 cycles after `rx_sof`, the classifier adds 14. So the
  first `frame_*` beat is at least 15 cycles after `rx_sof`, which is longer than the
  `ExPtp.RTL.TimestampUnit` needs to have the timestamp ready (`ExPtp.RTL.RxStamp` does not
  stall the frame stream).

  Options: `entries:` (classifier table size, 16), `stream_bits:` (4), `depth:` (UdpRx FIFO
  beats, 512), `slots:` (4).
  """
  use ExHdl.RTL
  alias ExNet.RTL.{Classifier, Ifc, MacRx, UdpRx}

  def build(opts \\ []) do
    n = Keyword.get(opts, :entries, 16)
    sb = Keyword.get(opts, :stream_bits, 4)
    depth = Keyword.get(opts, :depth, 512)
    slots = Keyword.get(opts, :slots, 4)
    hw = Classifier.hit_width(n)
    aw = Classifier.addr_width(n)

    module "rx_path_n#{n}_s#{sb}_d#{depth}_r#{slots}" do
      rxd = input(:xgmii_rxd, 64)
      rxc = input(:xgmii_rxc, 8)
      cfg_we = input(:cfg_we, 1)
      cfg_addr = input(:cfg_addr, aw)
      cfg_data = input(:cfg_data, 32)
      rx = master(:rx, Ifc.ts_rx())
      frame = master(:frame, Ifc.rx_frame(sb, hw))
      m = master(:m_axis, Ifc.udp_rx())
      frame_end = output(:frame_end, 1)
      status = output(:status, 3)
      ovf = output(:ovf, 1)
      drop_bad = output(:drop_bad, 1)
      drop_full = output(:drop_full, 1)
      level = output(:level, ExHdl.RTL.Builder.ceil_log2(depth) + 1)
      dbg = output(:dbg, 2)

      mac = instance(:u_mac, MacRx.build(64), connect: [xgmii_rxd: rxd, xgmii_rxc: rxc])

      cls =
        instance(:u_cls, Classifier.build(entries: n, stream_bits: sb, slots: slots),
          connect: [cfg_we: cfg_we, cfg_addr: cfg_addr, cfg_data: cfg_data]
        )

      udp =
        instance(:u_udp, UdpRx.build(stream_bits: sb, hit_bits: hw, depth: depth))

      connect(mac.m_axis, cls.s)
      connect(cls.m, udp.s)
      connect(cls.m, frame)
      connect(udp.m_axis, m)
      rx.sof <~ mac.rx_sof
      frame_end <~ mac.frame_end
      status <~ mac.status
      ovf <~ cls.ovf
      drop_bad <~ udp.drop_bad
      drop_full <~ udp.drop_full
      level <~ udp.level
      dbg <~ udp.dbg
    end
  end
end
