defmodule ExNet.IGMP.Filter do
  @moduledoc """
  Removes the group records of hardware-owned multicast groups from the IGMP
  frames the Linux kernel sends, so that the hardware IGMP block stays the only
  member of those groups on the link (see "Multicast group ownership" in the
  card's NIC note).

  `filter/2` takes an Ethernet frame (no FCS) and a set of owned groups (a
  `MapSet` or list of IPv4 tuples):

  | Frame | Result |
  |---|---|
  | not IPv4, not IGMP, a query, or one that does not decode | unchanged |
  | v3 report, no record for an owned group | unchanged |
  | v3 report, some records owned | the other records, record count, IPv4 total length and both checksums recomputed |
  | v3 report, all records owned (or none left) | `:drop` |
  | v1 or v2 report, or v2 leave, for an owned group | `:drop` |
  | v1 or v2 report, or v2 leave, for another group | unchanged |

  Frames that are changed are rebuilt with the existing codecs; Ethernet
  addresses, VLAN tags, IPv4 fields (TTL, DSCP, Router Alert) and the
  remaining records, with their sources and auxiliary data, are kept.

      iex> alias ExNet.{Ethernet, IGMP, IPv4}
      iex> rec = fn g -> %IGMP.Record{type: :change_to_exclude, group: g} end
      iex> igmp = IGMP.encode(%IGMP.ReportV3{records: [rec.({239, 1, 1, 1}), rec.({239, 2, 2, 2})]})
      iex> ip = %IPv4{src: {10, 0, 0, 1}, dst: {224, 0, 0, 22}, protocol: 2, ttl: 1, options: <<148, 4, 0, 0>>, payload: igmp}
      iex> frame = Ethernet.encode(%Ethernet{dst: Ethernet.multicast_mac({224, 0, 0, 22}), src: <<2, 0, 0, 0, 0, 1>>, ethertype: 0x0800, payload: IPv4.encode(ip)})
      iex> out = ExNet.IGMP.Filter.filter(frame, [{239, 1, 1, 1}])
      iex> {:ok, eth} = Ethernet.decode(out)
      iex> {:ok, ip} = IPv4.decode(eth.payload)
      iex> {:ok, %IGMP.ReportV3{records: [%IGMP.Record{group: g}]}} = IGMP.decode(ip.payload)
      iex> g
      {239, 2, 2, 2}
      iex> ExNet.IGMP.Filter.filter(frame, [{239, 1, 1, 1}, {239, 2, 2, 2}])
      :drop
  """
  alias ExNet.{Ethernet, IGMP, IPv4}

  @spec filter(binary, Enumerable.t()) :: binary | :drop
  def filter(frame, owned) when is_binary(frame) do
    owned = MapSet.new(owned)

    with {:ok, eth} <- Ethernet.decode(frame),
         0x0800 <- eth.ethertype,
         {:ok, %IPv4{protocol: 2, fragment: false} = ip} <- IPv4.decode(eth.payload),
         {:ok, msg} <- IGMP.decode(ip.payload) do
      case apply_filter(msg, owned) do
        :keep -> frame
        :drop -> :drop
        {:replace, igmp} -> Ethernet.encode(%{eth | payload: IPv4.encode(%{ip | payload: igmp})})
      end
    else
      _ -> frame
    end
  end

  defp apply_filter(%IGMP.Report{group: g}, owned), do: single(g, owned)
  defp apply_filter(%IGMP.Leave{group: g}, owned), do: single(g, owned)

  defp apply_filter(%IGMP.ReportV3{records: recs} = r, owned) do
    case Enum.reject(recs, &MapSet.member?(owned, &1.group)) do
      ^recs -> :keep
      [] -> :drop
      rest -> {:replace, IGMP.encode(%{r | records: rest})}
    end
  end

  defp apply_filter(_query, _owned), do: :keep

  defp single(group, owned), do: if(MapSet.member?(owned, group), do: :drop, else: :keep)
end
