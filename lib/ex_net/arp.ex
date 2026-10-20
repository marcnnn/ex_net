defmodule ExNet.ARP do
  @moduledoc """
  ARP for Ethernet/IPv4 (28 bytes). Other hardware or protocol types are
  rejected.

      iex> a = %ExNet.ARP{op: :request, sha: <<2, 0, 0, 0, 0, 1>>, spa: {10, 0, 0, 1},
      ...>   tha: <<0::48>>, tpa: {10, 0, 0, 2}}
      iex> {:ok, ^a} = ExNet.ARP.decode(ExNet.ARP.encode(a))
  """
  alias ExNet.{IPv4, Packets}

  defstruct [:op, :sha, :spa, :tha, :tpa]

  def encode(%__MODULE__{} = a) do
    Packets.encode_header(:arp, %{
      oper: oper(a.op),
      sha: :binary.decode_unsigned(a.sha),
      spa: IPv4.ip_int(a.spa),
      tha: :binary.decode_unsigned(a.tha),
      tpa: IPv4.ip_int(a.tpa)
    })
  end

  @doc "Decodes an ARP payload; trailing Ethernet padding is ignored."
  def decode(bin) when is_binary(bin) do
    case Packets.header(:arp, bin) do
      {:ok, %{oper: o} = h} when o in [1, 2] ->
        {:ok,
         %__MODULE__{
           op: if(o == 1, do: :request, else: :reply),
           sha: <<h.sha::48>>,
           spa: IPv4.ip_tuple(h.spa),
           tha: <<h.tha::48>>,
           tpa: IPv4.ip_tuple(h.tpa)
         }}

      {:ok, _} ->
        {:error, :bad_opcode}

      {:error, {:assert_failed, _, _}} ->
        {:error, :unsupported_arp}

      {:error, _} = e ->
        e
    end
  end

  def decode(_), do: {:error, :not_binary}

  defp oper(:request), do: 1
  defp oper(:reply), do: 2
end
