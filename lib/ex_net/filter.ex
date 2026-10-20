defmodule ExNet.Filter do
  @moduledoc """
  RX filter reference: a runtime-configured, ordered match table deciding
  per frame whether to drop it, hand it to the host, or steer it to stream
  engine `n`. The first matching rule wins (hardware: lowest table index);
  frames matching nothing get the `default` action. Frames with a bad FCS are
  always dropped.

  `key/1` is the header extraction the hardware parser has to reproduce: it
  skips up to two VLAN tags and IPv4 options, and yields `nil` for fields that
  do not apply. UDP ports are only extracted from unfragmented packets (a
  fragment never matches a UDP rule), and an IPv4 header with a bad checksum
  yields no IP fields.

  Rule match keys, all optional and ANDed:

    * `:dst_mac` - 6 byte binary, or `{value, mask}` binaries
    * `:multicast` - `true`: group bit of the destination MAC set
    * `:vlan` - outermost tag's VID
    * `:ethertype` - EtherType after all tags
    * `:ip_proto`, `:ip_dst` (tuple), `:udp_dst_port` (integer or range)

  Actions: `:drop`, `:host`, `{:stream, n}`.

      iex> alias ExNet.{Filter, Ethernet, IPv4, UDP}
      iex> f = Filter.new(default: :drop)
      ...>   |> Filter.add(%{ip_dst: {239, 69, 1, 1}, udp_dst_port: 5004}, {:stream, 3})
      ...>   |> Filter.add(%{ethertype: 0x0806}, :host)
      iex> udp = UDP.encode(%UDP{src_port: 1, dst_port: 5004, payload: "x"}, {10, 0, 0, 1}, {239, 69, 1, 1})
      iex> ip = IPv4.encode(%IPv4{src: {10, 0, 0, 1}, dst: {239, 69, 1, 1}, protocol: 17, payload: udp})
      iex> frame = Ethernet.encode(%Ethernet{dst: Ethernet.multicast_mac({239, 69, 1, 1}), src: <<2, 0, 0, 0, 0, 1>>, ethertype: 0x0800, payload: ip})
      iex> Filter.classify(f, frame)
      {:stream, 3}
      iex> Filter.classify(f, frame, false)
      :drop
  """
  alias ExNet.{Ethernet, IPv4, Packets}

  defstruct rules: [], default: :drop

  @type action :: :drop | :host | {:stream, non_neg_integer()}

  def new(opts \\ []), do: %__MODULE__{default: Keyword.get(opts, :default, :drop)}

  @doc "Appends a rule (lower priority than all existing ones)."
  def add(%__MODULE__{} = f, match, action) when is_map(match) or is_list(match) do
    unless action in [:drop, :host] or match?({:stream, n} when is_integer(n) and n >= 0, action),
      do: raise(ArgumentError, "bad action #{inspect(action)}")

    %{f | rules: f.rules ++ [{Map.new(match), action}]}
  end

  @doc "Header fields the match table looks at."
  def key(frame) when is_binary(frame) do
    base = %{
      dst_mac: nil,
      vlan: nil,
      ethertype: nil,
      ip_proto: nil,
      ip_dst: nil,
      udp_dst_port: nil,
      fragment: false
    }

    case frame do
      <<dst::binary-size(6), _::binary>> ->
        base = %{base | dst_mac: dst}

        case Ethernet.decode(frame) do
          {:ok, eth} -> ip_fields(%{base | ethertype: eth.ethertype, vlan: vlan(eth.tags)}, eth)
          {:error, _} -> base
        end

      _ ->
        base
    end
  end

  defp vlan([%{vid: v} | _]), do: v
  defp vlan([]), do: nil

  defp ip_fields(key, %{ethertype: 0x0800, payload: p}) do
    case IPv4.decode(p) do
      {:ok, ip} ->
        key = %{key | ip_proto: ip.protocol, ip_dst: ip.dst, fragment: ip.fragment}

        with 17 <- ip.protocol,
             false <- ip.fragment,
             {:ok, u} <- Packets.header(:udp, ip.payload) do
          %{key | udp_dst_port: u.dst_port}
        else
          _ -> key
        end

      {:error, _} ->
        key
    end
  end

  defp ip_fields(key, _), do: key

  @doc "Action for `frame` (without FCS); `fcs_ok = false` always drops."
  def classify(%__MODULE__{} = f, frame, fcs_ok \\ true) do
    {action, _} = classify_rule(f, frame, fcs_ok)
    action
  end

  @doc "Like `classify/3` but also returns the matching rule index (`nil` for the default)."
  def classify_rule(_f, _frame, false), do: {:drop, nil}

  def classify_rule(%__MODULE__{} = f, frame, true) do
    key = key(frame)

    f.rules
    |> Enum.with_index()
    |> Enum.find_value({f.default, nil}, fn {{m, action}, i} ->
      if matches?(m, key), do: {action, i}
    end)
  end

  defp matches?(m, key), do: Enum.all?(m, fn {k, v} -> field(k, v, key) end)

  defp field(:dst_mac, {v, mask}, %{dst_mac: d}) when is_binary(d),
    do: masked(d, mask) == masked(v, mask)

  defp field(:dst_mac, v, %{dst_mac: d}), do: d == v

  defp field(:multicast, want, %{dst_mac: d}) when is_binary(d),
    do: Ethernet.multicast_mac?(d) == want

  defp field(:vlan, v, %{vlan: x}), do: x == v
  defp field(:ethertype, v, %{ethertype: x}), do: x == v
  defp field(:ip_proto, v, %{ip_proto: x}), do: x == v
  defp field(:ip_dst, v, %{ip_dst: x}), do: x == v
  defp field(:udp_dst_port, %Range{} = r, %{udp_dst_port: x}), do: is_integer(x) and x in r
  defp field(:udp_dst_port, v, %{udp_dst_port: x}), do: x == v
  defp field(_, _, _), do: false

  defp masked(a, m) do
    <<x::48>> = a
    <<y::48>> = m
    Bitwise.band(x, y)
  end
end
