defmodule ExNet.IgmpBench do
  @moduledoc false
  # Closed-loop test bench for ExNet.RTL.Igmp: commands, received frames and a sink with
  # random stalls driven from a script; the transmitted frames come back with their cycle.
  import Bitwise
  alias ExNet.{Ethernet, IGMP, IPv4, RtlCase}
  alias ExNet.IGMP.Host

  @mac <<2, 0, 0, 0, 0, 0x42>>
  @ip {10, 1, 2, 3}
  @querier_mac <<2, 0, 0, 0, 0, 0x99>>
  @querier_ip {10, 1, 2, 1}

  def mac, do: @mac
  def ip, do: @ip

  @doc "Static inputs; `opts`: `:v2_only`, `:robustness`, `:unsol_ms`, `:vlan` (VID)."
  def cfg(opts \\ []) do
    base = %{
      src_mac: :binary.decode_unsigned(@mac),
      src_ip: IPv4.ip_int(@ip),
      v2_only: Keyword.get(opts, :v2_only, 0),
      robustness: Keyword.get(opts, :robustness, 2),
      unsol_ms: Keyword.get(opts, :unsol_ms, 1000)
    }

    if v = Keyword.get(opts, :vlan), do: Map.put(base, :vlan_id, v), else: base
  end

  @doc "The BEAM host with the same identity, to build the frames the RTL must produce."
  def host(opts \\ []), do: Host.new(mac: @mac, ip: @ip, vlan: Keyword.get(opts, :vlan))

  @doc "The frame the RTL sends for `msg` (an `ExNet.IGMP` struct)."
  def expect(msg, opts \\ []), do: Host.frame(host(opts), msg, IGMP.encode(msg))

  @doc """
  A query as a querier sends it (padded to 60 bytes). Options: `:dst` (default 224.0.0.1 for a
  general query, else the group), `:tags` (list of VIDs), `:ihl_pad` (extra option words after the
  Router Alert), `:corrupt` (flip a bit of the IGMP checksum).
  """
  def query_frame(%IGMP.Query{} = q, opts \\ []), do: igmp_frame(IGMP.encode(q), q.group, opts)

  def igmp_frame(bin, group, opts \\ []) do
    bin = if opts[:corrupt], do: flip(bin), else: bin
    dst = Keyword.get(opts, :dst, if(group == {0, 0, 0, 0}, do: IGMP.all_hosts(), else: group))

    ip =
      IPv4.encode(%IPv4{
        src: Keyword.get(opts, :src, @querier_ip),
        dst: dst,
        protocol: 2,
        ttl: 1,
        dscp: 48,
        options:
          <<0x94, 4, 0, 0>> <> :binary.copy(<<1, 1, 1, 1>>, Keyword.get(opts, :ihl_pad, 0)),
        payload: bin
      })

    tags = for vid <- Keyword.get(opts, :tags, []), do: %{tpid: 0x8100, pcp: 6, dei: 0, vid: vid}

    f =
      Ethernet.encode(%Ethernet{
        dst: Ethernet.multicast_mac(dst),
        src: Keyword.get(opts, :src_mac, @querier_mac),
        tags: tags,
        ethertype: 0x0800,
        payload: ip
      })

    pad(f)
  end

  @doc "A v2 membership report of another host."
  def other_report(group, opts \\ []) do
    igmp_frame(
      IGMP.encode(%IGMP.Report{version: 2, group: group}),
      group,
      [dst: group, src: {10, 1, 2, 77}, src_mac: <<2, 0, 0, 0, 0, 0x77>>] ++ opts
    )
  end

  defp flip(<<a, b, c, rest::binary>>), do: <<a, b, bxor(c, 0x10), rest::binary>>
  defp pad(f) when byte_size(f) < 60, do: f <> :binary.copy(<<0>>, 60 - byte_size(f))
  defp pad(f), do: f

  @doc "Input maps (one per beat) of `frame` as the classifier presents it."
  def rx_inputs(frame, opts \\ []) do
    {:ok, eth} = Ethernet.decode(frame)
    chunks = frame |> :binary.bin_to_list() |> Enum.chunk_every(8)
    last = length(chunks) - 1

    for {ch, i} <- Enum.with_index(chunks) do
      d = ch |> Enum.with_index() |> Enum.reduce(0, fn {x, k}, a -> a ||| x <<< (8 * k) end)

      %{
        s_tdata: d,
        s_tkeep: (1 <<< length(ch)) - 1,
        s_tlast: if(i == last, do: 1, else: 0),
        s_tuser: if(i == last and opts[:bad], do: 1, else: 0),
        s_tvalid: 1,
        s_sof: if(i == 0, do: 1, else: 0),
        s_ntags: length(eth.tags),
        s_ethertype: Keyword.get(opts, :ethertype, 0x0800),
        s_ip_valid: Keyword.get(opts, :ip_valid, 1),
        s_ip_proto: Keyword.get(opts, :proto, 2),
        s_kind: 1
      }
    end
  end

  @doc """
  Runs `script` (`{cycle, {:join, g} | {:leave, g} | {:rx, frame} | {:rx, frame, opts}}`) for
  `cycles` cycles. Options: `:cfg` (see `cfg/1`, a map), `:stall` (percent of cycles with the
  sink not ready), `:seed`, `:groups`, `:clk_hz`, `:vlan`. Returns `%{frames: [{cycle, bin}],
  outs, events, errs: [cycle], done: [cycle]}`.
  """
  def run(script, cycles, opts \\ []) do
    :rand.seed(:exsss, {Keyword.get(opts, :seed, 1), 7, 9})
    stall = Keyword.get(opts, :stall, 0)
    cfg = Keyword.get(opts, :cfg, cfg(vlan: opts[:vlan]))
    mod = module(opts)

    cmds = for {t, {k, g}} <- script, k in [:join, :leave], do: {t, k, g}
    rxs = for {t, {:rx, f}} <- script, do: {t, rx_inputs(f)}
    rxs = rxs ++ for {t, {:rx, f, o}} <- script, do: {t, rx_inputs(f, o)}

    init = %{
      cmds: Enum.sort(cmds),
      cur: nil,
      rxs: Enum.sort_by(rxs, &elem(&1, 0)),
      rx_cur: [],
      frames: [],
      beats: <<>>,
      errs: [],
      done: [],
      sent: 0
    }

    {events, outs, acc} =
      RtlCase.drive(mod, init, cycles, fn acc, i ->
        {rx_in, acc} = next_rx(acc, i)
        {cmd, acc} = next_cmd(acc, i)
        ready = if :rand.uniform(100) > stall, do: 1, else: 0

        inputs =
          cfg
          |> Map.merge(rx_in)
          |> Map.merge(cmd)
          |> Map.put(:m_axis_tready, ready)
          |> Map.put(:rd_idx, 0)

        {inputs, fn o -> settle(acc, o, inputs, ready, i) end}
      end)

    %{
      frames: Enum.reverse(acc.frames),
      outs: outs,
      events: events,
      errs: Enum.reverse(acc.errs),
      done: Enum.reverse(acc.done)
    }
  end

  def module(opts) do
    ExNet.RTL.Igmp.build(
      groups: Keyword.get(opts, :groups, 4),
      clk_hz: Keyword.get(opts, :clk_hz, 20_000),
      vlan: Keyword.get(opts, :vlan) != nil
    )
  end

  defp next_rx(%{rx_cur: [b | rest]} = acc, _i), do: {b, %{acc | rx_cur: rest}}

  defp next_rx(%{rxs: [{t, [b | rest]} | more]} = acc, i) when t <= i,
    do: {b, %{acc | rxs: more, rx_cur: rest}}

  defp next_rx(acc, _), do: {%{}, acc}

  defp next_cmd(%{cur: nil, cmds: [{t, k, g} | more]} = acc, i) when t <= i,
    do: {cmd_inputs(k, g), %{acc | cur: {k, g}, cmds: more}}

  defp next_cmd(%{cur: {k, g}} = acc, _), do: {cmd_inputs(k, g), acc}
  defp next_cmd(acc, _), do: {%{}, acc}

  defp cmd_inputs(k, g),
    do: %{cmd_valid: 1, cmd_leave: if(k == :leave, do: 1, else: 0), cmd_group: IPv4.ip_int(g)}

  defp settle(acc, o, inputs, ready, i) do
    acc =
      if Map.get(inputs, :cmd_valid) == 1 and o.cmd_ready == 1,
        do: %{acc | cur: nil},
        else: acc

    acc = if o.cmd_err == 1, do: %{acc | errs: [i | acc.errs]}, else: acc
    acc = if o.cmd_done == 1, do: %{acc | done: [i | acc.done]}, else: acc

    if o.m_axis_tvalid == 1 and ready == 1 do
      k = Enum.count(0..7, &((o.m_axis_tkeep >>> &1 &&& 1) == 1))
      cur = acc.beats <> binary_part(<<o.m_axis_tdata::little-size(64)>>, 0, k)

      if o.m_axis_tlast == 1,
        do: %{acc | beats: <<>>, frames: [{i, cur} | acc.frames]},
        else: %{acc | beats: cur}
    else
      acc
    end
  end
end
