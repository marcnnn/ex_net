defmodule ExNet.Tap do
  @moduledoc """
  An existing Linux TAP interface opened from the BEAM: whole Ethernet frames
  without FCS in both directions, the TAP side of the card's NIC bridge.

  The interface has to exist already and be accessible to the BEAM's user. As
  root, once (`aes0` is the card's conventional name):

      ip tuntap add dev aes0 mode tap user $USER
      ip addr add 10.0.0.1/24 dev aes0
      ip link set aes0 up

  `open/2` opens `/dev/net/tun` with `TUNSETIFF` (`IFF_TAP | IFF_NO_PI`),
  non-blocking, through a small NIF (`c_src/ex_net_tap_nif.c`, built by
  `mix compile` when `make` and a C compiler exist) and selects it with
  `enif_select`. This process reads the frames in batches and sends each to the
  owner (default: the caller of `open/2`):

      {:ex_net_tap, tap, frame}

  `write/2` sends a frame to the kernel and returns `:ok` or `{:error, reason}`
  (`:eagain` when the kernel's queue is full, `:emsgsize`, `:enetdown`). The
  Tap stops when `close/1` is called or the owner dies; the interface itself
  stays. While the interface is administratively down the kernel neither
  delivers nor accepts frames. A frame the kernel sends before the process
  opened the TAP is lost.

  Reading the interface state (MAC, MTU, addresses, multicast lists) needs no
  privileges and no open TAP: see `ExNet.Netif`. The kernel's IGMP frames
  arrive here like any other; `ExNet.IGMP.Filter` removes the records of
  hardware-owned groups, `ExNet.Multicast.mc_hash_of/1` turns the multicast list
  into the receive filter.

  Tests with a real TAP run in a rootless container, see the README
  ("TAP interface").
  """
  use GenServer

  alias ExNet.Tap.Nif

  defstruct [:ifname, :ref, :owner, :mon]

  @type t :: GenServer.server()

  @doc """
  Opens the TAP `ifname` and starts the process. Options: `:owner` (receives the
  frames, default `self()`), `:name` (registered name).

  An interface that does not exist is `{:error, :enoent}` (a privileged
  `TUNSETIFF` would otherwise create a temporary one). Other errors:
  `{:error, :nif_unavailable}`, `{:error, :enoent}` also for a missing `/dev/net/tun`,
  `{:error, :eacces}` / `{:error, :eperm}` (no permission on `/dev/net/tun` or
  the interface belongs to another user), `{:error, :ebusy}` (already open),
  `{:error, :einval}` (not a TAP interface).
  """
  @spec open(String.t(), keyword) :: {:ok, pid} | {:error, atom}
  def open(ifname, opts \\ []) when is_binary(ifname), do: start(:start, ifname, opts)

  @doc "Like `open/2`, linked to the caller (for a supervisor)."
  @spec start_link(String.t(), keyword) :: {:ok, pid} | {:error, atom}
  def start_link(ifname, opts \\ []) when is_binary(ifname), do: start(:start_link, ifname, opts)

  @doc false
  def child_spec({ifname, opts}),
    do: %{id: {__MODULE__, ifname}, start: {__MODULE__, :start_link, [ifname, opts]}}

  defp start(fun, ifname, opts) do
    {name, opts} = Keyword.pop(opts, :name)
    opts = Keyword.put_new(opts, :owner, self())
    gen_opts = if name, do: [name: name], else: []

    case apply(GenServer, fun, [__MODULE__, {ifname, opts}, gen_opts]) do
      {:error, reason} -> {:error, reason}
      other -> other
    end
  end

  @doc "Sends one Ethernet frame (no FCS) to the kernel."
  @spec write(t, iodata) :: :ok | {:error, atom}
  def write(tap, frame), do: GenServer.call(tap, {:write, IO.iodata_to_binary(frame)})

  @doc "Closes the TAP; the interface stays."
  @spec close(t) :: :ok
  def close(tap) do
    GenServer.stop(tap)
  catch
    :exit, _ -> :ok
  end

  @doc "True when the NIF is built and loaded."
  @spec available?() :: boolean
  def available?, do: Nif.loaded?()

  @impl true
  def init({ifname, opts}) do
    owner = Keyword.fetch!(opts, :owner)

    with true <- Nif.loaded?() or {:error, :nif_unavailable},
         true <- ExNet.Netif.exists?(ifname) or {:error, :enoent},
         {:ok, ref} <- Nif.open(ifname) do
      mon = Process.monitor(owner)
      send(self(), {:ex_net_tap_ready, ref})
      {:ok, %__MODULE__{ifname: ifname, ref: ref, owner: owner, mon: mon}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:write, frame}, _from, s), do: {:reply, Nif.write(s.ref, frame), s}

  @impl true
  def handle_info({:ex_net_tap_ready, ref}, %{ref: ref} = s) do
    drain(s)
    {:noreply, s}
  end

  def handle_info({:DOWN, mon, :process, _, _}, %{mon: mon} = s), do: {:stop, :normal, s}
  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, %{ref: ref}), do: Nif.close(ref)

  defp drain(s) do
    case Nif.recv(s.ref) do
      {:ok, frames, state} ->
        for f <- frames, do: send(s.owner, {:ex_net_tap, self(), f})
        if state == :more, do: drain(s)

      {:error, reason} ->
        exit({:tap_read, reason})
    end
  end
end
