defmodule ExNet.RTL.UdpTx do
  @moduledoc """
  UDP/IPv4/Ethernet header insertion for stream engines such as
  `ExAes67.RTL.Packetiser`: a UDP payload stream (`ExNet.RTL.Ifc.udp_tx/0`, `tuser` =
  `{len, port, ip}`) becomes an Ethernet frame without FCS (`ExNet.RTL.Ifc.mac_tx/1`).

  Frame layout (42 header bytes, so the payload starts at lane 2 of beat 5):

  | Bytes | Field |
  |---|---|
  | 0-5 | destination MAC: `01:00:5E` + low 23 bits of the IP for 224.0.0.0/4, else `uc_mac` |
  | 6-11, 12-13 | `src_mac`, EtherType 0x0800 |
  | 14-33 | IPv4, IHL 5, `tos`, total length `28 + len`, identification = packet counter (from 0 after reset), DF, `ttl`, protocol 17, header checksum, `src_ip`, destination IP |
  | 34-41 | UDP: `src_port`, destination port, length `8 + len`, checksum 0 (none, legal over IPv4) |

  Ports besides the two streams (all static or per packet stable): `src_mac` (48), `src_ip`
  (32), `uc_mac` (48), `src_port` (16), `ttl` (8), `tos` (8), `tag` (8, goes to the
  `tuser` of the first output beat, 0 on the others, see `Ifc.mac_tx/1`). Byte order: MAC
  and IP integers have the first octet in the MSBs.

  Behaviour: the 5 header beats are sent while the first payload beat waits (`s_axis_tready`
  low), then payload beats pass with a shift of two lanes and one beat of register: the
  output `tvalid` follows the input `tvalid` (a source that pauses makes the frame pause,
  so put a store-and-forward FIFO between this module and a MAC), `tready` passes through. A last
  input beat with 7 or 8 bytes needs one more output beat. `len` must equal the number of
  payload bytes and be at least 1. Frame in cycle `t` to output in `t + 0` for header
  beats (combinational from the input `tuser`), payload beat `j` (input beat `j`) in the
  same cycle as output beat `5 + j`; the IPv4 checksum is registered over two cycles and
  used from the fourth header beat on.

  `model/4` builds the same frame with the BEAM codecs.
  """
  use ExHdl.RTL
  alias ExNet.RTL.Ifc

  @doc """
  The frame for `payload` and `%{ip:, port:, len:}`-style arguments: `cfg` has `:src_mac`,
  `:src_ip` (tuple), `:uc_mac`, `:src_port`, `:ttl`, `:tos`; `dst_ip` is a tuple, `id` the
  packet counter.
  """
  def model(payload, {dst_ip, dst_port}, cfg, id) do
    dst_mac =
      if ExNet.Ethernet.multicast_ip?(dst_ip),
        do: ExNet.Ethernet.multicast_mac(dst_ip),
        else: cfg.uc_mac

    udp =
      ExNet.UDP.encode(
        %ExNet.UDP{src_port: cfg.src_port, dst_port: dst_port, payload: payload},
        cfg.src_ip,
        dst_ip,
        checksum: false
      )

    ip =
      ExNet.IPv4.encode(%ExNet.IPv4{
        src: cfg.src_ip,
        dst: dst_ip,
        protocol: 17,
        dscp: Bitwise.bsr(cfg.tos, 2),
        ecn: Bitwise.band(cfg.tos, 3),
        id: id,
        df: true,
        ttl: cfg.ttl,
        payload: udp
      })

    ExNet.Ethernet.encode(%ExNet.Ethernet{
      dst: dst_mac,
      src: cfg.src_mac,
      ethertype: 0x0800,
      payload: ip
    })
  end

  def build(_opts \\ []) do
    module "udp_tx" do
      s = slave(:s_axis, Ifc.udp_tx())
      m = master(:m_axis, Ifc.mac_tx(64))
      src_mac = input(:src_mac, 48)
      src_ip = input(:src_ip, 32)
      uc_mac = input(:uc_mac, 48)
      src_port = input(:src_port, 16)
      ttl = input(:ttl, 8)
      tos = input(:tos, 8)
      tag = input(:tag, 8)

      # 0 header beats, 1 payload, 2 flush
      phase = reg(:phase, 2)
      hb = reg(:hb, 3)
      prev = reg(:prev, 16)
      ident = reg(:ident, 16)
      fl_keep = reg(:fl_keep, 8, reset: nil)
      sum_r = reg(:sum_r, 20, reset: nil)
      csum_r = reg(:csum_r, 16, reset: nil)

      dst_ip = s.tuser[0..31]
      dst_port = s.tuser[32..47]
      len = s.tuser[48..63]

      byte = fn x, i -> x[(8 * i)..(8 * i + 7)] end
      be = fn x, n -> for i <- (n - 1)..0//-1, do: byte.(x, i) end
      bytes = fn list -> cat(Enum.reverse(list)) end
      c8 = fn v -> const(v, 8) end

      multicast = wire(:multicast, dst_ip[28..31] == 0xE)

      mc_mac =
        wire(
          :mc_mac,
          cat([
            c8.(0x01),
            c8.(0x00),
            c8.(0x5E),
            cat([const(0, 1), dst_ip[16..22]]),
            byte.(dst_ip, 1),
            byte.(dst_ip, 0)
          ])
        )

      dmac = wire(:dmac, mux(multicast, mc_mac, uc_mac))
      total = wire(:total, add_wrap(len, 28))
      ulen = wire(:ulen, add_wrap(len, 8))

      # IPv4 header checksum, two register stages (the beat with it is the fourth)
      terms = [
        cat([c8.(0x45), tos]),
        total,
        ident,
        const(0x4000, 16),
        cat([ttl, c8.(17)]),
        src_ip[16..31],
        src_ip[0..15],
        dst_ip[16..31],
        dst_ip[0..15]
      ]

      f1 = wire(:fold1, zext(sum_r[0..15], 17) + sum_r[16..19])
      f2 = wire(:fold2, zext(f1[0..15], 17) + f1[16])

      hdr =
        [
          be.(dmac, 6) ++ [byte.(src_mac, 5), byte.(src_mac, 4)],
          [byte.(src_mac, 3), byte.(src_mac, 2), byte.(src_mac, 1), byte.(src_mac, 0)] ++
            [c8.(0x08), c8.(0x00), c8.(0x45), tos],
          be.(total, 2) ++ be.(ident, 2) ++ [c8.(0x40), c8.(0x00), ttl, c8.(17)],
          be.(csum_r, 2) ++ be.(src_ip, 4) ++ [byte.(dst_ip, 3), byte.(dst_ip, 2)],
          [byte.(dst_ip, 1), byte.(dst_ip, 0)] ++
            be.(src_port, 2) ++ be.(dst_port, 2) ++ be.(ulen, 2)
        ]
        |> Enum.map(bytes)

      hdr_word = wire(:hdr_word, mux(hb, hdr ++ List.duplicate(List.last(hdr), 3)))

      # valid bytes of the input beat
      nb =
        Enum.reduce(1..7, zext(s.tkeep[0], 4), fn i, a -> add_wrap(a, zext(s.tkeep[i], 4)) end)

      over = wire(:over, nb > 6)
      in_hdr = wire(:in_hdr, phase == 0)
      in_data = wire(:in_data, phase == 1)
      in_flush = wire(:in_flush, phase == 2)
      go = wire(:go, m.tready)

      comb do
        m.tvalid <~ 0
        m.tdata <~ hdr_word
        m.tkeep <~ 0xFF
        m.tlast <~ 0
        m.tuser <~ 0
        s.tready <~ 0

        if in_hdr do
          m.tvalid <~ s.tvalid
          m.tuser <~ mux(hb == 0, tag, const(0, 8))
        end

        if in_data do
          m.tvalid <~ s.tvalid
          s.tready <~ go
          m.tdata <~ cat([s.tdata[0..47], prev])

          m.tkeep
          <~ mux(
            s.tlast and not over,
            cat(for i <- 7..0//-1, do: nb + 2 > i),
            const(0xFF, 8)
          )

          m.tlast <~ (s.tlast and not over)
        end

        if in_flush do
          m.tvalid <~ 1
          m.tdata <~ zext(prev, 64)
          m.tkeep <~ fl_keep
          m.tlast <~ 1
        end
      end

      sync do
        sum_r
        <~ Enum.reduce(tl(terms), zext(hd(terms), 20), fn t, a -> add_wrap(a, zext(t, 20)) end)

        csum_r <~ ~~~f2[0..15]

        if in_hdr and s.tvalid and go do
          hb <~ add_wrap(hb, 1)

          if hb == 4 do
            hb <~ 0
            phase <~ 1
          end
        end

        if in_data and s.tvalid and go do
          prev <~ s.tdata[48..63]

          if s.tlast do
            ident <~ add_wrap(ident, 1)

            if over do
              phase <~ 2
              fl_keep <~ mux(nb == 7, const(0x01, 8), const(0x03, 8))
            else
              phase <~ 0
              prev <~ 0
            end
          end
        end

        if in_flush and go do
          phase <~ 0
          prev <~ 0
        end
      end
    end
  end
end
