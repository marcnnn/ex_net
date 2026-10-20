# ExNet

Ethernet for ExHdl designs: the hardware datapath and the matching BEAM
codecs come from the same packet definitions.

## Status

BEAM side done: packet codecs and bit-exact reference models. Hardware done as
`ExHdl.RTL` modules, each checked cycle by cycle against those models in the BEAM
simulator and in Verilator (random stimulus); gearbox and transceiver black boxes
(ex_hdl_xilinx), FIFOs (ex_hdl_cores) and the NIC top level are not written yet.

| Layer | Module | Hardware | State |
|---|---|---|---|
| Packets | `ExNet.Ethernet`, `IPv4`, `UDP`, `IGMP`, `ARP`, `Packets` | | codecs done; fixed headers use `defpacket` |
| FCS | `ExNet.CRC32` | `ExNet.RTL.CRC32` | 8 and 64 bit with `tkeep` |
| MAC | `ExNet.MAC`, `MAC.Tx`, `MAC.Rx`, `MAC.Tx64`, `MAC.Rx64` | `ExNet.RTL.MacTx`, `MacRx` | GMII (8 bit) and XGMII (64 bit), `sof` strobes |
| 1000BASE-X | `PCS.Code8b10b`, `PCS.Base1000X`, `PCS.AutoNeg` | `RTL.Code8b10b`, `RTL.PCS1000X`, `RTL.AutoNeg` | 8b/10b, comma alignment, sync, `/C/` sets, Clause 37 |
| 10GBASE-R | `PCS.Block66`, `PCS.Scrambler`, `PCS.BlockLock`, `PCS.Base10GR` | `RTL.Block66`, `RTL.Scrambler`, `RTL.BlockLock`, `RTL.PCS10GR` | 64b/66b, scrambler, block lock, 64 + 2 bit gearbox side |
| Filtering | `ExNet.Filter` | `ExNet.RTL.Classifier` | Ethernet + 2 VLAN, IPv4 any IHL, UDP, 16 entry table |
| Loopback | | `ExNet.RTL.Loopback` | MAC TX, PCS TX, PCS RX, MAC RX for 1G and 10G |
| Transceivers, FIFOs, NIC test | | | not started |

All decoders return `{:ok, struct}` or `{:error, reason}` and never raise on
malformed input (property-tested with random and mutated binaries).

## API overview

```elixir
# frames
frame = %ExNet.Ethernet{dst: ExNet.Ethernet.multicast_mac({239, 69, 1, 1}), src: mac,
                        tags: [%{tpid: 0x8100, pcp: 5, dei: 0, vid: 20}],
                        ethertype: 0x0800, payload: ip_bytes}
{:ok, ^frame} = ExNet.Ethernet.decode(ExNet.Ethernet.encode(frame))
{:ok, ip} = ExNet.IPv4.decode(frame.payload)        # options, fragment flag, checksum
{:ok, udp} = ExNet.UDP.decode(ip.payload, ip.src, ip.dst)

# FCS: crc' = S_n * crc xor D_n * data, rows as bit masks for the XOR network
ExNet.CRC32.step_word(crc, word, 8)
ExNet.CRC32.matrices(8)

# MAC on {data, valid, error} cycles
{state, {data, valid, error}, ready} = ExNet.MAC.Tx.step(state, {byte, last?} | nil)
{state, nil | {:data, byte, first?} | {:end, status}} = ExNet.MAC.Rx.step(state, cycle)

# 1000BASE-X, one code group per GMII cycle
{state, {code10, symbol}} = ExNet.PCS.Base1000X.Tx.step(state, {d, en, er})
{state, %{gmii: _, config: _, sync: _, symbol: _}} = ExNet.PCS.Base1000X.Rx.step(state, code10)
{code10, rd} = ExNet.PCS.Code8b10b.encode(rd, {:k, 0xBC})

# 10GBASE-R, one XGMII word {data64, ctl8} per 66-bit block {sync, payload64}
{state, {sync, scrambled}} = ExNet.PCS.Base10GR.tx_step(state, {data, ctl})
{state, %{lock: _, slip: _, xgmii: _}} = ExNet.PCS.Base10GR.rx_step(state, {sync, scrambled})

# filtering
f = ExNet.Filter.new() |> ExNet.Filter.add(%{ip_dst: {239, 69, 1, 1}, udp_dst_port: 5004}, {:stream, 0})
ExNet.Filter.classify(f, frame_bytes, fcs_ok)       # :drop | :host | {:stream, n}
```

Each step function is a pure `(state, input) -> {state, output}`, one call per
clock (or per word), so a hardware trace can be replayed against it and compared
cycle by cycle. Bit and byte order conventions are in the moduledocs.

Known limits of the models (the RTL inherits them): the Clause 36 sync and Clause 37 auto-negotiation
state machines and the 66-bit block layouts were written without the standard
at hand (see the moduledocs); `ExNet.PCS.Block66` byte positions inside control
blocks and the `ExNet.PCS.AutoNeg` transitions around `idle_detect` should be
checked against the standard text before the RTL is signed off. Next pages,
remote fault generation, EEE/LPI behaviour and the 64-to-66 bit gearbox are
not modelled.

## Hardware modules

All modules use the default domain (`clk`, synchronous active-low `rst_n`), registered
outputs unless stated, one cycle per clock. "Model cycle `t`" is the output of the
reference step function for the input of cycle `t`; the RTL shows it in cycle `t + 1`
unless noted. The moduledocs list every port.

| Module (`build/1` or function) | Interface | Behaviour |
|---|---|---|
| `RTL.CRC32.build(1 \| 8)` | `data`, `keep`, `valid`, `init` in; `state`, `crc`, `ok` out | one word per cycle, partial last word by `keep`, XOR network from `ExNet.CRC32.matrices/1` |
| `RTL.MacTx.build(8)` | AXI4-Stream in (`tdata/tlast/tvalid/tready`), `gmii_txd/en/er`, `sof` | preamble, pad to 60, FCS, 12 cycle gap; `tvalid` must not drop in a frame |
| `RTL.MacTx.build(64)` | AXI4-Stream in with `tkeep`, `xgmii_txd/txc`, `sof` | Start word, one word per beat, FCS behind the last byte, gap of at least 12 bytes with `/T/` counted (1 or 2 idle words); min frame 11 words |
| `RTL.MacRx.build(8)` | `gmii_rxd/dv/er` in; AXI4-Stream out (`tuser` 4 bit: bit 0 bad, 3:1 status), `sof`, `frame_end`, `status` | FCS stripped and checked, runt (< 64 with FCS), oversize (`max_len` 1522), `tlast` on the real last byte; beat in cycle `t + 2` |
| `RTL.MacRx.build(64)` | `xgmii_rxd/rxc` in; same outputs with `tkeep` | Start in lane 0 or 4, any `/T/` lane, first control lane ends a frame; `ExNet.MAC.Rx64` events in cycle `t + 1` |
| `RTL.PCS1000X.build_tx/0`, `build_rx/0`, `build/2` | `txd/en/er` to `code10`; unaligned `rx_code10` to `rxd/dv/er`; top adds Clause 37 | TX latency 1; RX alignment latency 4 for every bit offset; sync lost and regained |
| `RTL.AutoNeg.build/1` | event in (config / idle / invalid), `tick`, `restart` | state equal to `ExNet.PCS.AutoNeg` after every event |
| `RTL.PCS10GR.tx/0`, `rx/0`, `pcs/0` | `data/ctl` + `en` to `tx_data` (64) + `tx_header` (2) + `tx_valid`; reverse for RX with `rx_bitslip`, `lock` | latency 1, one block per enabled cycle; XGMII output only after block lock |
| `RTL.Classifier.build/1` | 64 bit AXI4-Stream in (no `tready`), table write port; stream out plus metadata | frame passes unchanged 14 cycles later, verdict and header fields valid from the first beat |
| `RTL.Loopback.build(:gbe \| :xgbe)` | AXI4-Stream in and out | first output beat 20 (1G) or 6 (10G) cycles after the first input beat |

### Timestamp hook

Every MAC has a one cycle `sof` output. TX: high in the cycle in which the SFD
(0xD5, lane 7 for XGMII) is on `gmii_txd` / `xgmii_txd`, i.e. aligned with the pins.
RX: high in the cycle after the SFD was on `gmii_rxd` (8 bit) or after the Start word
(with SFD in lane 7) was on `xgmii_rxd`, a constant 1 cycle behind the pins (the
outputs are registered). A wallclock sampled on `sof` needs these offsets, and the
PCS and transceiver latency, subtracted by the PTP layer.

### MAC limits

TX: no deficit idle count (the gap after `/T/` is rounded up to whole words, up to
11 words for a 64 byte frame instead of 10.5), Start only in lane 0, tkeep contiguous
and all ones except on the last beat. RX 64 bit: a word with a Terminate does not start
a frame, a malformed preamble is ignored, frames of up to 4 bytes (with FCS) produce no
beat (only `frame_end`). The classifier's result queue holds 4 frames: a stream of
runts at a period under 4 cycles sets its sticky `ovf`.

### Verification

`mix test` runs, per module, StreamData stimulus through the BEAM simulator against the
step functions (`ExNet.RtlCase`, closed loop where a handshake is involved:
`ExNet.AxisSource`), and replays recorded stimulus through Verilator with
`Cosim.assert_equivalent/3` (tag `:verilator`). The 64 bit MAC models (`MAC.Tx64`,
`MAC.Rx64`) are themselves checked against the byte models on random traffic
(`test/mac64_model_test.exs`). The loopback tests send random frames through
MAC, PCS, PCS, MAC for both speeds and compare them.

### Resources

Yosys `synth_xilinx` (UltraScale+, flattened, no I/O buffers), Yosys 0.69 on the dev
machine; synthesis only, no placement or timing. `mix test --include resources`
re-measures and enforces upper bounds (about 5 minutes).

| Design | LUT | FF | CARRY8 | BRAM18 | SRL |
|---|---|---|---|---|---|
| `crc32_8` | 101 | 32 | 0 | 0 | 0 |
| `crc32_64` (with `keep`) | 1580 | 32 | 0 | 0 | 0 |
| `mac_tx_8` | 166 | 59 | 4 | 0 | 0 |
| `mac_rx_8` | 142 | 108 | 3 | 0 | 0 |
| `mac_tx_64` | 2039 | 188 | 1 | 0 | 0 |
| `mac_rx_64` | 1906 | 279 | 5 | 0 | 0 |
| `pcs1000x_tx` | 93 | 37 | 0 | 0 | 0 |
| `pcs1000x_rx` (alignment, sync, `/C/`) | 150 | 73 | 0 | 1 (1) | 0 |
| `pcs1000x` (tx, rx, auto-negotiation) | 326 | 170 | 1 | 1 (1) | 0 |
| `autoneg` | 128 | 59 | 2 | 0 | 0 |
| `pcs10gr_tx` | 543 | 125 | 0 | 0 | 0 |
| `pcs10gr_rx` | 547 | 145 | 3 | 0 | 0 |
| `rxcls_n16` (16 entry table) | 3910 | 4919 | 162 | 0 | 76 |
| `net_loopback_1g` | 506 | 261 | 7 | 1 (1) | 0 |
| `net_loopback_10g` | 4901 | 737 | 9 | 0 | 0 |

(1) Yosys turns the constant synchronisation next-state table into a RAMB18; a
LUT implementation would be a few LUTs (see NEEDS.md). The 64 bit CRC and MAC numbers are
dominated by the partial-word variants (`keep` selects one of 8 XOR networks). The
classifier is dominated by the table registers (16 entries x 8 words x 32 bits).

## The hardware library set

ExHdl itself only provides the basics (RTL DSL, simulation, SystemVerilog,
targets, tool drivers). Function lives in these siblings:

| Library | Scope |
|---|---|
| [ex_hdl_cores](../ex_hdl_cores) | generic IP: FIFOs, CRC, arbiters, AXI4-Stream plumbing |
| [ex_hdl_xilinx](../ex_hdl_xilinx) | Xilinx primitives, constraints, boards |
| [ex_net](../ex_net) | Ethernet MAC, PCS, VLAN/IPv4/UDP/IGMP |
| [ex_ptp](../ex_ptp) | IEEE 1588: timestamping, wallclock, servo, BMCA |
| [ex_aes67](../ex_aes67) | RTP streams, jitter buffer, SAP/SDP, RTSP, mDNS, NMOS |
| [ex_audio](../ex_audio) | audio DSP kernels: EQ, dynamics, matrix mixer, meters |
| [ex_pcie](../ex_pcie) | PCIe DMA and BAR access, host side over vfio |

## Development

```sh
./scripts/checkout_siblings.sh   # path dependencies
mix test                       # about 4 minutes, Verilator tests included
mix test --exclude verilator   # BEAM side only
```

Tests: doctests, known answers (CRC check value 0xCBF43926, IEEE 802.3 8b/10b
code groups, 64b/66b block types), StreamData properties, malformed input.
Tests tagged `:tcpdump` and `:tshark` dissect generated pcaps and are skipped
when the tool is not in PATH (`ExNet.Pcap.write!/2` writes frames for
Wireshark).
