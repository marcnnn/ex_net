defmodule ExNet.IGMP.Host do
  @moduledoc """
  Host side of IGMPv2 (RFC 2236) and IGMPv3 (RFC 3376) for joining multicast
  streams (AES67 receivers), as a pure model plus frame builder.

  The model is `step(host, event) -> {host, frames}`, time in milliseconds:

    * `{:join, group}`, `{:leave, group}` - membership changes (v3: any-source
      joins, i.e. `change_to_exclude` with no sources, and `change_to_include` to
      leave). A change sends one report at once and `robustness - 1`
      retransmissions spaced by random delays up to `unsolicited_ms`.
    * `{:query, %ExNet.IGMP.Query{}}` - a received query. A general query
      schedules a report of every joined group (v3: one report with all records,
      `mode_is_exclude`), a group-specific query one for that group, each after a
      random delay below the query's max response time. A v1/v2 query switches
      a v3 host to v2 compatibility (RFC 3376 7.2.1, timeout simplified to
      `robustness * qqic + max_resp`).
    * `{:report, group}` - a v2 report of another host seen on the link; cancels
      our pending v2 report of that group (suppression; v3 has none).
    * `{:tick, now}` - advances the clock and emits what is due.

  Frames are Ethernet frames (no FCS) from `frame/3`: IPv4 TTL 1, Router Alert
  option, DSCP 48 (CS6), destination the group (v2 report), 224.0.0.2 (v2 leave)
  or 224.0.0.22 (v3 report). Randomness comes from a seeded `:rand` state in the
  struct, so runs are reproducible.

      iex> alias ExNet.IGMP.Host
      iex> h = Host.new(mac: <<2, 0, 0, 0, 0, 1>>, ip: {10, 0, 0, 5}, version: 2)
      iex> {_h, [f]} = Host.step(h, {:join, {239, 69, 1, 1}})
      iex> {:ok, msg} = Host.decode_frame(f)
      iex> msg
      %ExNet.IGMP.Report{version: 2, group: {239, 69, 1, 1}}
  """
  alias ExNet.{Ethernet, IGMP, IPv4}
  alias ExNet.IGMP.{Leave, Query, Record, Report, ReportV3}

  defstruct mac: nil,
            ip: nil,
            version: 3,
            vlan: nil,
            robustness: 2,
            unsolicited_ms: 1000,
            now: 0,
            groups: MapSet.new(),
            compat_until: nil,
            # [{due_ms, kind, group | nil, retransmissions_left}]
            timers: [],
            rand: nil

  @type t :: %__MODULE__{}

  @doc "A host. Options: `mac:`, `ip:` (required), `version:` (2 or 3), `vlan:` (VID), `robustness:`, `unsolicited_ms:`, `seed:`."
  def new(opts) do
    seed = Keyword.get(opts, :seed, 1)

    %__MODULE__{
      mac: Keyword.fetch!(opts, :mac),
      ip: Keyword.fetch!(opts, :ip),
      version: Keyword.get(opts, :version, 3),
      vlan: Keyword.get(opts, :vlan),
      robustness: Keyword.get(opts, :robustness, 2),
      unsolicited_ms: Keyword.get(opts, :unsolicited_ms, 1000),
      rand: :rand.seed_s(:exsss, {seed, seed + 1, seed + 2})
    }
  end

  @doc "The version in use: 2 while in v2 compatibility mode, else the configured one."
  def mode(%__MODULE__{version: 2}), do: 2
  def mode(%__MODULE__{compat_until: t, now: now}) when is_integer(t) and now < t, do: 2
  def mode(_), do: 3

  @doc "Joined groups."
  def groups(%__MODULE__{groups: g}), do: g |> MapSet.to_list() |> Enum.sort()

  @doc "Applies one event; returns the frames to send now."
  def step(h, {:join, g}) do
    if MapSet.member?(h.groups, g) do
      {h, []}
    else
      h = %{h | groups: MapSet.put(h.groups, g)}
      change(cancel(h, g), :join, g)
    end
  end

  def step(h, {:leave, g}) do
    if MapSet.member?(h.groups, g) do
      h = %{h | groups: MapSet.delete(h.groups, g)}
      change(cancel(h, g), :leave, g)
    else
      {h, []}
    end
  end

  def step(h, {:query, %Query{} = q}) do
    h =
      if q.version in [1, 2] and h.version == 3 do
        %{h | compat_until: h.now + h.robustness * 125_000 + q.max_resp * 100}
      else
        h
      end

    max_ms = max(IGMP.decode_code(q.max_resp) * 100, 100)

    cond do
      MapSet.size(h.groups) == 0 ->
        {h, []}

      q.group == {0, 0, 0, 0} and mode(h) == 3 ->
        h |> schedule_once(:general, nil, max_ms) |> no_frames()

      q.group == {0, 0, 0, 0} ->
        Enum.reduce(h.groups, h, fn g, h -> schedule_once(h, :current, g, max_ms) end)
        |> no_frames()

      MapSet.member?(h.groups, q.group) ->
        h |> schedule_once(:current, q.group, max_ms) |> no_frames()

      true ->
        {h, []}
    end
  end

  def step(h, {:report, g}) do
    if mode(h) == 2,
      do: {%{h | timers: Enum.reject(h.timers, &match?({_, :current, ^g, _}, &1))}, []},
      else: {h, []}
  end

  def step(h, {:tick, now}) do
    h = %{h | now: now}
    {due, rest} = Enum.split_with(h.timers, fn {t, _, _, _} -> t <= now end)
    h = %{h | timers: rest}

    due
    |> Enum.sort()
    |> Enum.reduce({h, []}, fn {_, kind, g, left}, {h, acc} ->
      {h, frames} = fire(h, kind, g, left)
      {h, acc ++ frames}
    end)
  end

  defp no_frames(h), do: {h, []}

  defp change(h, what, g), do: fire(h, what, g, h.robustness)

  # sends the message of a timer and reschedules retransmissions
  defp fire(h, kind, g, left) do
    msgs = messages(h, kind, g)
    h = if left > 1, do: later(h, kind, g, left - 1, h.unsolicited_ms), else: h
    {h, Enum.map(msgs, &frame(h, &1, IGMP.encode(&1)))}
  end

  defp messages(h, :join, g) do
    if mode(h) == 3,
      do: [%ReportV3{records: [%Record{type: :change_to_exclude, group: g}]}],
      else: [%Report{version: 2, group: g}]
  end

  defp messages(h, :leave, g) do
    if mode(h) == 3,
      do: [%ReportV3{records: [%Record{type: :change_to_include, group: g}]}],
      else: [%Leave{group: g}]
  end

  defp messages(h, :general, nil) do
    case groups(h) do
      [] -> []
      gs -> [%ReportV3{records: for(g <- gs, do: %Record{type: :mode_is_exclude, group: g})}]
    end
  end

  defp messages(h, :current, g) do
    cond do
      not MapSet.member?(h.groups, g) -> []
      mode(h) == 3 -> [%ReportV3{records: [%Record{type: :mode_is_exclude, group: g}]}]
      true -> [%Report{version: 2, group: g}]
    end
  end

  defp later(h, kind, g, left, max_ms) do
    {d, r} = :rand.uniform_s(max(max_ms, 1), h.rand)
    %{h | rand: r, timers: h.timers ++ [{h.now + d, kind, g, left}]}
  end

  # a query response: keep an earlier pending one (RFC 2236 3, RFC 3376 5.2)
  defp schedule_once(h, kind, g, max_ms) do
    {d, r} = :rand.uniform_s(max_ms, h.rand)
    due = h.now + d

    case Enum.find(h.timers, &match?({_, ^kind, ^g, 1}, &1)) do
      {t, _, _, _} when t <= due -> %{h | rand: r}
      nil -> %{h | rand: r, timers: h.timers ++ [{due, kind, g, 1}]}
      old -> %{h | rand: r, timers: List.delete(h.timers, old) ++ [{due, kind, g, 1}]}
    end
  end

  defp cancel(h, g),
    do: %{
      h
      | timers: Enum.reject(h.timers, fn {_, k, gg, _} -> gg == g and k in [:join, :leave] end)
    }

  @doc """
  The Ethernet frame (no padding, no FCS) carrying IGMP message `msg` (its
  encoding `bin`) from host `h`.
  """
  def frame(h, msg, bin) do
    dst =
      case msg do
        %Report{group: g} -> g
        %Leave{} -> IGMP.all_routers()
        %ReportV3{} -> IGMP.v3_reports()
      end

    ip = %IPv4{
      src: h.ip,
      dst: dst,
      protocol: IGMP.protocol(),
      ttl: 1,
      dscp: 48,
      # Router Alert (RFC 2113)
      options: <<0x94, 4, 0, 0>>,
      payload: bin
    }

    tags = if h.vlan, do: [%{tpid: 0x8100, pcp: 6, dei: 0, vid: h.vlan}], else: []

    Ethernet.encode(%Ethernet{
      dst: Ethernet.multicast_mac(dst),
      src: h.mac,
      tags: tags,
      ethertype: 0x0800,
      payload: IPv4.encode(ip)
    })
  end

  @doc "Decodes an IGMP frame built by `frame/3` back to the message."
  def decode_frame(bin) do
    with {:ok, eth} <- Ethernet.decode(bin),
         {:ok, ip} <- IPv4.decode(eth.payload),
         2 <- ip.protocol do
      IGMP.decode(ip.payload)
    else
      {:error, _} = e -> e
      _ -> {:error, :not_igmp}
    end
  end
end
