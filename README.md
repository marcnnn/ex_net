# ExNet

Ethernet for ExHdl designs: the hardware datapath and the matching BEAM
codecs come from the same packet definitions.

## Status

BEAM side done: packet codecs and bit-exact reference models. Hardware done as
`ExHdl.RTL` modules, each checked cycle by cycle against those models in the BEAM
simulator and in Verilator (random stimulus); gearbox and transceiver black boxes
(ex_hdl_xilinx) and the NIC top level are not written yet. The interfaces to ex_ptp and
ex_aes67 are defined once in `ExNet.RTL.Ifc`; `RxPath` and `TxPath` are the datapaths
between the MAC and those libraries (integration tests in ex_aes67, `test/integration/`).

| Layer | Module | Hardware | State |
|---|---|---|---|
| Packets | `ExNet.Ethernet`, `IPv4`, `UDP`, `IGMP`, `ARP`, `Packets` | | codecs done; fixed headers use `defpacket` |
| FCS | `ExNet.CRC32` | `ExNet.RTL.CRC32` | 8 and 64 bit with `tkeep` |
| Interfaces | | `ExNet.RTL.Ifc` | bundles and field layouts of the MAC, classifier and UDP payload streams, timestamp strobes |
| MAC | `ExNet.MAC`, `MAC.Tx`, `MAC.Rx`, `MAC.Tx64`, `MAC.Rx64` | `ExNet.RTL.MacTx`, `MacRx` | GMII (8 bit) and XGMII (64 bit), `rx_sof` / `tx_sof` strobes, TX tag |
| 1000BASE-X | `PCS.Code8b10b`, `PCS.Base1000X`, `PCS.AutoNeg` | `RTL.Code8b10b`, `RTL.PCS1000X`, `RTL.AutoNeg` | 8b/10b, comma alignment, sync, `/C/` sets, Clause 37 |
| 10GBASE-R | `PCS.Block66`, `PCS.Scrambler`, `PCS.BlockLock`, `PCS.Base10GR` | `RTL.Block66`, `RTL.Scrambler`, `RTL.BlockLock`, `RTL.PCS10GR` | 64b/66b, scrambler, block lock, 64 + 2 bit gearbox side |
| Filtering | `ExNet.Filter` | `ExNet.RTL.Classifier` | Ethernet + 2 VLAN, IPv4 any IHL, UDP, 16 entry table, UDP payload offset and length |
| UDP payload RX | | `ExNet.RTL.UdpRx` | payload realigned to lane 0 behind a store-and-forward packet FIFO, bad frames dropped |
| UDP payload TX | `ExNet.Ethernet`, `IPv4`, `UDP` | `ExNet.RTL.UdpTx`, `TxPath` | Ethernet/IPv4/UDP header insertion, multicast MAC from the IP, store-and-forward merge of sources |
| IGMP host | `ExNet.IGMP`, `IGMP.Host` | `ExNet.RTL.Igmp` | IGMPv2/v3 join and leave from a command port, query responses with random delay, own frames (Router Alert, CS6, multicast MAC), `TxPath` `raw:` source |
| Datapaths | | `ExNet.RTL.RxPath`, `TxPath` | MAC RX, classifier, `UdpRx`; sources, `UdpTx`, packet FIFOs, merge |
| Loopback | | `ExNet.RTL.Loopback` | MAC TX, PCS TX, PCS RX, MAC RX for 1G and 10G |
| Transceivers, NIC test | | | not started |

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
| `RTL.CRC32.build(1 \| 8)` | `data`, `keep`, `valid`, `init` in; `state`, `crc`, `ok` out | one word per cycle, partial last word by `keep`, XOR network from `ExHdlCores.CRC` |
| `RTL.MacTx.build(8)` | AXI4-Stream in (`tdata/tlast/tuser/tvalid/tready`), `gmii_txd/en/er`, `tx_sof`, `tx_tag` | preamble, pad to 60, FCS, 12 cycle gap; `tvalid` must not drop in a frame; `tuser` = PTP tag |
| `RTL.MacTx.build(64)` | AXI4-Stream in with `tkeep`, `tuser` (tag), `xgmii_txd/txc`, `tx_sof`, `tx_tag` | Start word, one word per beat, FCS behind the last byte, gap of at least 12 bytes with `/T/` counted (1 or 2 idle words); min frame 11 words |
| `RTL.MacRx.build(8)` | `gmii_rxd/dv/er` in; AXI4-Stream out (`tuser` 4 bit: bit 0 bad, 3:1 status), `rx_sof`, `frame_end`, `status` | FCS stripped and checked, runt (< 64 with FCS), oversize (`max_len` 1522), `tlast` on the real last byte; beat in cycle `t + 2` |
| `RTL.MacRx.build(64)` | `xgmii_rxd/rxc` in; same outputs with `tkeep` | Start in lane 0 or 4, any `/T/` lane, first control lane ends a frame; `ExNet.MAC.Rx64` events in cycle `t + 1` |
| `RTL.PCS1000X.build_tx/0`, `build_rx/0`, `build/2` | `txd/en/er` to `code10`; unaligned `rx_code10` to `rxd/dv/er`; top adds Clause 37 | TX latency 1; RX alignment latency 4 for every bit offset; sync lost and regained |
| `RTL.AutoNeg.build/1` | event in (config / idle / invalid), `tick`, `restart` | state equal to `ExNet.PCS.AutoNeg` after every event |
| `RTL.PCS10GR.tx/0`, `rx/0`, `pcs/0` | `data/ctl` + `en` to `tx_data` (64) + `tx_header` (2) + `tx_valid`; reverse for RX with `rx_bitslip`, `lock` | latency 1, one block per enabled cycle; XGMII output only after block lock |
| `RTL.Classifier.build/1` | `Ifc.mac_rx` in (no `tready`), table write port; `Ifc.rx_frame` out (stream plus metadata) | frame passes unchanged 14 cycles later, verdict and header fields (with `payload_offset`, `payload_len`) valid from the first beat; `Classifier.program/3` makes the table writes from an `ExNet.Filter` |
| `RTL.UdpRx.build/1` | `Ifc.rx_frame` in; `Ifc.udp_rx` out | UDP payload of `kind = 2` frames from lane 0, whole packets only, metadata in `tuser`; a bad FCS drops the packet, `drop_full` if the FIFO is full |
| `RTL.UdpTx.build/0` | `Ifc.udp_tx` in; `Ifc.mac_tx` out; `src_mac`, `src_ip`, `uc_mac`, `src_port`, `ttl`, `tos`, `tag` | 5 header beats, payload shifted by 2 lanes; IPv4 checksum, DF, id from a packet counter, UDP checksum 0 |
| `RTL.Igmp.build/1` | `Ifc.rx_frame` in (from the classifier); command port `cmd_valid/leave/group`, `src_mac`, `src_ip`, `v2_only`, `robustness`, `unsol_ms`; `Ifc.mac_tx` out (may pause, use a packet FIFO); `member`, `joined`, `mode_v2` | table of joined groups, reports sent `robustness` times on join and leave, general and group-specific query answers after a random delay up to the maximum response time, v2 compatibility and report suppression; frames equal `ExNet.IGMP.Host.frame/3`; see the moduledoc and "IGMP" below |
| `RTL.RxPath.build/1`, `RTL.TxPath.build/1` | see the moduledocs | `MacRx` + `Classifier` + `UdpRx`; `n` sources through `UdpTx` and packet FIFOs, merged packet by packet |
| `RTL.Loopback.build(:gbe \| :xgbe)` | AXI4-Stream in and out | first output beat 20 (1G) or 6 (10G) cycles after the first input beat |

### Interfaces

`ExNet.RTL.Ifc` is the contract; ex_ptp and ex_aes67 build their ports from it. Its
moduledoc has the field tables, this is the summary:

| Interface | Producer to consumer | Layout and timing |
|---|---|---|
| `mac_rx/1` | `MacRx` to classifier, `RxStamp` | `tuser` 4 bit, valid with `tlast`: bit 0 bad frame, 3:1 status; no `tready` |
| `ts_rx/0` | `MacRx` to `TimestampUnit` | `rx_sof`, one cycle, 1 cycle after the Start word on the pins (`Ifc.rx_sof_cycles/0`); one frame follows each |
| `ts_tx/1` | `MacTx` to `TimestampUnit` | `tx_sof` in the cycle of the Start word (offset 0), `tx_tag` valid in that cycle and held |
| `mac_tx/1` | `TxPath`, `TxInsert` to `MacTx` | `tuser` = tag on the first beat, 0 on the others; `tready` low for one cycle at the start, then high until `tlast`: no `tvalid` gaps inside a frame |
| `rx_frame/3` | `Classifier` to `UdpRx`, host path | stream plus `sof` plus metadata (`kind`, `stream`, `hit`, `ethertype`, IPs, ports, `payload_offset`, `payload_len`), 14 cycles after the MAC beat |
| `udp_rx/0` | `UdpRx` to `ExAes67.RTL.Depacketiser` | 64 bit payload stream, `tuser` 96 bit `{len 16, src IP 32, port 16, dst IP 32}` |
| `udp_tx/0` | `ExAes67.RTL.Packetiser` to `UdpTx` | 64 bit payload stream, `tuser` 64 bit `{len 16, port 16, IP 32}`, may pause and stall |

The MAC cannot stall: everything behind `MacRx` either keeps up (the classifier, `RxStamp`
with a ready sink) or drops whole frames (`UdpRx`). The MAC TX cannot pause: a source that
can (the packetiser) goes through `TxPath`, whose packet FIFOs release complete frames only.

### Timestamp hook

`rx_sof` (`MacRx`): high in the cycle after the SFD was on `gmii_rxd` (8 bit) or after the
Start word (with SFD in lane 7) was on `xgmii_rxd`, a constant 1 cycle behind the pins (the
outputs are registered). `tx_sof` (`MacTx`): high in the cycle in which the SFD (0xD5, lane 7 for
XGMII) is on `gmii_txd` / `xgmii_txd`, aligned with the pins; `tx_tag` is the `tuser` of the
first beat, valid in the same cycle. The reference point of a stamp is the clock edge that samples
the Start word (RX: at the MAC's input, TX: at the PHY). `ExPtp.RTL.TimestampUnit.nominal_comp/3`
turns the offsets and its capture latency into the compensation; add the PCS and transceiver
latency of a real board. `ExPtp.RTL.TxInsert` in front of `MacTx` samples the wallclock when it
accepts the first beat; the Start word is on the pins `Ifc.tx_first_beat_cycles/0` (2) cycles later.

### MAC limits

TX: no deficit idle count (the gap after `/T/` is rounded up to whole words, up to
11 words for a 64 byte frame instead of 10.5), Start only in lane 0, tkeep contiguous
and all ones except on the last beat, `tvalid` must stay high from the first to the last beat
(see `Ifc`). RX 64 bit: a word with a Terminate does not start
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

`UdpRx` is checked with classifier-model metadata on random frames (VLAN, IP options, padding,
fragments, bad FCS, sink stalls, FIFO overflow), `UdpTx` against the BEAM codecs (every tail
length, source pauses, sink stalls, checksum and MAC derivation). `test/rtl/datapath_test.exs`
runs XGMII words through `RxPath` (MAC, classifier, payload extraction: frames, metadata and
payloads against the models) and sources through `TxPath` and `MacTx` (decoded with the
`MAC.Rx64` model, FCS valid, tags at `tx_sof`). The three-library chains are in ex_aes67
(`test/integration/`), the timestamp tests behind the MACs in ex_ptp.

### Resources

Yosys `synth_xilinx` (UltraScale+, flattened, no I/O buffers), Yosys 0.69 on the dev
machine; synthesis only, no placement or timing. `mix test --include resources`
re-measures and enforces upper bounds (about 5 minutes).

| Design | LUT | FF | CARRY8 | BRAM18 | SRL |
|---|---|---|---|---|---|
| `crc32_8` | 101 | 32 | 0 | 0 | 0 |
| `crc32_64` (with `keep`) | 1580 | 32 | 0 | 0 | 0 |
| `mac_tx_8` | 163 | 67 | 4 | 0 | 0 |
| `mac_rx_8` | 142 | 108 | 3 | 0 | 0 |
| `mac_tx_64` | 2097 | 196 | 1 | 0 | 0 |
| `mac_rx_64` | 1855 | 279 | 5 | 0 | 0 |
| `pcs1000x_tx` | 93 | 37 | 0 | 0 | 0 |
| `pcs1000x_rx` (alignment, sync, `/C/`) | 150 | 73 | 0 | 1 (1) | 0 |
| `pcs1000x` (tx, rx, auto-negotiation) | 326 | 170 | 1 | 1 (1) | 0 |
| `autoneg` | 128 | 59 | 2 | 0 | 0 |
| `pcs10gr_tx` | 503 | 125 | 0 | 0 | 0 |
| `pcs10gr_rx` | 547 | 145 | 3 | 0 | 0 |
| `rxcls_n16` (16 entry table) | 4087 | 5015 | 107 | 0 | 76 |
| `net_loopback_1g` | 504 | 261 | 7 | 1 (1) | 0 |
| `net_loopback_10g` | 4928 | 737 | 9 | 0 | 0 |
| `udp_rx` (512 beat packet FIFO) | 431 | 299 | 19 | 5 | 0 |
| `udp_tx` | 414 | 75 | 26 | 0 | 0 |
| `tx_path_n2` (2 sources, 512 beat FIFOs) | 1026 | 223 | 80 | 6 | 0 |
| `rx_path_n16` (`mac_rx_64`, classifier, `udp_rx`) | 6318 | 5592 | 132 | 5 | 76 |
| `igmp_g16` (16 groups, one DSP48 for the random delay) | 2979 | 2274 | 144 | 0 | 0 |

(1) Yosys turns the constant synchronisation next-state table into a RAMB18; a
LUT implementation would be a few LUTs (see NEEDS.md). The 64 bit CRC and MAC numbers are
dominated by the partial-word variants (`keep` selects one of 8 XOR networks). The
classifier is dominated by the table registers (16 entries x 8 words x 32 bits); with a one entry
table it is 2008 LUT and 1834 FF. `udp_rx` stores the 96 bit metadata with every FIFO beat (see NEEDS.md).

## IGMP

`ExNet.RTL.Igmp` is the hardware twin of `ExNet.IGMP.Host` (the BEAM model and frame builder):
the same message choices (v3 `change_to_exclude` / `change_to_include` records, v2 report and
leave, `mode_is_exclude` answers, v2 compatibility after a v1/v2 query, v2 suppression); only the
random delays differ (a 32 bit LFSR instead of `:rand`). Wiring on the card:

```elixir
cls = instance(:u_cls, Classifier.build(entries: 16))            # frame stream with metadata
igmp = instance(:u_igmp, Igmp.build(groups: 16, hit_bits: 4), connect: [src_mac: ..., src_ip: ..., ...])
connect(cls.m, igmp.s)                                           # next to UdpRx and the PTP stage
path = instance(:u_path, TxPath.build(sources: 1, raw: 1))      # the IGMP frames join the merge
connect(igmp.m_axis, path.r0_axis)
```

The BEAM drives `cmd_valid` / `cmd_leave` / `cmd_group` (hold `cmd_valid` until `cmd_ready`,
`cmd_done` and `cmd_err` follow), for example from CSRs for `GROUP` and `CMD`. A top level with exactly
this wiring is `ExNet.NetTops.igmp_top/1`; `test/rtl/igmp_card_test.exs` runs it from XGMII to XGMII.

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

## Interop

`mix test --only interop` checks the codecs against real implementations (excluded from
`mix test`). Needs rootless podman and, for the first run, network access (image build,
Wireshark sample captures cached in `$TMPDIR/ex_interop_captures`; a failed download skips
the test).

```sh
containers/build.sh            # tshark (Wireshark 4.4, Debian trixie) and nettools (iproute2, tcpdump)
mix test --only interop
```

| Test | Against | Result |
|---|---|---|
| `test/interop/tshark_test.exs` | tshark `-T json`: Ethernet, 802.1Q and 802.1ad, IPv4 with options, DSCP/ECN/DF/TTL/ID, UDP, ARP, IGMP v1/v2/v3 queries, reports and leave | no malformed or expert warnings, IPv4/UDP/IGMP checksums good, every field equal; a corrupted UDP payload is reported as bad checksum (negative control) |
| `test/interop/kernel_traffic_test.exs` | Linux kernel on a veth pair (`containers/nettools`, tcpdump): ARP requests plain, 802.1Q (vid 20) and 802.1ad (vid 30), UDP multicast with TTL 4, IGMPv3 join and leave | every frame decodes; UDP and IPv4 checksums verify; the IGMPv3 records are `change_to_exclude` and `change_to_include` for the joined group |
| `test/interop/igmp_rtl_test.exs` | frames sent by `RTL.Igmp` (BEAM simulation): v3 joins, general query answer with three records, leave, v2 report and leave, 802.1Q tagged report | no malformed or expert warnings, IPv4 and IGMP checksums good, TTL 1, DSCP 48, Router Alert, multicast MACs, group addresses and record types equal the scenario |
| `test/interop/captures_test.exs` | Wireshark sample captures `IGMP-dataset.pcap` (147 frames), `vlan.cap.gz` (395), `arp-storm.pcap` (622), frame by frame against tshark | all frames agree on MACs, tags, ethertype, IPv4, UDP, ARP and IGMP fields; 39 LLC frames are reported as such by `Ethernet.decode/1` |

Notes:

- veth leaves partial (pseudo header only) checksums on transmit. The kernel traffic script
  turns TX offload off (`ethtool -K ... tx off`); without that `UDP.decode/3` correctly
  reports `:bad_checksum`. tshark calls such packets `checksum.status = 1` anyway, so it is
  not a checksum oracle for captures taken before offload.
- No ARP replies in the kernel capture (one network namespace), no IPv6 (the kernel's
  IPv6 neighbour discovery and MLD are in the capture and ignored).
- Findings: none in `lib/`, see NEEDS.md ("Interop findings").
