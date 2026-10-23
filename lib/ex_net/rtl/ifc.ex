defmodule ExNet.RTL.Ifc do
  @moduledoc """
  The interfaces of the ex_net datapath, defined once. Producers and consumers in
  ex_net, ex_ptp and ex_aes67 build their ports from these bundles
  (`master(:m_axis, Ifc.mac_rx())`, `slave(:s_axis, Ifc.udp_rx())`), so a change of a
  width or a field breaks elaboration instead of the wiring.

  All streams are AXI4-Stream with little endian lanes (byte 0 in `tdata[7:0]`) and
  `tkeep` contiguous from lane 0 (only the last beat of a packet may be partial).

  ## `mac_rx/1`: MAC receive stream (producer `ExNet.RTL.MacRx`)

  `tdata`, `tkeep` (64 bit only), `tlast`, `tuser` (4), `tvalid`, no `tready`. The frame
  without preamble and FCS. `tuser` is meaningful with `tlast`: bit 0 set = bad frame
  (FCS error, receive error, runt, oversize), bits 3:1 the status code (0 ok, 1 FCS,
  2 receive error, 3 runt, 4 oversize). Use `bad/1` in RTL.

  ## `ts_rx/0`, `ts_tx/0`: timestamp strobes (producer MAC, consumer `ExPtp.RTL.TimestampUnit`)

    * `rx_sof`: one cycle, 1 MAC cycle after the cycle in which the Start word (8 bit:
      the SFD byte) was on the receive pins. Every `rx_sof` belongs to exactly one frame on
      the stream (bad frames included), in order. The first stream beat of that frame
      appears at least 2 cycles later.
    * `tx_sof`: one cycle, in the cycle in which the Start word (8 bit: the SFD byte) is on
      the transmit pins (offset 0). `tx_tag` (8 bits) is valid in the same cycle and held
      until the next frame: the `tuser` of the first beat of that frame (see `mac_tx/1`).
    * Between two `*_sof` of one kind at least 8 cycles pass (an Ethernet frame is at least
      11 words); nothing else about spacing is promised.

  ## `mac_tx/1`: MAC transmit stream (consumer `ExNet.RTL.MacTx`)

  `tdata`, `tkeep` (64 bit), `tlast`, `tuser` (8), `tvalid`, `tready`. A frame without
  FCS (the MAC pads to 60 bytes and appends the FCS). `tuser` is the PTP timestamp tag and
  is read on the first beat only.

    * The MAC looks at `tvalid` while idle. The first beat is taken one cycle after
      `tvalid` was first seen (`tready` is low in the first cycle), and `tx_sof` and the
      Start word follow in that cycle. From the first beat on `tready` is high until
      `tlast`: **the source must not drop `tvalid` between the first and the last beat**
      (a stalled frame is sent with an error and truncated). Put a store-and-forward
      `ExHdlCores.FIFO.packet/1` behind any source that can pause.
    * Latency: with `ExPtp.RTL.TxInsert` in front, the first beat accepted by `TxInsert` in
      cycle `a` has its Start word on the pins in cycle `a + 2` (`tx_first_beat_cycles/0`).

  ## `rx_frame/1`: classifier output (producer `ExNet.RTL.Classifier`)

  The frame unchanged (`tdata`, `tkeep`, `tlast`, `tuser` as `mac_rx/1`, `tvalid`, no
  `tready`), `sof` (first beat) and the header metadata, valid in every cycle with
  `tvalid`, constant over the frame (fields that do not apply read 0):

  | Field | Bits | Meaning |
  |---|---|---|
  | `kind` | 2 | 0 drop, 1 host, 2 stream engine; on the last beat of a bad frame always 0 |
  | `stream` | `sb` | stream index of a kind 2 hit |
  | `hit` | 1 | a table entry matched |
  | `hit_index` | `hw` | its index |
  | `vlan_id`, `vlan_valid`, `ntags` | 12, 1, 2 | outermost tag |
  | `ethertype` | 16 | after all tags |
  | `ip_valid`, `ip_proto`, `src_ip`, `dst_ip` | 1, 8, 32, 32 | IPv4 (checksum valid, first octet in the MSBs) |
  | `src_port`, `dst_port` | 16, 16 | UDP, unfragmented |
  | `payload_valid` | 1 | UDP header found |
  | `payload_offset` | 7 | byte offset of the UDP payload in the frame (22 to 90) |
  | `payload_len` | 16 | UDP payload bytes (UDP length - 8, clamped to the IP payload) |

  Timing: the beat on the input in cycle `t` is on the output in cycle `t + 14`
  (`ExNet.RTL.Classifier.delay/0`); the metadata is valid from the first output beat.
  The speculative verdict (`kind`...) assumes a good FCS; commit on `tlast`.

  ## `udp_rx/0`: UDP payload stream (producer `ExNet.RTL.UdpRx`, consumer `ExAes67.RTL.Depacketiser`)

  `tdata`, `tkeep`, `tlast`, `tuser` (96), `tvalid`, `tready`. Payload bytes only, byte 0
  of the payload in lane 0, whole packets only (a bad frame never appears). `tuser`
  (valid on every beat, constant over the packet), see `pack_udp_rx/1`:

  | Bits | Field |
  |---|---|
  | 31:0 | destination IP |
  | 47:32 | destination UDP port |
  | 79:48 | source IP |
  | 95:80 | payload length in bytes |

  ## `udp_tx/0`: UDP payload to transmit (producer `ExAes67.RTL.Packetiser`, consumer `ExNet.RTL.UdpTx`)

  Same stream with `tuser` (64) valid on every beat (constant over the packet), see
  `pack_udp_tx/1`: 31:0 destination IP, 47:32 destination port, 63:48 payload length.
  `tready` may be low at any time; `tvalid` may pause inside a packet.
  """
  alias ExHdl.RTL.Interface
  import Bitwise

  @doc """
  MAC receive stream (see the moduledoc). `bits` is 8 or 64 (consumers that can stall, like
  `ExPtp.RTL.RxStamp`, take any width and `ready: true`; `keep:` defaults to `bits > 8`).
  """
  def mac_rx(bits \\ 64, opts \\ []) do
    Interface.axi_stream(
      data: bits,
      keep: Keyword.get(opts, :keep, bits > 8),
      user: 4,
      ready: Keyword.get(opts, :ready, false)
    )
  end

  @doc "MAC transmit stream, `tuser` = timestamp tag. `bits` is 8 or 64 (`keep:` as `mac_rx/2`)."
  def mac_tx(bits \\ 64, opts \\ []),
    do: Interface.axi_stream(data: bits, keep: Keyword.get(opts, :keep, bits > 8), user: 8)

  @doc "Bit of the MAC receive `tuser` that flags a bad frame (valid with `tlast`)."
  def bad(user), do: user[0]

  @doc "Receive timestamp strobe bundle; use with prefix `:rx` (ports `rx_sof`)."
  def ts_rx, do: Interface.new(:ts_rx, [{:sof, 1, :fwd}])

  @doc "Transmit timestamp bundle; use with prefix `:tx` (ports `tx_sof`, `tx_tag`); `tag` bits, default 8."
  def ts_tx(tag \\ 8), do: Interface.new(:ts_tx, [{:sof, 1, :fwd}, {:tag, tag, :fwd}])

  @doc "MAC cycles between the Start word on the receive pins and `rx_sof`."
  def rx_sof_cycles, do: 1

  @doc "MAC cycles between `tx_sof` and the Start word on the transmit pins."
  def tx_sof_cycles, do: 0

  @doc "Cycles from the first beat accepted by `TxInsert` to the Start word on the pins."
  def tx_first_beat_cycles, do: 2

  @doc """
  Classifier output: the MAC receive stream plus `sof` and the metadata fields. `sb` is the
  number of stream index bits, `hw` the width of `hit_index`.
  """
  def rx_frame(sb \\ 4, hw \\ 4, bits \\ 64) do
    axis = Interface.axi_stream(data: bits, user: 4, ready: false).fields
    meta = for {n, w} <- rx_meta_fields(sb, hw), do: {n, w, :fwd}
    Interface.new(:rx_frame, axis ++ [{:sof, 1, :fwd}] ++ meta)
  end

  @doc "Metadata fields `[{name, width}]` of `rx_frame/3`, in documentation order."
  def rx_meta_fields(sb \\ 4, hw \\ 4) do
    [
      kind: 2,
      stream: sb,
      hit: 1,
      hit_index: hw,
      vlan_id: 12,
      vlan_valid: 1,
      ntags: 2,
      ethertype: 16,
      ip_valid: 1,
      ip_proto: 8,
      src_ip: 32,
      dst_ip: 32,
      src_port: 16,
      dst_port: 16,
      payload_valid: 1,
      payload_offset: 7,
      payload_len: 16
    ]
  end

  @doc "UDP payload stream with the 96 bit receive metadata."
  def udp_rx, do: Interface.axi_stream(data: 64, user: 96)

  @doc "UDP payload stream with the 64 bit transmit metadata."
  def udp_tx, do: Interface.axi_stream(data: 64, user: 64)

  @doc """
  The 96 bit `udp_rx` `tuser` of `%{dst_ip:, dst_port:, src_ip:, len:}` (IPs as 32 bit
  integers).

      iex> Integer.to_string(ExNet.RTL.Ifc.pack_udp_rx(%{dst_ip: 1, dst_port: 2, src_ip: 3, len: 4}), 16)
      "400000003000200000001"
  """
  def pack_udp_rx(%{dst_ip: ip, dst_port: port, src_ip: src, len: len}),
    do: ip ||| port <<< 32 ||| src <<< 48 ||| len <<< 80

  @doc "Inverse of `pack_udp_rx/1`."
  def unpack_udp_rx(u),
    do: %{
      dst_ip: u &&& 0xFFFFFFFF,
      dst_port: u >>> 32 &&& 0xFFFF,
      src_ip: u >>> 48 &&& 0xFFFFFFFF,
      len: u >>> 80 &&& 0xFFFF
    }

  @doc "The 64 bit `udp_tx` `tuser` of `%{ip:, port:, len:}`."
  def pack_udp_tx(%{ip: ip, port: port, len: len}), do: ip ||| port <<< 32 ||| len <<< 48

  @doc "Inverse of `pack_udp_tx/1`."
  def unpack_udp_tx(u),
    do: %{ip: u &&& 0xFFFFFFFF, port: u >>> 32 &&& 0xFFFF, len: u >>> 48 &&& 0xFFFF}
end
