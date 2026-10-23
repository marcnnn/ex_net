defmodule ExNet.RTL.UdpTxTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  alias ExNet.RTL.UdpTx
  alias ExNet.{RtlCase, UdpSource}

  @moduletag timeout: 300_000

  @cfg %{
    src_mac: <<2, 0, 0, 0, 0, 0x42>>,
    src_ip: {10, 1, 2, 3},
    uc_mac: <<0xA0, 1, 2, 3, 4, 5>>,
    src_port: 5004,
    ttl: 32,
    tos: 0xB8
  }

  defp cfg_inputs do
    %{
      src_mac: :binary.decode_unsigned(@cfg.src_mac),
      src_ip: ExNet.IPv4.ip_int(@cfg.src_ip),
      uc_mac: :binary.decode_unsigned(@cfg.uc_mac),
      src_port: @cfg.src_port,
      ttl: @cfg.ttl,
      tos: @cfg.tos,
      tag: 0x5A
    }
  end

  # Closed loop: source with pauses between beats (never inside an offered beat), sink with
  # stalls. Returns the frames as `{bytes, tusers}`.
  defp run(packets, seed, pause_pct, stall_pct) do
    :rand.seed(:exsss, {seed, 5, 9})
    src = UdpSource.new(packets)
    init = %{src: src, cur: <<>>, tusers: [], frames: []}
    n = length(src.q) * 12 + 200

    {events, outs, acc} =
      RtlCase.drive(UdpTx.build(), init, n, fn acc, _i ->
        {src_in, offer} = UdpSource.offer(acc.src, "s_axis", pause_pct)
        ready = if :rand.uniform(100) > stall_pct, do: 1, else: 0
        inputs = cfg_inputs() |> Map.merge(src_in) |> Map.put(:m_axis_tready, ready)

        {inputs,
         fn o ->
           acc = %{acc | src: UdpSource.settle(acc.src, offer, o.s_axis_tready)}

           if o.m_axis_tvalid == 1 and ready == 1 do
             k = Enum.count(0..7, &((o.m_axis_tkeep >>> &1 &&& 1) == 1))
             cur = acc.cur <> binary_part(<<o.m_axis_tdata::little-size(64)>>, 0, k)
             tusers = [o.m_axis_tuser | acc.tusers]

             if o.m_axis_tlast == 1 do
               %{acc | cur: <<>>, tusers: [], frames: [{cur, Enum.reverse(tusers)} | acc.frames]}
             else
               %{acc | cur: cur, tusers: tusers}
             end
           else
             acc
           end
         end}
      end)

    {events, outs, Enum.reverse(acc.frames)}
  end

  defp expected(packets),
    do:
      for(
        {{payload, dest}, id} <- Enum.with_index(packets),
        do: UdpTx.model(payload, dest, @cfg, id)
      )

  defp verify(packets, frames) do
    assert Enum.map(frames, &elem(&1, 0)) == expected(packets)

    for {_, [first | rest]} <- frames do
      assert first == 0x5A
      assert Enum.all?(rest, &(&1 == 0))
    end
  end

  defp packet do
    gen all(
          len <- one_of([integer(1..20), integer(1..200)]),
          payload <- binary(length: len),
          dst <-
            one_of([
              tuple({integer(224..239), integer(0..255), integer(0..255), integer(0..255)}),
              tuple({integer(1..223), integer(0..255), integer(0..255), integer(0..255)})
            ]),
          port <- integer(0..65535)
        ) do
      {payload, {dst, port}}
    end
  end

  property "frames equal the BEAM codecs, with source pauses and sink stalls" do
    check all(
            packets <- list_of(packet(), min_length: 1, max_length: 5),
            seed <- integer(1..10_000),
            pause <- member_of([0, 30]),
            stall <- member_of([0, 40]),
            max_runs: 25
          ) do
      {_, _, frames} = run(packets, seed, pause, stall)
      verify(packets, frames)
    end
  end

  test "every payload length from 1 to 24 bytes (all tail cases)" do
    packets =
      for len <- 1..24,
          do:
            {:binary.list_to_bin(for(i <- 1..len, do: rem(i * 29 + len, 255) + 1)),
             {{239, 69, 1, 1}, 5004}}

    {_, _, frames} = run(packets, 1, 0, 0)
    verify(packets, frames)
  end

  test "after the first beat the output is gapless with an always-valid source" do
    packets = [{:binary.copy(<<7>>, 100), {{239, 1, 2, 3}, 319}}]
    {_, outs, frames} = run(packets, 1, 0, 0)
    verify(packets, frames)
    valid = Enum.map(outs, & &1.m_axis_tvalid)
    first = Enum.find_index(valid, &(&1 == 1))
    n = Enum.count(valid, &(&1 == 1))
    assert Enum.slice(valid, first, n) == List.duplicate(1, n)
  end

  test "multicast MAC derivation and the IPv4 checksum validate in an independent decoder" do
    packets = [{"abc", {{239, 129, 3, 4}, 5004}}, {"abc", {{192, 168, 1, 9}, 5004}}]
    {_, _, frames} = run(packets, 3, 0, 0)

    for {{f, _}, {_, {ip, _}}} <- Enum.zip(frames, packets) do
      {:ok, eth} = ExNet.Ethernet.decode(f)
      {:ok, ipv4} = ExNet.IPv4.decode(eth.payload)
      assert ipv4.dst == ip and ipv4.ttl == 32 and ipv4.df
      assert eth.dst == if(ip == {192, 168, 1, 9}, do: @cfg.uc_mac, else: <<1, 0, 0x5E, 1, 3, 4>>)
    end
  end

  @tag :verilator
  property "Verilator equals the BEAM simulator" do
    check all(packets <- list_of(packet(), min_length: 1, max_length: 3), max_runs: 3) do
      {events, _, _} = run(packets, 7, 20, 20)
      RtlCase.cosim!(UdpTx.build(), events)
    end
  end
end
