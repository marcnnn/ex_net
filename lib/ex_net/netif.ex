defmodule ExNet.Netif do
  @moduledoc """
  Unprivileged read access to the state of a Linux network interface, for the
  TAP bridge of the card (`ExNet.Tap`) and any other interface.

  | Function | Source |
  |---|---|
  | `mac/1`, `mtu/1`, `up?/1`, `exists?/1` | `/sys/class/net/<if>/{address,mtu,flags,operstate}` |
  | `ipv4_addresses/1` | `:inet.getifaddrs/0` (`{address, netmask}` pairs) |
  | `multicast_macs/1` | `/proc/net/dev_mcast` (link-layer multicast list, what a driver turns into its hash filter) |
  | `joined_groups/1` | `/proc/net/igmp` (IPv4 groups the kernel has joined on the interface) |

  `/proc/net` is the table of the network namespace of the calling process.
  `joined_groups/1` always contains 224.0.0.1 on an interface that is up
  (the all-hosts group), and `multicast_macs/1` its MAC 01:00:5e:00:00:01.
  `up?/1` is the administrative state (`IFF_UP`); `running?/1` is `IFF_RUNNING`
  (carrier, for a TAP: a process has it open).

  All functions return `{:error, :enoent}` for an unknown interface, except
  the predicates, which return `false`.
  """
  import Bitwise

  @sys "/sys/class/net"

  @type ip :: ExNet.IPv4.ip()

  @doc "True if the interface exists."
  @spec exists?(String.t()) :: boolean
  def exists?(ifname), do: File.dir?(Path.join(@sys, ifname))

  @doc """
  The interface's MAC address as a 6-byte binary.

  Interface names with `/` are rejected (`{:error, :einval}`).
  """
  @spec mac(String.t()) :: {:ok, binary} | {:error, atom}
  def mac(ifname) do
    with {:ok, s} <- attr(ifname, "address"),
         <<_::binary-size(17)>> <- s do
      {:ok, ExNet.Ethernet.mac(s)}
    else
      {:error, _} = e -> e
      _ -> {:error, :einval}
    end
  end

  @doc "The MTU in bytes."
  @spec mtu(String.t()) :: {:ok, pos_integer} | {:error, atom}
  def mtu(ifname) do
    with {:ok, s} <- attr(ifname, "mtu"), do: {:ok, String.to_integer(s)}
  end

  @doc "True if the administrative state is up (`IFF_UP`)."
  @spec up?(String.t()) :: boolean
  def up?(ifname), do: flag?(ifname, 0x1)

  @doc "True if the interface is operationally running (`IFF_RUNNING`)."
  @spec running?(String.t()) :: boolean
  def running?(ifname), do: flag?(ifname, 0x40)

  @doc "IPv4 addresses with their netmasks, `[{{10, 0, 0, 1}, {255, 255, 255, 0}}]`."
  @spec ipv4_addresses(String.t()) :: {:ok, [{ip, ip}]} | {:error, atom}
  def ipv4_addresses(ifname) do
    with true <- exists?(ifname),
         {:ok, list} <- :inet.getifaddrs() do
      case List.keyfind(list, String.to_charlist(ifname), 0) do
        nil ->
          {:ok, []}

        {_, opts} ->
          addrs = for {:addr, {_, _, _, _} = a} <- opts, do: a
          masks = for {:netmask, {_, _, _, _} = m} <- opts, do: m
          {:ok, Enum.zip(addrs, masks)}
      end
    else
      false -> {:error, :enoent}
      {:error, _} = e -> e
    end
  end

  @doc """
  The link-layer multicast list (`ip maddr show dev <if>`, link entries) as
  6-byte binaries. Pass it to `ExNet.Multicast.mc_hash/1`.
  """
  @spec multicast_macs(String.t()) :: {:ok, [binary]} | {:error, atom}
  def multicast_macs(ifname) do
    with true <- exists?(ifname),
         {:ok, text} <- File.read("/proc/net/dev_mcast") do
      {:ok, parse_dev_mcast(text, ifname)}
    else
      false -> {:error, :enoent}
      {:error, _} = e -> e
    end
  end

  @doc """
  IPv4 groups the kernel has joined on the interface (`ip maddr show dev
  <if>`, inet entries), in the order of `/proc/net/igmp`.
  """
  @spec joined_groups(String.t()) :: {:ok, [ip]} | {:error, atom}
  def joined_groups(ifname) do
    with true <- exists?(ifname),
         {:ok, text} <- File.read("/proc/net/igmp") do
      {:ok, parse_igmp(text, ifname)}
    else
      false -> {:error, :enoent}
      {:error, _} = e -> e
    end
  end

  @doc """
  Parses `/proc/net/dev_mcast`: `ifindex name refcount global_use addrlen
  hex-address`, one line per address.

      iex> text = "2    eth0    1     0     01005e000001\\n3    tap0    1     0     333300000001\\n"
      iex> ExNet.Netif.parse_dev_mcast(text, "eth0")
      [<<1, 0, 0x5E, 0, 0, 1>>]
  """
  @spec parse_dev_mcast(String.t(), String.t()) :: [binary]
  def parse_dev_mcast(text, ifname) do
    for line <- String.split(text, "\n", trim: true),
        [_idx, ^ifname, _ref, _global, hex] <- [String.split(line)],
        byte_size(hex) == 12,
        {:ok, mac} <- [Base.decode16(hex, case: :mixed)],
        do: mac
  end

  @doc """
  Parses `/proc/net/igmp`. Group lines hold the address as the hex of a
  host-order word (the doctest assumes a little endian machine), so
  `FB0000E0` is 224.0.0.251.

      iex> text = "Idx\\tDevice    : Count Querier\\tGroup    Users Timer\\tReporter\\n" <>
      ...>   "2\\teth0      :     2      V3\\n\\t\\t\\t\\tFB0000E0     1 0:00000000\\t\\t0\\n" <>
      ...>   "\\t\\t\\t\\t010000E0     1 0:00000000\\t\\t0\\n3\\ttap0      :     1      V3\\n\\t\\t\\t\\t010000E0     1 0:00000000\\t\\t0\\n"
      iex> ExNet.Netif.parse_igmp(text, "eth0")
      [{224, 0, 0, 251}, {224, 0, 0, 1}]
  """
  @spec parse_igmp(String.t(), String.t()) :: [ip]
  def parse_igmp(text, ifname) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce({nil, []}, fn line, {cur, acc} ->
      case {String.starts_with?(line, [" ", "\t"]), String.split(line)} do
        {false, [_idx, name | _]} ->
          {String.trim_trailing(name, ":"), acc}

        {true, [<<hex::binary-size(8)>> | _]} when cur == ifname ->
          case Integer.parse(hex, 16) do
            {n, ""} -> {cur, [host_word_ip(n) | acc]}
            _ -> {cur, acc}
          end

        _ ->
          {cur, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # the kernel prints the network-order address as a word of the host
  defp host_word_ip(n) do
    <<a, b, c, d>> = <<n::native-32>>
    {a, b, c, d}
  end

  defp flag?(ifname, bit) do
    with {:ok, s} <- attr(ifname, "flags"),
         {n, _} <- Integer.parse(String.trim_leading(s, "0x"), 16) do
      (n &&& bit) != 0
    else
      _ -> false
    end
  end

  defp attr(ifname, name) do
    if ifname == "" or String.contains?(ifname, ["/", <<0>>]) or ifname in [".", ".."] do
      {:error, :einval}
    else
      with {:ok, s} <- File.read(Path.join([@sys, ifname, name])), do: {:ok, String.trim(s)}
    end
  end
end
