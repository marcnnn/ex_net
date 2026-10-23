defmodule ExNet.Interop.CapturesTest do
  @moduledoc """
  Differential test against Wireshark: real captures from the Wireshark sample
  capture wiki (downloaded on demand, cached in the system temp dir) are decoded
  by ex_net and by tshark, frame by frame. Where tshark finds a valid frame
  ex_net must decode it to the same fields; where tshark reports a bad
  checksum ex_net must reject it.
  """
  use ExUnit.Case, async: false

  alias ExNet.{ARP, Ethernet, IGMP, IPv4, UDP}
  alias Interop.{Captures, Tshark}

  @moduletag :interop
  @moduletag timeout: 300_000

  @captures ["IGMP-dataset.pcap", "vlan.cap.gz", "arp-storm.pcap"]

  for name <- @captures do
    test "#{name} decodes like tshark" do
      case Captures.fetch(unquote(name)) do
        {:skip, why} ->
          IO.puts("skipped #{unquote(name)}: #{why}")

        {:ok, path} ->
          {1, frames} = Captures.frames(path)
          pkts = Tshark.dissect_file(Path.dirname(path), Path.basename(path))
          assert length(frames) == length(pkts)

          results =
            for {{f, p}, i} <- Enum.with_index(Enum.zip(frames, pkts), 1),
                do: {i, compare(f, p)}

          failures = for {i, {:fail, why}} <- results, do: {i, why}

          assert failures == [],
                 "#{length(failures)} frames differ: #{inspect(Enum.take(failures, 5))}"

          stats = Enum.frequencies(for {_, r} <- results, do: elem(r, 0))
          IO.puts("#{unquote(name)}: #{inspect(stats)}")
          assert Map.get(stats, :ok, 0) > 0
      end
    end
  end

  # -- per frame ----------------------------------------------------------------------------

  defp compare(frame, pkt) do
    protos = String.split(Tshark.get(pkt, "frame.protocols"), ":")

    cond do
      "llc" in protos or Tshark.get(pkt, "eth.type") == nil ->
        # 802.3 length frames: ex_net reports them as LLC, Ethernet II only here
        case Ethernet.decode(frame) do
          {:error, _} -> {:skip, :llc}
          {:ok, _} -> {:fail, :llc_accepted}
        end

      true ->
        eth(frame, pkt)
    end
  end

  defp eth(frame, pkt) do
    case Ethernet.decode(frame) do
      {:error, e} ->
        {:fail, {:ethernet, e}}

      {:ok, f} ->
        want_tags = Tshark.all(pkt, "vlan.id")

        want_type =
          if(want_tags == [],
            do: Tshark.get(pkt, "eth.type"),
            else: List.last(Tshark.all(pkt, "vlan.etype"))
          )
          |> hex()

        cond do
          Ethernet.format_mac(f.dst) != Tshark.get(pkt, "eth.dst") ->
            {:fail, :dst}

          Ethernet.format_mac(f.src) != Tshark.get(pkt, "eth.src") ->
            {:fail, :src}

          Enum.map(f.tags, &Integer.to_string(&1.vid)) != want_tags ->
            {:fail, {:tags, f.tags, want_tags}}

          f.ethertype != want_type ->
            {:fail, {:ethertype, f.ethertype, want_type}}

          true ->
            l3(f, pkt)
        end
    end
  end

  defp l3(%{ethertype: 0x0806, payload: p}, pkt) do
    case ARP.decode(p) do
      {:ok, a} ->
        want = {
          Tshark.get(pkt, "arp.opcode"),
          Tshark.get(pkt, "arp.src.proto_ipv4"),
          Tshark.get(pkt, "arp.dst.proto_ipv4"),
          Tshark.get(pkt, "arp.src.hw_mac"),
          Tshark.get(pkt, "arp.dst.hw_mac")
        }

        got = {
          if(a.op == :request, do: "1", else: "2"),
          ip(a.spa),
          ip(a.tpa),
          Ethernet.format_mac(a.sha),
          Ethernet.format_mac(a.tha)
        }

        if got == want, do: {:ok, :arp}, else: {:fail, {:arp, got, want}}

      {:error, e} ->
        # unusual ARP (non-Ethernet/IPv4 hardware): only a failure if tshark understood IPv4 ARP
        if Tshark.get(pkt, "arp.src.proto_ipv4"), do: {:fail, {:arp, e}}, else: {:skip, :arp}
    end
  end

  defp l3(%{ethertype: 0x0800, payload: p}, pkt) do
    bad_ip = Tshark.get(pkt, "ip.checksum.status") == "0"

    case IPv4.decode(p) do
      {:error, e} ->
        if bad_ip or Tshark.problems(pkt) != [],
          do: {:ok, {:rejected, e}},
          else: {:fail, {:ipv4, e}}

      {:ok, ip} when bad_ip ->
        {:fail, {:bad_ip_checksum_accepted, ip.id}}

      {:ok, ip} ->
        got = {ip(ip.src), ip(ip.dst), Integer.to_string(ip.ttl), Integer.to_string(ip.protocol)}

        want =
          {Tshark.get(pkt, "ip.src"), Tshark.get(pkt, "ip.dst"), Tshark.get(pkt, "ip.ttl"),
           Tshark.get(pkt, "ip.proto")}

        cond do
          got != want -> {:fail, {:ipv4, got, want}}
          ip.id != hex(Tshark.get(pkt, "ip.id")) -> {:fail, {:ip_id, ip.id}}
          ip.fragment -> {:ok, :ipv4_fragment}
          ip.protocol == 17 -> l4_udp(ip, pkt)
          ip.protocol == 2 -> l4_igmp(ip, pkt)
          true -> {:ok, :ipv4}
        end
    end
  end

  defp l3(_, _), do: {:ok, :other}

  defp l4_udp(ip, pkt) do
    status = Tshark.get(pkt, "udp.checksum.status")

    case UDP.decode(ip.payload, ip.src, ip.dst) do
      {:ok, u} when status in [nil, "0"] and u.checksum_present ->
        {:fail, {:bad_udp_checksum_accepted, status}}

      {:ok, u} ->
        if {Integer.to_string(u.src_port), Integer.to_string(u.dst_port)} ==
             {Tshark.get(pkt, "udp.srcport"), Tshark.get(pkt, "udp.dstport")},
           do: {:ok, :udp},
           else: {:fail, :udp_ports}

      {:error, e} ->
        if status == "0" or Tshark.problems(pkt) != [],
          do: {:ok, {:rejected, e}},
          else: {:fail, {:udp, e}}
    end
  end

  defp l4_igmp(ip, pkt) do
    want = Tshark.get(pkt, "igmp.type")

    case IGMP.decode(ip.payload) do
      {:ok, m} ->
        got =
          case m do
            %IGMP.Query{} -> "0x11"
            %IGMP.Report{version: 1} -> "0x12"
            %IGMP.Report{version: 2} -> "0x16"
            %IGMP.Leave{} -> "0x17"
            %IGMP.ReportV3{} -> "0x22"
          end

        cond do
          got != want ->
            {:fail, {:igmp_type, got, want}}

          Map.has_key?(m, :group) and m.group != nil and
              ip(m.group) != Tshark.get(pkt, "igmp.maddr") ->
            {:fail, :igmp_group}

          true ->
            {:ok, :igmp}
        end

      {:error, e} ->
        if want in ["0x11", "0x12", "0x16", "0x17", "0x22"] and Tshark.problems(pkt) == [],
          do: {:fail, {:igmp, e, want}},
          else: {:ok, {:rejected, e}}
    end
  end

  defp ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp hex("0x" <> h), do: String.to_integer(h, 16)
end
