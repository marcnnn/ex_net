defmodule ExNet.RTL.PCS10GR do
  @moduledoc """
  10GBASE-R PCS datapath in hardware: `tx/0`, `rx/0` and the combined `pcs/0`,
  cycle-equivalent to `ExNet.PCS.Base10GR.tx_step/2` and `rx_step/2` with one
  cycle of latency and one block per cycle.

  ## Module `pcs10gr_tx`

  Inputs `data` (64), `ctl` (8) (XGMII word, lane `i` in bits `8i+7..8i`, `ctl`
  bit `i` marks a control character), `en`. All outputs are registers:
  `tx_valid` (1), `tx_data` (64, scrambled payload, bit 0 first), `tx_header`
  (2, sync header, bit 0 first: 1 = `01` data, 2 = `10` control). With `en` in
  cycle `i`, cycle `i + 1` shows `tx_valid = 1` and the block
  `Base10GR.tx_step` gives for the word of cycle `i`; without `en` the
  scrambler holds and the cycle shows `tx_valid = 0`, data and header 0. Reset
  values 0, scrambler seeded with all ones.

  ## Module `pcs10gr_rx`

  Inputs `rx_data` (64), `rx_header` (2), `en` (the gearbox presents a valid
  block this cycle). Outputs, all registers: `out_valid` (= `en` of the previous
  cycle), `lock` (block lock after the previous block), `rx_bitslip` (one
  cycle pulse request to the gearbox), `xgmii_valid` (1 only when the previous
  cycle had `en` and the lock state machine was locked after that block, like
  `xgmii != nil` in `Base10GR.rx_step`), `xgmii_data` (64), `xgmii_ctl` (8), both
  0 while `xgmii_valid = 0`. A locked block with a bad header or block type gives
  the all-error word. Descrambler state holds without `en`.

  ## Module `pcs10gr`

  Both side by side: `tx_xgmii_data`, `tx_xgmii_ctl`, `tx_en` in; `tx_data`,
  `tx_header`, `tx_valid` out; `rx_data`, `rx_header`, `rx_en` in; `rx_lock`,
  `rx_bitslip`, `rx_out_valid`, `rx_xgmii_valid`, `rx_xgmii_data`, `rx_xgmii_ctl` out.

  ## Gearbox adaptation (Xilinx GTY 64b/66b, black box not included)

  The cores take one block per clock-enabled cycle. The transceiver gearbox
  needs `en` tied to its data strobe: TX `txsequence` (a 32-cycle counter, the
  66-to-64 gearbox skips one word in 33, so `en` is low then; `tx_data` goes to
  `txdata`, `tx_header[1:0]` to `txheader`), RX `rxdatavalid & rxheadervalid`
  (`rx_data` from `rxdata`, `rx_header` from `rxheader`). `rx_bitslip` goes to
  `rxgearboxslip`; the transceiver wants slip pulses at least ~64 cycles apart
  (the model slips on every invalid header while unlocked) so the black box
  wrapper should hold off new slips for that time and ignore `rx_header`
  blocks while a slip settles. The `en` gating means all XGMII-side words must
  come at the same enable, so a FIFO or the `txusrclk` / `en` divide is the
  wrapper's job.
  """
  use ExHdl.RTL

  alias ExNet.RTL.{Block66, BlockLock, Scrambler}

  @doc "Transmit side `pcs10gr_tx`."
  def tx do
    module "pcs10gr_tx" do
      data = input(:data, 64)
      ctl = input(:ctl, 8)
      en = input(:en, 1)
      tx_valid = output(:tx_valid, 1, reset: 0)
      tx_data = output(:tx_data, 64, reset: 0)
      tx_header = output(:tx_header, 2, reset: 0)
      enc = instance(:enc, Block66.encoder(), connect: [data: data, ctl: ctl])
      scr = instance(:scr, Scrambler.build(:scramble), connect: [data: enc.payload, en: en])

      sync do
        tx_valid <~ en
        tx_data <~ mux(en, scr.out, const(0, 64))
        tx_header <~ mux(en, enc.hdr, const(0, 2))
      end
    end
  end

  @doc "Receive side `pcs10gr_rx`."
  def rx do
    module "pcs10gr_rx" do
      rx_data = input(:rx_data, 64)
      rx_header = input(:rx_header, 2)
      en = input(:en, 1)
      out_valid = output(:out_valid, 1, reset: 0)
      lock = output(:lock, 1, reset: 0)
      bitslip = output(:rx_bitslip, 1, reset: 0)
      xvalid = output(:xgmii_valid, 1, reset: 0)
      xdata = output(:xgmii_data, 64, reset: 0)
      xctl = output(:xgmii_ctl, 8, reset: 0)
      bl = instance(:bl, BlockLock.build(), connect: [sh: rx_header, valid: en])
      ds = instance(:ds, Scrambler.build(:descramble), connect: [data: rx_data, en: en])
      dec = instance(:dec, Block66.decoder(), connect: [hdr: rx_header, payload: ds.out])
      ok = wire(:ok, en and bl.lock)

      sync do
        out_valid <~ en
        lock <~ bl.lock
        bitslip <~ bl.slip
        xvalid <~ ok
        xdata <~ mux(ok, dec.data, const(0, 64))
        xctl <~ mux(ok, dec.ctl, const(0, 8))
      end
    end
  end

  @doc "Both directions, `pcs10gr`."
  def pcs do
    module "pcs10gr" do
      txd = input(:tx_xgmii_data, 64)
      txc = input(:tx_xgmii_ctl, 8)
      txe = input(:tx_en, 1)
      rd = input(:rx_data, 64)
      rh = input(:rx_header, 2)
      re = input(:rx_en, 1)
      o_td = output(:tx_data, 64)
      o_th = output(:tx_header, 2)
      o_tv = output(:tx_valid, 1)
      o_lock = output(:rx_lock, 1)
      o_slip = output(:rx_bitslip, 1)
      o_ov = output(:rx_out_valid, 1)
      o_xv = output(:rx_xgmii_valid, 1)
      o_xd = output(:rx_xgmii_data, 64)
      o_xc = output(:rx_xgmii_ctl, 8)
      t = instance(:u_tx, tx(), connect: [data: txd, ctl: txc, en: txe])
      r = instance(:u_rx, rx(), connect: [rx_data: rd, rx_header: rh, en: re])
      o_td <~ t.tx_data
      o_th <~ t.tx_header
      o_tv <~ t.tx_valid
      o_lock <~ r.lock
      o_slip <~ r.rx_bitslip
      o_ov <~ r.out_valid
      o_xv <~ r.xgmii_valid
      o_xd <~ r.xgmii_data
      o_xc <~ r.xgmii_ctl
    end
  end
end
