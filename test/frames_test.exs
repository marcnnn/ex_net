defmodule ExNet.FramesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExNet.{ARP, Checksum, Ethernet, Gen, IGMP, IPv4, UDP}
  alias ExNet.IGMP.{Leave, Query, Record, Report, ReportV3}

  doctest ExNet.Packets
  doctest ExNet.Checksum
  doctest ExNet.Ethernet
  doctest ExNet.IPv4
  doctest ExNet.UDP
  doctest ExNet.ARP
  doctest ExNet.IGMP
  doctest ExNet.Pcap

  describe "checksum" do
    test "RFC 1071 example" do
      assert Checksum.sum(<<0x00, 0x01, 0xF2, 0x03, 0xF4, 0xF5, 0xF6, 0xF7>>) == 0xDDF2
    end

    test "odd length pads with zero" do
      assert Checksum.sum(<<0x12>>) == 0x1200
    end
  end

  describe "ethernet" do
    test "multicast mapping drops the top 9 bits of the group" do
      assert Ethernet.multicast_mac({224, 0, 0, 251}) == Ethernet.mac("01:00:5e:00:00:fb")
      assert Ethernet.multicast_mac({239, 255, 255, 255}) == Ethernet.mac("01:00:5e:7f:ff:ff")
      assert Ethernet.multicast_mac({239, 129, 1, 1}) == Ethernet.multicast_mac({224, 1, 1, 1})
    end

    test "wire layout with QinQ" do
      f = %Ethernet{
        dst: <<1, 2, 3, 4, 5, 6>>,
        src: <<7, 8, 9, 10, 11, 12>>,
        tags: [
          %{tpid: 0x88A8, pcp: 7, dei: 1, vid: 0xABC},
          %{tpid: 0x8100, pcp: 1, dei: 0, vid: 5}
        ],
        ethertype: 0x0800,
        payload: <<0xEE>>
      }

      assert Ethernet.encode(f) ==
               <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0x88, 0xA8, 0xFA, 0xBC, 0x81, 0x00, 0x20,
                 0x05, 8, 0, 0xEE>>

      assert {:ok, ^f} = Ethernet.decode(Ethernet.encode(f))
    end

    test "errors" do
      assert {:error, :truncated_header} = Ethernet.decode(<<1, 2, 3>>)
      assert {:error, :llc_frame} = Ethernet.decode(<<0::96, 0, 46, 0::368>>)
      tag = <<0x81, 0, 0, 1>>
      three = <<0::96>> <> tag <> tag <> tag <> <<8, 0>>
      assert {:error, :too_many_tags} = Ethernet.decode(three)

      assert {:error, :bad_tag_order} =
               Ethernet.decode(<<0::96, 0x81, 0, 0, 1, 0x88, 0xA8, 0, 1, 8, 0>>)

      assert {:error, :truncated_header} = Ethernet.decode(<<0::96, 0x81, 0, 0>>)
    end

    property "round trip" do
      check all(f <- Gen.eth_frame()) do
        assert {:ok, ^f} = Ethernet.decode(Ethernet.encode(f))
      end
    end
  end

  describe "ipv4" do
    test "known header (Wikipedia example)" do
      hdr =
        <<0x45, 0, 0, 0x73, 0, 0, 0x40, 0, 0x40, 0x11, 0xB8, 0x61, 0xC0, 0xA8, 0, 1, 0xC0, 0xA8,
          0, 0xC7>>

      payload = :binary.copy(<<0>>, 0x73 - 20)
      assert {:ok, p} = IPv4.decode(hdr <> payload)

      assert {p.src, p.dst, p.protocol, p.df, p.ttl} ==
               {{192, 168, 0, 1}, {192, 168, 0, 199}, 17, true, 64}

      assert IPv4.encode(%IPv4{
               src: {192, 168, 0, 1},
               dst: {192, 168, 0, 199},
               protocol: 17,
               df: true,
               payload: payload
             }) ==
               hdr <> payload
    end

    test "options extend the header and are padded" do
      p = %IPv4{
        src: {1, 1, 1, 1},
        dst: {2, 2, 2, 2},
        protocol: 2,
        options: <<0x94, 4, 0, 0>>,
        payload: "abcd"
      }

      bin = IPv4.encode(p)
      assert <<0x46, _::binary>> = bin
      assert {:ok, %{options: <<0x94, 4, 0, 0>>, payload: "abcd"}} = IPv4.decode(bin)
      assert <<0x45, _::binary>> = IPv4.encode(%{p | options: <<>>})
      assert <<0x46, _::binary>> = IPv4.encode(%{p | options: <<1>>})
    end

    test "fragments are flagged" do
      base = %IPv4{src: {1, 1, 1, 1}, dst: {2, 2, 2, 2}, protocol: 17, payload: "x"}
      assert {:ok, %{fragment: false}} = IPv4.decode(IPv4.encode(base))
      assert {:ok, %{fragment: true, mf: true}} = IPv4.decode(IPv4.encode(%{base | mf: true}))

      assert {:ok, %{fragment: true, frag_offset: 185}} =
               IPv4.decode(IPv4.encode(%{base | frag_offset: 185}))
    end

    test "rejections" do
      good =
        IPv4.encode(%IPv4{src: {1, 1, 1, 1}, dst: {2, 2, 2, 2}, protocol: 17, payload: "xyz"})

      <<a, rest::binary>> = good
      assert {:error, :bad_version} = IPv4.decode(<<0x65, rest::binary>>)
      assert {:error, :bad_ihl} = IPv4.decode(<<0x44, rest::binary>>)
      assert {:error, :truncated_header} = IPv4.decode(<<0x4F, rest::binary>>)
      assert {:error, :truncated} = IPv4.decode(binary_part(good, 0, 22))

      assert {:error, :bad_checksum} =
               IPv4.decode(<<a, rest::binary-size(7), 99, 0, 0, 1>> <> binary_part(good, 12, 11))

      assert {:ok, _} =
               IPv4.decode(<<a, rest::binary-size(7), 99, 0, 0, 1>> <> binary_part(good, 12, 11),
                 verify_checksum: false
               )

      assert {:error, :bad_length} =
               IPv4.decode(<<a, 0, 0, 10, rest::binary-size(16), 0::32>> |> binary_part(0, 24))
    end

    property "round trip, padding trimmed" do
      check all(p <- Gen.ipv4(), pad <- binary(max_length: 20)) do
        assert {:ok, ^p} = IPv4.decode(IPv4.encode(p) <> pad)
      end
    end

    property "checksum detects a flipped header bit" do
      check all(p <- Gen.ipv4(), bit <- integer(0..159)) do
        bin = IPv4.encode(p)
        <<pre::bitstring-size(bit), b::1, post::bitstring>> = bin
        flipped = <<pre::bitstring, 1 - b::1, post::bitstring>>

        case IPv4.decode(flipped) do
          {:ok, _} -> flunk("flip accepted")
          {:error, _} -> :ok
        end
      end
    end
  end

  describe "udp" do
    @src {192, 168, 1, 1}
    @dst {239, 69, 83, 171}

    test "checksum known answer" do
      bin = UDP.encode(%UDP{src_port: 5004, dst_port: 5004, payload: <<1, 2, 3>>}, @src, @dst)
      # pseudo header + header + payload summed by hand
      sum =
        Checksum.sum(
          <<192, 168, 1, 1, 239, 69, 83, 171, 0, 17, 0, 11, 5004::16, 5004::16, 11::16, 0::16, 1,
            2, 3>>
        )

      <<_::48, ck::16, _::binary>> = bin
      assert ck == Bitwise.bxor(sum, 0xFFFF)
      assert {:ok, _} = UDP.decode(bin, @src, @dst)
      assert {:error, :bad_checksum} = UDP.decode(bin, @src, {1, 2, 3, 4})
    end

    test "zero checksum is allowed and not verified" do
      bin = UDP.encode(%UDP{src_port: 1, dst_port: 2, payload: "p"}, @src, @dst, checksum: false)
      assert <<_::48, 0::16, _::binary>> = bin
      assert {:ok, %{checksum_present: false, payload: "p"}} = UDP.decode(bin, @src, @dst)
    end

    test "computed zero is sent as 0xFFFF" do
      # find a payload whose checksum computes to zero
      bin =
        Enum.find_value(0..65535, fn n ->
          b = UDP.encode(%UDP{src_port: 1, dst_port: 2, payload: <<n::16>>}, @src, @dst)
          match?(<<_::48, 0xFFFF::16, _::binary>>, b) && b
        end)

      assert bin
      assert {:ok, _} = UDP.decode(bin, @src, @dst)
    end

    test "length checks and padding trim" do
      bin = UDP.encode(%UDP{src_port: 1, dst_port: 2, payload: "abc"}, @src, @dst)
      assert {:ok, %{payload: "abc"}} = UDP.decode(bin <> <<0, 0, 0, 0>>, @src, @dst)
      assert {:error, :truncated} = UDP.decode(binary_part(bin, 0, 9), @src, @dst)
      assert {:error, :bad_length} = UDP.decode(<<1::16, 2::16, 4::16, 0::16>>)
      assert {:error, :truncated_header} = UDP.decode(<<1, 2, 3>>)
    end

    property "round trip" do
      check all({u, s, d} <- Gen.udp(), cs <- boolean()) do
        bin = UDP.encode(u, s, d, checksum: cs)
        assert {:ok, got} = UDP.decode(bin, s, d)
        assert got == %{u | checksum_present: cs}
      end
    end

    property "payload corruption is detected when a checksum is present" do
      check all(
              {u, s, d} <- Gen.udp(),
              u.payload != "",
              i <- integer(0..(byte_size(u.payload) - 1)),
              flip <- integer(1..255)
            ) do
        bin = UDP.encode(u, s, d)
        <<pre::binary-size(8 + i), b, post::binary>> = bin
        bad = <<pre::binary, Bitwise.bxor(b, flip), post::binary>>
        assert {:error, :bad_checksum} = UDP.decode(bad, s, d)
      end
    end
  end

  describe "arp" do
    test "request wire format" do
      a = %ARP{
        op: :request,
        sha: <<2, 0, 0, 0, 0, 1>>,
        spa: {10, 0, 0, 1},
        tha: <<0::48>>,
        tpa: {10, 0, 0, 2}
      }

      assert ARP.encode(a) ==
               <<0, 1, 8, 0, 6, 4, 0, 1, 2, 0, 0, 0, 0, 1, 10, 0, 0, 1, 0, 0, 0, 0, 0, 0, 10, 0,
                 0, 2>>

      assert {:ok, ^a} = ARP.decode(ARP.encode(a) <> :binary.copy(<<0>>, 18))
    end

    test "rejections" do
      good =
        ARP.encode(%ARP{
          op: :reply,
          sha: <<1::48>>,
          spa: {1, 1, 1, 1},
          tha: <<2::48>>,
          tpa: {2, 2, 2, 2}
        })

      assert {:error, :unsupported_arp} = ARP.decode(<<0, 6, binary_part(good, 2, 26)::binary>>)

      assert {:error, :bad_opcode} =
               ARP.decode(
                 <<binary_part(good, 0, 7)::binary, 9, binary_part(good, 8, 20)::binary>>
               )

      assert {:error, :truncated_header} = ARP.decode(binary_part(good, 0, 27))
    end
  end

  describe "igmp" do
    test "v2 report known answer" do
      bin = IGMP.encode(%Report{version: 2, group: {239, 1, 2, 3}})

      assert <<0x16, 0, _::16, 239, 1, 2, 3>> = bin
      assert Checksum.valid?(bin)
    end

    test "queries" do
      general = %Query{version: 2, max_resp: 100, group: {0, 0, 0, 0}}
      assert {:ok, ^general} = IGMP.decode(IGMP.encode(general))

      assert {:ok, %Query{version: 1}} =
               IGMP.decode(IGMP.encode(%Query{version: 1, group: {0, 0, 0, 0}}))

      v3 = %Query{
        version: 3,
        max_resp: 0x8F,
        group: {239, 1, 1, 1},
        suppress: true,
        qrv: 5,
        qqic: 200,
        sources: [{10, 0, 0, 1}, {10, 0, 0, 2}]
      }

      assert {:ok, ^v3} = IGMP.decode(IGMP.encode(v3))
      assert byte_size(IGMP.encode(v3)) == 12 + 8
      assert IGMP.decode_code(0x8F) == 0x1F * 8
      assert IGMP.decode_code(0xFF) == 0x1F * 1024
    end

    test "v3 report with records, leave" do
      r = %ReportV3{
        records: [
          %Record{type: :mode_is_include, group: {239, 1, 1, 1}, sources: [{10, 0, 0, 1}]},
          %Record{
            type: :block_old_sources,
            group: {239, 1, 1, 2},
            sources: [],
            aux: <<1, 2, 3, 4>>
          }
        ]
      }

      assert {:ok, ^r} = IGMP.decode(IGMP.encode(r))

      assert {:ok, %Leave{group: {239, 1, 1, 1}}} =
               IGMP.decode(IGMP.encode(%Leave{group: {239, 1, 1, 1}}))
    end

    test "rejections" do
      good = IGMP.encode(%Report{version: 2, group: {239, 1, 1, 1}})
      assert {:error, :bad_checksum} = IGMP.decode(<<good::binary-size(7), 0>>)
      assert {:error, :truncated_header} = IGMP.decode(binary_part(good, 0, 7))
      bad_type = <<0x99, 0, 0, 0, 0, 0, 0, 0>>
      sum = Checksum.checksum(bad_type)
      assert {:error, {:unknown_type, 0x99}} = IGMP.decode(<<0x99, 0, sum::16, 0::32>>)

      v3 =
        IGMP.encode(%ReportV3{
          records: [%Record{type: :mode_is_include, group: {1, 1, 1, 1}, sources: [{2, 2, 2, 2}]}]
        })

      short = binary_part(v3, 0, byte_size(v3) - 4)
      # fix checksum so only the length is wrong
      <<h::binary-size(2), _::16, rest::binary>> = short

      short =
        <<h::binary, Checksum.checksum(<<h::binary, 0::16, rest::binary>>)::16, rest::binary>>

      assert {:error, :truncated} = IGMP.decode(short)
    end
  end

  describe "never raise on malformed input" do
    property "random binaries" do
      check all(bin <- binary(max_length: 120)) do
        for f <- [
              &Ethernet.decode/1,
              &IPv4.decode/1,
              &UDP.decode/1,
              &ARP.decode/1,
              &IGMP.decode/1
            ] do
          assert match?({:ok, _}, f.(bin)) or match?({:error, _}, f.(bin))
        end

        assert match?({:ok, _}, UDP.decode(bin, @src, @dst)) or
                 match?({:error, _}, UDP.decode(bin, @src, @dst))
      end
    end

    property "mutated and truncated valid frames" do
      check all(
              f <- Gen.eth_frame(),
              cut <- integer(0..140),
              pos <- integer(0..139),
              val <- integer(0..255)
            ) do
        bin = Ethernet.encode(f)

        mutated =
          if pos < byte_size(bin),
            do:
              binary_part(bin, 0, pos) <>
                <<val>> <> binary_part(bin, pos + 1, byte_size(bin) - pos - 1),
            else: bin

        trunc = binary_part(mutated, 0, min(cut, byte_size(mutated)))

        for b <- [mutated, trunc] do
          with {:ok, eth} <- Ethernet.decode(b),
               {:ok, ip} <- IPv4.decode(eth.payload),
               {:ok, _} <- UDP.decode(ip.payload, ip.src, ip.dst) do
            :ok
          else
            {:error, _} -> :ok
          end
        end
      end
    end

    property "igmp mutations" do
      check all(pos <- integer(0..30), val <- integer(0..255), cut <- integer(0..40)) do
        msg =
          IGMP.encode(%ReportV3{
            records: [
              %Record{
                type: :mode_is_include,
                group: {239, 1, 1, 1},
                sources: [{1, 1, 1, 1}, {2, 2, 2, 2}]
              }
            ]
          })

        pos = rem(pos, byte_size(msg))
        <<a::binary-size(pos), _, b::binary>> = msg
        m = binary_part(<<a::binary, val, b::binary>>, 0, min(cut, byte_size(msg)))
        assert match?({:ok, _}, IGMP.decode(m)) or match?({:error, _}, IGMP.decode(m))
      end
    end
  end
end
