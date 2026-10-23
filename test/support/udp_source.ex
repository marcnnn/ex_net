defmodule ExNet.UdpSource do
  @moduledoc false
  # Closed-loop UDP payload source (`ExNet.RTL.Ifc.udp_tx/0`) for `ExNet.RtlCase.drive/4`:
  # beats of packets `{payload, {dst_ip_tuple, port}}`, `tvalid` pauses only between beats
  # (an offered beat is held until `tready`), `tuser` constant over a packet.
  import Bitwise
  alias ExNet.RTL.Ifc

  def new(packets) do
    q =
      for {payload, {ip, port}} <- packets,
          {b, i} <- Enum.with_index(beats(payload)),
          do: {b, %{ip: ExNet.IPv4.ip_int(ip), port: port, len: byte_size(payload)}, i}

    %{q: q, offer: nil}
  end

  def done?(%{q: q}), do: q == []

  @doc "Beats `{data, keep, last?}` of a payload (little endian lanes)."
  def beats(p) do
    chunks = for <<c::binary-size(8) <- p>>, do: c
    rest = binary_part(p, 8 * length(chunks), byte_size(p) - 8 * length(chunks))
    all = chunks ++ if(rest == <<>>, do: [], else: [rest])

    for {c, i} <- Enum.with_index(all, 1) do
      bits = 8 * byte_size(c)
      <<v::little-size(bits)>> = c
      {v, (1 <<< byte_size(c)) - 1, i == length(all)}
    end
  end

  @doc "`{inputs, offer}` for this cycle; `prefix` like `\"s0_axis\"` or `\"s_axis\"`."
  def offer(st, prefix, pause_pct) do
    offer =
      cond do
        st.offer != nil -> st.offer
        st.q != [] and :rand.uniform(100) > pause_pct -> hd(st.q)
        true -> nil
      end

    p = fn k -> :"#{prefix}_#{k}" end

    inputs =
      case offer do
        nil ->
          %{p.(:tvalid) => 0}

        {{d, k, l}, user, _} ->
          %{
            p.(:tvalid) => 1,
            p.(:tdata) => d,
            p.(:tkeep) => k,
            p.(:tlast) => if(l, do: 1, else: 0),
            p.(:tuser) => Ifc.pack_udp_tx(user)
          }
      end

    {inputs, offer}
  end

  @doc "State after the cycle: the offer is consumed when `tready` was high."
  def settle(st, nil, _ready), do: %{st | offer: nil}
  def settle(st, _offer, 1), do: %{st | q: tl(st.q), offer: nil}
  def settle(st, offer, _), do: %{st | offer: offer}
end
