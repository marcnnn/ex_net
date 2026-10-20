defmodule ExNet.IGMP do
  @moduledoc """
  IGMPv1/v2/v3 messages (the IPv4 payload with protocol 2).

  Structs: `Query` (general, group-specific and v3 group-and-source),
  `Report` (v1/v2 membership report), `Leave` (v2), `ReportV3` (with group
  records). Checksums are computed on encode and verified on decode.

  A query of 8 bytes is v1 (max response 0) or v2; 12 bytes or more is v3.
  The v3 max response code and QQIC use the 8-bit float of RFC 3376,
  `decode_code/1` turns them into time units (1/10 s for max response, 1 s
  for QQIC).

      iex> alias ExNet.IGMP
      iex> r = %IGMP.ReportV3{records: [%IGMP.Record{type: :change_to_exclude, group: {239, 1, 1, 1}, sources: []}]}
      iex> {:ok, ^r} = IGMP.decode(IGMP.encode(r))
      iex> {:ok, %IGMP.Report{version: 2}} = IGMP.decode(IGMP.encode(%IGMP.Report{version: 2, group: {239, 1, 1, 1}}))
  """
  import Bitwise
  alias ExNet.{Checksum, IPv4, Packets}

  defmodule Query do
    @moduledoc false
    defstruct version: 3,
              max_resp: 100,
              group: {0, 0, 0, 0},
              suppress: false,
              qrv: 2,
              qqic: 125,
              sources: []
  end

  defmodule Report do
    @moduledoc false
    defstruct version: 2, group: nil
  end

  defmodule Leave do
    @moduledoc false
    defstruct [:group]
  end

  defmodule Record do
    @moduledoc false
    defstruct [:type, :group, sources: [], aux: <<>>]
  end

  defmodule ReportV3 do
    @moduledoc false
    defstruct records: []
  end

  @record_types %{
    1 => :mode_is_include,
    2 => :mode_is_exclude,
    3 => :change_to_include,
    4 => :change_to_exclude,
    5 => :allow_new_sources,
    6 => :block_old_sources
  }
  @record_codes Map.new(@record_types, fn {k, v} -> {v, k} end)

  @doc "IPv4 protocol number."
  def protocol, do: 2

  @doc "All-hosts (queries) and all-routers (leaves) and IGMPv3 report groups."
  def all_hosts, do: {224, 0, 0, 1}
  def all_routers, do: {224, 0, 0, 2}
  def v3_reports, do: {224, 0, 0, 22}

  def encode(%Query{version: v} = q) when v in [1, 2] do
    msg(0x11, if(v == 1, do: 0, else: q.max_resp), q.group)
  end

  def encode(%Query{version: 3} = q) do
    n = length(q.sources)
    flags = bsl(b(q.suppress), 3) ||| (q.qrv &&& 7)

    fix(
      <<0x11, q.max_resp, 0::16, IPv4.ip_int(q.group)::32, flags, q.qqic, n::16>> <>
        for(s <- q.sources, into: <<>>, do: <<IPv4.ip_int(s)::32>>)
    )
  end

  def encode(%Report{version: 1, group: g}), do: msg(0x12, 0, g)
  def encode(%Report{version: 2, group: g}), do: msg(0x16, 0, g)
  def encode(%Leave{group: g}), do: msg(0x17, 0, g)

  def encode(%ReportV3{records: rs}) do
    recs =
      for r <- rs, into: <<>> do
        <<Map.fetch!(@record_codes, r.type), div(byte_size(r.aux), 4), length(r.sources)::16,
          IPv4.ip_int(r.group)::32>> <>
          for(s <- r.sources, into: <<>>, do: <<IPv4.ip_int(s)::32>>) <> r.aux
      end

    fix(<<0x22, 0, 0::16, 0::16, length(rs)::16>> <> recs)
  end

  def decode(bin) when is_binary(bin) do
    with {:ok, h} <- Packets.header(:igmp, bin),
         :ok <- if(Checksum.valid?(bin), do: :ok, else: {:error, :bad_checksum}) do
      body(h, bin)
    else
      {:error, _} = e -> e
    end
  end

  def decode(_), do: {:error, :not_binary}

  defp body(%{type: 0x11} = h, bin) when byte_size(bin) == 8,
    do:
      {:ok,
       %Query{
         version: if(h.max_resp == 0, do: 1, else: 2),
         max_resp: h.max_resp,
         group: IPv4.ip_tuple(h.group)
       }}

  defp body(%{type: 0x11} = h, <<_::64, flags, qqic, n::16, rest::binary>>) do
    if byte_size(rest) >= 4 * n do
      {:ok,
       %Query{
         version: 3,
         max_resp: h.max_resp,
         group: IPv4.ip_tuple(h.group),
         suppress: (flags &&& 8) != 0,
         qrv: flags &&& 7,
         qqic: qqic,
         sources: sources(rest, n)
       }}
    else
      {:error, :truncated}
    end
  end

  defp body(%{type: 0x11}, _), do: {:error, :bad_length}

  defp body(%{type: 0x12} = h, bin) when byte_size(bin) >= 8,
    do: {:ok, %Report{version: 1, group: IPv4.ip_tuple(h.group)}}

  defp body(%{type: 0x16} = h, bin) when byte_size(bin) >= 8,
    do: {:ok, %Report{version: 2, group: IPv4.ip_tuple(h.group)}}

  defp body(%{type: 0x17} = h, bin) when byte_size(bin) >= 8,
    do: {:ok, %Leave{group: IPv4.ip_tuple(h.group)}}

  defp body(%{type: 0x22}, <<_::32, _::16, n::16, rest::binary>>), do: records(rest, n, [])
  defp body(%{type: t}, _), do: {:error, {:unknown_type, t}}

  defp records(_, 0, acc), do: {:ok, %ReportV3{records: Enum.reverse(acc)}}

  defp records(<<t, aux_len, ns::16, g::32, rest::binary>>, n, acc)
       when byte_size(rest) >= 4 * ns + 4 * aux_len do
    with {:ok, type} <- Map.fetch(@record_types, t) |> ok_or(:bad_record_type) do
      <<srcs::binary-size(4 * ns), aux::binary-size(4 * aux_len), rest::binary>> = rest
      r = %Record{type: type, group: IPv4.ip_tuple(g), sources: sources(srcs, ns), aux: aux}
      records(rest, n - 1, [r | acc])
    end
  end

  defp records(_, _, _), do: {:error, :truncated}

  defp ok_or({:ok, v}, _), do: {:ok, v}
  defp ok_or(:error, e), do: {:error, e}

  defp sources(bin, n), do: for(<<s::32 <- binary_part(bin, 0, 4 * n)>>, do: IPv4.ip_tuple(s))

  defp msg(type, max_resp, group),
    do: fix(<<type, max_resp, 0::16, IPv4.ip_int(group)::32>>)

  # fills in the checksum at bytes 2..3
  defp fix(<<a::binary-size(2), 0::16, rest::binary>> = bin),
    do: <<a::binary, Checksum.checksum(bin)::16, rest::binary>>

  defp b(true), do: 1
  defp b(false), do: 0

  @doc """
  Decodes the 8-bit float of the v3 max response code and QQIC.

      iex> {ExNet.IGMP.decode_code(100), ExNet.IGMP.decode_code(0x80)}
      {100, 128}
  """
  def decode_code(c) when c < 128, do: c
  def decode_code(c), do: bsl(0x10 ||| (c &&& 0xF), 3 + (c >>> 4 &&& 7))
end
