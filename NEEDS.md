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
19. **Generic blocks written locally** (to deduplicate into ex_hdl_cores): CRC-32 with `keep`
    (`ExNet.RTL.CRC32`; the matrix-masked XOR network, `next_keep/4` costs 1580 LUT at
    64 bit, a shared network with a shifter would be smaller), LFSR/scrambler matrices by unit
    vectors (`ExNet.RTL.Scrambler.masks/1`), AXI4-Stream source/driver for tests
    (`test/support/axis_source.ex`), comma aligner, header capture buffer with a fixed delay
    line and result ring (`ExNet.RTL.Classifier`), ones' complement checksum tree over a
    masked word window, byte-lane shifters by runtime offset.
20. **defpacket for the classifier.** The RX classifier was written by hand (see items 1
    and 2 at the top): with variable header lengths the offset muxes, the 13-way UDP port
    select, the 34-word checksum mask and the truncation guards would come from the packet
    chain. The byte-model `ExNet.Filter.key/1` stays the contract.
