defmodule ExNet.RTL.Code8b10bTest do
  use ExUnit.Case, async: true

  alias ExNet.PCS.Code8b10b, as: C
  alias ExNet.RTL.Code8b10b, as: Hw
  alias ExNet.RtlCase

  defp rdb(:pos), do: 1
  defp rdb(:neg), do: 0

  # every (k, byte) pair, 512, at both disparities
  defp enc_events,
    do: for(rd <- 0..1, k <- 0..1, byte <- 0..255, do: %{k: k, data: byte, rd: rd})

  defp enc_expected(%{k: k, data: byte, rd: rd}) do
    sym = {if(k == 1, do: :k, else: :d), byte}

    if k == 1 and byte not in C.valid_k() do
      %{code: 0, rd_next: rd, bad: 1}
    else
      {code, rd2} = C.encode(if(rd == 1, do: :pos, else: :neg), sym)
      %{code: code, rd_next: rdb(rd2), bad: 0}
    end
  end

  # all 1024 code groups at both disparities
  defp dec_events, do: for(rd <- 0..1, code <- 0..1023, do: %{code: code, rd: rd})

  defp dec_expected(%{code: code, rd: rd}) do
    case C.decode(if(rd == 1, do: :pos, else: :neg), code) do
      {:ok, {kind, byte}, rd2} ->
        %{data: byte, k: b(kind == :k), code_err: 0, disp_err: 0, rd_next: rdb(rd2)}

      {:error, :disparity_error, rd2} ->
        {kind, byte} = C.symbol(code)
        %{data: byte, k: b(kind == :k), code_err: 0, disp_err: 1, rd_next: rdb(rd2)}

      {:error, :invalid_code, rd2} ->
        %{data: 0, k: 0, code_err: 1, disp_err: 0, rd_next: rdb(rd2)}
    end
  end

  defp b(true), do: 1
  defp b(false), do: 0

  test "encoder matches the model for all 256 data + 12 control symbols (and rejects other K) at both RD" do
    evs = enc_events()
    outs = RtlCase.run(Hw.build_enc(), evs)
    assert outs == Enum.map(evs, &enc_expected/1)
    assert Enum.count(outs, &(&1.bad == 0)) == 2 * (256 + 12)
  end

  test "decoder matches the model for all 1024 code groups at both RD" do
    evs = dec_events()
    outs = RtlCase.run(Hw.build_dec(), evs)
    assert outs == Enum.map(evs, &dec_expected/1)
    assert Enum.count(outs, &(&1.code_err == 0 and &1.disp_err == 0)) == length(C.table())
  end

  @tag :verilator
  test "encoder co-simulates" do
    :rand.seed(:exsss, {4, 5, 6})
    RtlCase.cosim!(Hw.build_enc(), Enum.take_random(enc_events(), 300))
  end

  @tag :verilator
  test "decoder co-simulates" do
    :rand.seed(:exsss, {7, 8, 9})
    RtlCase.cosim!(Hw.build_dec(), Enum.take_random(dec_events(), 300))
  end
end
