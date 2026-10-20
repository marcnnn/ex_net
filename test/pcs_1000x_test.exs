defmodule ExNet.PCS.Base1000XTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExNet.MAC
  alias ExNet.PCS.Base1000X, as: P
  alias ExNet.PCS.Base1000X.{Rx, Sync, Tx}
  alias ExNet.PCS.Code8b10b, as: C

  doctest ExNet.PCS.Base1000X

  @idle {0, false, false}

  defp tx_syms(gmii) do
    {_, syms} =
      Enum.reduce(gmii, {Tx.new(), []}, fn c, {s, acc} ->
        {s, {_, sym}} = Tx.step(s, c)
        {s, [sym | acc]}
      end)

    Enum.reverse(syms)
  end

  test "idle alternates /I1/ and /I2/ so that disparity is corrected" do
    syms = tx_syms(List.duplicate(@idle, 8))
    assert Enum.take(syms, 4) == [C.k(28, 5), C.d(16, 2), C.k(28, 5), C.d(16, 2)]

    # start at RD+ : /I1/ (D5.6)
    s = Tx.new(:pos)
    {s, {_, k}} = Tx.step(s, @idle)
    {_, {_, d}} = Tx.step(s, @idle)
    assert {k, d} == {C.k(28, 5), C.d(5, 6)}
  end

  test "frame: /S/ replaces the first preamble byte, /T/ /R/ close it, idles resume on an even group" do
    for n <- [60, 61] do
      frame = :binary.copy(<<0xA5>>, n)
      gmii = List.duplicate(@idle, 4) ++ MAC.tx_cycles([frame])
      syms = tx_syms(gmii)
      s_at = Enum.find_index(syms, &(&1 == C.k(27, 7)))
      assert s_at == 4
      t_at = Enum.find_index(syms, &(&1 == C.k(29, 7)))

      assert Enum.slice(syms, s_at + 1, 7) ==
               [{:d, 0x55}] |> List.duplicate(6) |> List.flatten() |> Kernel.++([{:d, 0xD5}])

      assert Enum.at(syms, t_at + 1) == C.k(23, 7)
      next_k = Enum.find_index(Enum.drop(syms, t_at), &(&1 == C.k(28, 5))) + t_at
      assert rem(next_k, 2) == 0
      assert (next_k - t_at) in [2, 3]
    end
  end

  test "frame odd and even length leaves /R/ count 1 or 2" do
    counts =
      for n <- [60, 61] do
        syms = tx_syms(List.duplicate(@idle, 2) ++ MAC.tx_cycles([:binary.copy(<<1>>, n)]))
        Enum.count(syms, &(&1 == C.k(23, 7)))
      end

    assert Enum.sort(counts) == [1, 2]
  end

  test "error propagation sends /V/" do
    s = Tx.new()
    {s, _} = Tx.step(s, {0x55, true, false})
    {s, _} = Tx.step(s, {0x55, true, false})
    {_, {_, sym}} = Tx.step(s, {0, true, true})
    assert sym == C.k(30, 7)
  end

  test "sync: acquired after three commas separated by data, six groups from the first comma" do
    codes = P.tx_run(List.duplicate(@idle, 16))
    outs = P.rx_run(codes)

    assert Enum.map(Enum.take(outs, 7), & &1.sync) == [
             false,
             false,
             false,
             false,
             false,
             true,
             true
           ]

    assert Enum.all?(Enum.drop(outs, 5), & &1.sync)
  end

  test "sync state sequence and loss" do
    s = Sync.new()

    seq = [
      {:comma, :comma_detect_1},
      {:data, :acquire_sync_1},
      {:comma, :comma_detect_2},
      {:data, :acquire_sync_2},
      {:comma, :comma_detect_3},
      {:data, :sync_acquired_1}
    ]

    s =
      Enum.reduce(seq, s, fn {class, st}, s ->
        assert %{st: ^st} = s = Sync.step(s, class)
        s
      end)

    assert Sync.in_sync?(s)

    # four invalid groups in a row lose sync
    states = Enum.scan(1..4, s, fn _, s -> Sync.step(s, :invalid) end) |> Enum.map(& &1.st)
    assert states == [:sync_acquired_2, :sync_acquired_3, :sync_acquired_4, :loss_of_sync]

    # an isolated error is forgiven: four good groups return to level 1
    s1 = Sync.step(s, :invalid)
    levels = Enum.scan(1..4, s1, fn _, s -> Sync.step(s, :data) end) |> Enum.map(& &1.st)
    assert levels == [:sync_acquired_2a, :sync_acquired_2a, :sync_acquired_2a, :sync_acquired_1]

    # errors during acquisition restart it
    s = Sync.step(Sync.new(), :comma)
    assert Sync.step(s, :invalid).st == :loss_of_sync
    s = s |> Sync.step(:data) |> Sync.step(:invalid)
    assert s.st == :loss_of_sync
  end

  test "rx reports config ordered sets and idles the GMII side" do
    {_, codes} =
      Enum.reduce(1..20, {Tx.new(), []}, fn _, {s, acc} ->
        {s, {c, _}} = Tx.step(s, @idle)
        {s, [c | acc]}
      end)

    codes = Enum.reverse(codes)
    # a C1 set: K28.5 D21.5 lo hi, built from the encoder with continuing disparity
    {c_codes, _} =
      Enum.map_reduce([C.k(28, 5), C.d(21, 5), {:d, 0xA0}, {:d, 0x01}], rd_after(codes), fn sym,
                                                                                            rd ->
        {code, rd} = C.encode(rd, sym)
        {code, rd}
      end)

    outs = P.rx_run(codes ++ c_codes ++ codes)
    assert [0x01A0] == for(%{config: c} <- outs, c != nil, do: c)
    assert Enum.all?(outs, fn %{gmii: g} -> g == @idle end)
  end

  defp rd_after(codes) do
    Enum.reduce(codes, :neg, fn c, rd ->
      {:ok, _, rd} = C.decode(rd, c)
      rd
    end)
  end

  test "code violation inside a frame raises RX_ER" do
    gmii = List.duplicate(@idle, 20) ++ MAC.tx_cycles([:binary.copy(<<3>>, 60)])
    codes = P.tx_run(gmii)
    bad = List.replace_at(codes, 20 + 30, 0b0000000000)
    outs = P.rx_run(bad)
    assert Enum.any?(outs, fn %{gmii: {_, dv, er}} -> dv and er end)
    assert [{:error, _, _}] = outs |> Enum.map(& &1.gmii) |> MAC.rx_frames()
  end

  property "frames survive the PCS, every group decodes cleanly, idle sets start on even groups" do
    check all(
            lead <- integer(0..9),
            frames <-
              list_of(binary(min_length: 1, max_length: 120), min_length: 1, max_length: 3)
          ) do
      gmii = List.duplicate(@idle, 16 + lead) ++ MAC.tx_cycles(frames) ++ List.duplicate(@idle, 6)
      codes = P.tx_run(gmii)
      assert length(codes) == length(gmii)

      {syms, _} =
        Enum.map_reduce(codes, :neg, fn c, rd ->
          assert {:ok, sym, rd} = C.decode(rd, c)
          {sym, rd}
        end)

      for {sym, i} <- Enum.with_index(syms), sym == C.k(28, 5), do: assert(rem(i, 2) == 0)

      got = codes |> P.rx_run() |> Enum.map(& &1.gmii) |> MAC.rx_frames()
      assert got == Enum.map(frames, &{:ok, MAC.pad(&1)})
    end
  end

  property "rx never raises on arbitrary code groups" do
    check all(codes <- list_of(integer(0..1023), max_length: 200)) do
      outs = P.rx_run(codes)
      assert length(outs) == length(codes)
      assert match?(%Rx{}, Enum.reduce(codes, Rx.new(), fn c, s -> elem(Rx.step(s, c), 0) end))
    end
  end
end
