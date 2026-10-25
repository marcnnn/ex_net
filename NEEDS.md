# Needs from ../exhdl

Written while doing the BEAM reference models. Nothing here blocks the models.

## defpacket

1. **Variable header length.** IPv4 (IHL 5..15), VLAN stacks (0..2 tags) and
   therefore every header after them start at a data-dependent byte offset.
   Wanted: a packet chain (`eth -> vlan* -> ipv4 -> udp`) with offsets
   computed from decoded fields (`ihl * 4`, EtherType in 0x8100/0x88A8), as
   decoder and as AXI4-Stream parser with a byte-lane shifter. This is
   PROJECT_REVIEW CRIT-01. Today ex_net slices bytes by hand and uses
   `defpacket` for the fixed parts only.
2. **Header not a multiple of the bus width.** Ethernet is 14 bytes, a VLAN tag
   4: `bus_width` has to be 16 or 8, so a 64-bit stream cannot use the
   definition. Wanted: headers that end mid-beat, payload starting at any byte
   lane.
3. **Computed fields.** Length (IPv4 total length, UDP length) and checksums
   (IPv4 header, UDP with pseudo header, ones' complement) on encode, check on
   decode. Wanted: `field :checksum, 16, compute: {:ones_complement, over: ...}`
   or a hook, in both the BEAM codec and the hardware emitter.
4. **Header-only decode and binary payload.** `decode_x/1` converts the whole
   payload to a list of integers. ex_net calls it on a header-sized slice;
   wanted: `payload :data, type: :bytes` (stays a binary), or a
   `decode_x_header/1` returning `{header, rest_binary}`.
5. **Sub-byte fields in `byte_order: :little` and flag fields.** Nice to have:
   `field :df, 1, type: :flag` decoding to a boolean, and named enums
   (`type: {:enum, ...}`) for opcodes and block types.
6. **assert error shape.** `{:error, {:assert_failed, name, value}}` is fine,
   but `decode` of a bad assert should be able to map to a user-chosen reason.

## Simulation and co-simulation

7. **Step-function comparison harness.** Models in ex_net are
   `step(state, input) -> {state, output}` (GMII cycle, code group, XGMII
   word). Wanted: a helper that drives a simulated module with an input list
   and compares the output trace per cycle against such a function, with
   `nil` as don't-care for output cycles and a configurable latency offset.
8. **Ports wider than 64 bits in the BEAM simulator.** A 66-bit block and an
   XGMII word (64 data + 8 control = 72 bits) have to be a single port value
   in simulation and in the generated SystemVerilog.
9. **Bit-reverse and slice/concat ops with static ranges** for the 8b/10b
   tables (ROM of 10-bit entries), the gearbox, and CRC XOR trees generated
   from `ExNet.CRC32.matrices/1` (rows as masks).

## RTL layer (wave 2)

Found while writing the MACs, PCS, classifier and loopbacks with `ExHdl.RTL`. Items 7 to 9
above are met: ports wider than 64 bits (tested with 100 bits) work in the BEAM simulator
and Verilator, slices/concat/`cat` cover the CRC and ROM needs. Nothing here blocks ex_net.

10. **Combinational-only modules have no `clk`/`rst_n`.** `ExNet.RtlCase` (and `Sim.reset`
    callers) poke `rst_n`:

        module "m" do
          a = input(:a, 1)
          q = output(:q, 1)
          q <~ a
        end
        # Sim.new(mod) |> Sim.poke(:rst_n, 0)  ->  ArgumentError: no port :rst_n

    Wanted: `Sim.reset/2` and `Cosim` ignore modules without a reset, or a documented
    `domain(:sys)` call (the workaround used in ex_net).
11. **Unread instance outputs fail `verilator --lint-only -Wall`.** Instantiate any child
    and leave one output unused: the generated wire `<inst>_<port>` raises
    `%Warning-UNUSEDSIGNAL` (an error in `Cosim.build`). Unread bits of ordinary signals
    get `lint_off` pragmas, instance port wires do not. Today every child output has to be
    read in the parent (ex_net concatenates leftovers into a `*_dbg` output).
12. **Instance wire names collide with parent signals.** Instance `:tx` with port `data`
    creates `tx_data`; a parent output `tx_data` then fails with
    `ElaborationError: tx_data is declared twice`. Wanted: a clear hint, or a separator
    that cannot collide (`u_tx__data`); ex_net names instances `u_*`.
13. **Constant tables become BRAM.** A `mux(sel, list)` ROM (the 1000BASE-X sync next-state
    table, 4 bit state) is emitted as a `case`; Yosys `synth_xilinx` infers a RAMB18 for it:
    `pcs1000x_rx` uses 1 RAMB18 for about 30 bits of table. Wanted: a ROM/table construct or
    option (`rom_style: :distributed`, emitted as `(* rom_style = "distributed" *)`) for
    constant `mux` lists, like `memory(style: ...)`.
14. **`mux(c, 4, 3)` does not elaborate.** Two integer branches have no width:
    `WidthError: integer 4 needs a width here; use const(4, 3)`. Annoying in state updates
    (`phase <~ mux(ge59, 4, 3)`); wanted: take the width from the assignment target, or
    from the larger of the two constants (`{:u, 3}` here).
15. **Signal names that are SystemVerilog keywords** are rejected only at elaboration time
    (`small`, `event` were hit, `trunc` as a register name is fine). A list in the docs, or
    automatic escaping of the SV name, would save a round trip.
16. **`==` on a Hardware expression and `nil`.** Inside `rtl do`/`module` blocks `acc == nil`
    builds a hardware comparison and raises `WidthError: not a hardware expression: nil`
    (used in a fold over `mux` branches). Not a bug, but the error could say that `==` is
    overloaded here and suggest `is_nil/1`.
17. **Closed-loop stimulus.** Handshake protocols (AXI4-Stream `tready`) need the next input to
    depend on this cycle's outputs. `ExNet.RtlCase.drive/4` (test/support/rtl_case.ex) does
    poke, `Sim.outputs`, decide, step. Wanted upstream (`ExHdl.RTL.Sim.drive/4` or in
    `Cosim`), including recording the stimulus so Verilator can replay it.
18. **BEAM simulation speed.** The classifier (about 5k FF, wide XOR/compare trees) takes
    about 3 s per random scenario of a few hundred cycles in `Sim`, a minute for its test
    file; Verilator runs the same stimulus in well under a second. A cheaper evaluation
    schedule (or caching of constant subtrees) would help large designs.
19. **Generic blocks written locally**: migrated to ex_hdl_cores. The MACs use
    `ExHdlCores.CRC.next/5`, `final/2` and `init/1` inline (the register is now in Rocksoft
    notation, so `fcs = CRC.final(:crc32, crc)` and the residue is compared bit reversed),
    `ExNet.RTL.PCS1000X.build_rx/0` instantiates `ExHdlCores.CommaAligner`, and
    `ExNet.RTL.Classifier` captures its header with `ExHdlCores.HeaderCapture` (`header: 96`,
    not 90: the 96 byte window keeps the `len`/`more` semantics of the parser; a one bit
    `at_start` register and the `hdr_valid` edge replace the index and event wires). Resource
    deltas (Yosys LUT): mac_tx_8 163 to 168, mac_rx_8 142 to 146, mac_tx_64 2097 to 2111,
    mac_rx_64 1855 to 1885, pcs1000x_rx 150 to 151, pcs1000x 326 to 356, rxcls_n16 4127 to
    4200, rx_path_n16 6661 to 6822; FF unchanged within 2. Still local: `test/support/axis_source.ex`
    (`AxisDriver` has random backpressure and frame outputs, ex_net's tests need the cycle exact
    closed loop with gaps and aborts, and read GMII or XGMII traces rather than streams),
    LFSR/scrambler matrices by unit vectors (`ExNet.RTL.Scrambler.masks/1`), the classifier's
    delay line and result ring (a packet FIFO with the verdict as sideband would replace them),
    ones' complement checksum tree and byte-lane shifters (shared already, see `Checksum`,
    `ByteShift`). `ExNet.CRC32.matrices/1` stays: it is the reference model's `step_word/3`.
20. **defpacket for the classifier.** Evaluated in the integration wave, not adopted. The
    parser generated from the chain `eth -> vlan{0,2} -> ipv4 (ihl) -> udp` (`defpacket :udp_rx,
    bus_width: 64`, `Wrap.protocol/2`, Yosys `synth_xilinx -flatten -family xcup`) takes
    3086 LUT and 1649 FF; `ExNet.RTL.Classifier` with a one entry table, including the 14 stage
    pass-through, the result queue, the table match, the verdict and `payload_len`, takes 2008 LUT
    and 1834 FF (a 16 entry table 4087 / 5015). The generated parser also has no BEAM model
    (`Wrap.protocol` black box), so the cycle-by-cycle tests against `ExNet.Filter` could not run
    in the BEAM simulator, and it emits the payload stream, not the frame with metadata from the
    first beat that `ExNet.RTL.Ifc.rx_frame/3` and the FCS verdict on the last beat need.
    The byte-model `ExNet.Filter.key/1` stays the contract. Wanted before it pays off: a BEAM model
    for protocol black boxes, and a "pass through and tag" mode (frame unchanged, fields as side
    outputs) next to the "strip headers" parser.

## Integration with ex_ptp and ex_aes67 (wave 3)

Contracts are `ExNet.RTL.Ifc`; tests are in ex_aes67 (`test/integration/`), ex_ptp
(`test/integration/`) and `test/rtl/datapath_test.exs`.

Resolved: `tx_tag` and the `tuser` tag of `MacTx`; `rx_sof` / `tx_sof` names and offsets; RX
`tuser` shared with `RxStamp`; classifier metadata with `payload_offset` and `payload_len`;
`UdpRx` (payload extraction, store and forward, bad frames dropped); `UdpTx` and `TxPath`
(header insertion, gapless frames for the MAC); `Classifier.program/3`.

Open:

- IGMP in hardware: done as `ExNet.RTL.Igmp` (v2 and v3 host, table of joined groups behind a
  command port, query responses, unsolicited reports, own frames; `TxPath` has `raw:` sources for
  it, `ExNet.NetTops.igmp_top/1` is the wiring). Open: a CSR wrapper (the command port and the
  `member` / `rd_*` read-back are plain ports), group-and-source filtering (only any-source
  `EXCLUDE {}` joins), IGMPv3 reports of more than the table size are not split, VLAN is one tag
  of fixed priority 6 from a static `vlan_id`, an event is dropped (`rx_missed`) if a second
  IGMP frame arrives within about 40 cycles of the first, a leave right after a join of the same
  group (within about 16 cycles) cancels the join's first report. ARP/unicast next hop
  resolution: `UdpTx` takes the unicast MAC from an input.
- `UdpRx` verifies the UDP checksum with its own 8-byte masked sum per beat (32 bit
  accumulator, fold on `tlast`); `ExHdlCores.Checksum` (uncommitted in cores at the time) could
  replace it once its API is settled.
- IPv6, and the MAC option that adjusts a UDP checksum after a one-step insertion.
- `RxPath` and `TxPath` are single clock. A MAC clock different from the system clock needs
  `ExHdlCores.FIFO.axis_async/1` on the classified frame stream and on the TX stream.
- `UdpRx` stores the 96 bit metadata with every beat of its FIFO (170 bit wide, 5 BRAM18 for 512
  beats); a metadata FIFO next to the 73 bit data FIFO would use 3.

ExHdl notes from this wave (the first two have reproducers in items 11, 12 above; they cost
workarounds in three more places):

- Instance wires `<inst>_<port>` against top level ports, again with a minimal case:

      child = module "c" do a = input(:a, 1); q = output(:phase, 1); q <~ a end
      module "t" do
        a = input(:a, 1); p = output(:nco_phase, 1)
        u = instance(:nco, child, connect: [a: a])
        p <~ u.phase
      end
      # ElaborationError: t: nco_phase is declared twice

- `use ExHdl.RTL` removes the Bitwise operators from `Kernel` also outside `module/3`, so a helper
  function in such a module fails with `undefined function <<</2` unless it has `import Bitwise`;
  `<~` is undefined outside `module`/`rtl` blocks, so loops that declare ports have to sit inside
  the module body. Only a documentation point.
- Multi-clock closed loop: `Loop` (ex_ptp and ex_aes67 `test/support/loop.ex`) drives `Sim` with
  `Sim.schedule/3` per event and replays the recorded inputs in Verilator; `ExAes67.Test.Loop.run_cosim/6`
  predicts a free-running design's outputs for long Verilator-only runs. This is item 17 again.
- BEAM simulator speed on the receive chain (MAC, classifier, UDP extractor, depacketiser, jitter
  buffer, timestamp unit, NCO): about 25 cycles per second, so the integration scenarios are
  1500 to 2000 cycles and take two minutes; Verilator needs seconds (item 18).

## Interop findings

Run against Wireshark 4.4.19 (tshark in a container), the Linux kernel (veth, tcpdump) and
Wireshark sample captures; commands in README "Interop".

- No protocol bug found in `ExNet.Ethernet`, `IPv4`, `UDP`, `ARP`, `IGMP`: frames built by the
  library dissect cleanly with equal fields, kernel generated IGMPv3, ARP, UDP and tagged
  frames decode, and 1100+ frames of three sample captures decode like tshark.
- Frames sent by `ExNet.RTL.Igmp` dissect cleanly in tshark (checksums, Router Alert, records);
  not covered by any real implementation yet: IGMP queries from a real querier (only what
  `IGMP-dataset.pcap` contains), a switch's IGMP snooping reacting to the RTL's reports, fragments, IPv4 options other
  than NOP and router alert, 802.1ad on a real switch, the MAC and PCS layers (no hardware, and
  Wireshark does not see them).
- tshark's `checksum.status` is 1 for partial (offloaded) checksums, so the interop tests compute
  the check with ex_net's own decoders and use tshark only for generated frames, where the
  checksums are complete.

