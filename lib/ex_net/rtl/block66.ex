defmodule ExNet.RTL.Block66 do
  @moduledoc """
  64b/66b block encoder and decoder (Clause 49) as combinational hardware, the
  same function as `ExNet.PCS.Block66.encode/1` and `decode_or_error/1`.

  `encode/2` and `decode/2` return expressions for use inside other modules;
  `encoder/0` and `decoder/0` are standalone modules. Both are purely
  combinational (latency 0, one word per cycle).

  Module `pcs10gr_enc`: inputs `data` (64, lane `i` in bits `8i+7..8i`), `ctl`
  (8, bit `i` set for a control character in lane `i`); outputs `hdr` (2, sync
  header: 1 = data block `01`, 2 = control block `10`, bit 0 is sent first) and
  `payload` (64, bit 0 sent first). A word with no valid encoding (including an
  invalid mix of lanes) gives the error block, `hdr = 2`, type `0x1E`, eight
  error codes.

  Module `pcs10gr_dec`: inputs `hdr` (2), `payload` (64); outputs `data` (64),
  `ctl` (8). `hdr = 1` is a data word; `hdr = 2` is decoded by block type; a bad
  header (0 or 3), an unknown block type or an `O` code that is neither
  Sequence (0x0) nor Signal (0xF) gives the all-error word (`0xFE` in every
  lane, `ctl = 0xFF`). 7-bit control codes other than idle (0x00) and LPI (0x06)
  decode to Error.
  """
  use ExHdl.RTL

  @t_types [0x87, 0x99, 0xAA, 0xB4, 0xCC, 0xD2, 0xE1, 0xFF]
  @head [
    {0x1E, ~w(c c c c c c c c)a},
    {0x78, ~w(s d d d d d d d)a},
    {0x33, ~w(c c c c s d d d)a},
    {0x66, ~w(o d d d s d d d)a},
    {0x55, ~w(o d d d o d d d)a},
    {0x2D, ~w(c c c c o d d d)a},
    {0x4B, ~w(o d d d c c c c)a}
  ]
  @patterns @head ++
              for(
                {t, k} <- Enum.with_index(@t_types),
                do: {t, List.duplicate(:d, k) ++ [:t] ++ List.duplicate(:c, 7 - k)}
              )

  @doc "Block types and their lane patterns (`:d` data, `:s` start, `:t` terminate, `:o` ordered set, `:c` other control), lane 0 first."
  def patterns, do: @patterns

  @doc "Expressions `{hdr, payload}` for the block of word `{data, ctl}`."
  def encode(data, ctl) do
    rtl do
      lane = fn i -> slice(data, 8 * i, 8) end

      kinds =
        for i <- 0..7 do
          l = lane.(i)
          c = slice(ctl, i, 1)
          s = c and l == 0xFB
          t = c and l == 0xFD
          o = c and (l == 0x9C or l == 0x5C)
          %{d: not c, s: s, t: t, o: o, c: c and not (s or t or o)}
        end

      cc = fn i ->
        l = lane.(i)
        mux(l == 0x07, const(0, 7), mux(l == 0x06, const(0x06, 7), const(0x1E, 7)))
      end

      oc = fn i -> mux(lane.(i) == 0x5C, const(0xF, 4), const(0, 4)) end
      nat = fn lo, hi -> for i <- lo..hi//1, do: lane.(i) end
      ccs = fn lo, hi -> for i <- lo..hi//1, do: cc.(i) end
      z4 = const(0, 4)

      # LSB first
      segs = fn type, ccf ->
        ty = const(type, 8)

        parts =
          case type do
            0x1E ->
              [ty | ccf.(0, 7)]

            0x78 ->
              [ty | nat.(1, 7)]

            0x33 ->
              [ty | ccf.(0, 3)] ++ [z4 | nat.(5, 7)]

            0x66 ->
              [ty | nat.(1, 3)] ++ [oc.(0), z4 | nat.(5, 7)]

            0x55 ->
              [ty | nat.(1, 3)] ++ [oc.(0), oc.(4) | nat.(5, 7)]

            0x2D ->
              [ty | ccf.(0, 3)] ++ [oc.(4) | nat.(5, 7)]

            0x4B ->
              [ty | nat.(1, 3)] ++ [oc.(0) | ccf.(4, 7)]

            _ ->
              k = Enum.find_index(@t_types, &(&1 == type))
              [ty | nat.(0, k - 1)] ++ ccf.(k + 1, 7)
          end

        w = parts |> Enum.map(&width/1) |> Enum.sum()
        cat(Enum.reverse(if w < 64, do: parts ++ [const(0, 64 - w)], else: parts))
      end

      matches = fn pat ->
        reduce_and(cat(for {k, i} <- Enum.with_index(pat), do: Map.fetch!(Enum.at(kinds, i), k)))
      end

      err = segs.(0x1E, fn lo, hi -> for _ <- lo..hi//1, do: const(0x1E, 7) end)

      ctl_payload =
        @patterns
        |> Enum.reverse()
        |> Enum.reduce(err, fn {t, pat}, acc -> mux(matches.(pat), segs.(t, ccs), acc) end)

      is_data = matches.(List.duplicate(:d, 8))
      {mux(is_data, const(1, 2), const(2, 2)), mux(is_data, data, ctl_payload)}
    end
  end

  @doc "Expressions `{data, ctl}` for the block `{hdr, payload}` (all-error word if invalid)."
  def decode(hdr, payload) do
    rtl do
      d = fn i -> slice(payload, 8 * i, 8) end
      ty = slice(payload, 0, 8)

      cch = fn start ->
        v = slice(payload, start, 7)
        mux(v == 0, const(0x07, 8), mux(v == 6, const(0x06, 8), const(0xFE, 8)))
      end

      och = fn start ->
        n = slice(payload, start, 4)
        {mux(n == 0, const(0x9C, 8), const(0x5C, 8)), n == 0 or n == 0xF}
      end

      fb = const(0xFB, 8)
      one = const(1, 1)
      ds = fn lo, hi -> for i <- lo..hi//1, do: d.(i) end
      cs = fn start, n -> for j <- 0..(n - 1)//1, do: cch.(start + 7 * j) end

      # {lanes lane 0 first, ctl mask, ok}
      forms =
        [
          {0x1E, cs.(8, 8), 0xFF, one},
          {0x78, [fb | ds.(1, 7)], 0x01, one},
          {0x33, cs.(8, 4) ++ [fb | ds.(5, 7)], 0x1F, one},
          {0x66, [elem(och.(32), 0) | ds.(1, 3)] ++ [fb | ds.(5, 7)], 0x11, elem(och.(32), 1)},
          {0x55, [elem(och.(32), 0) | ds.(1, 3)] ++ [elem(och.(36), 0) | ds.(5, 7)], 0x11,
           elem(och.(32), 1) and elem(och.(36), 1)},
          {0x2D, cs.(8, 4) ++ [elem(och.(36), 0) | ds.(5, 7)], 0x1F, elem(och.(36), 1)},
          {0x4B, [elem(och.(32), 0) | ds.(1, 3)] ++ cs.(36, 4), 0xF1, elem(och.(32), 1)}
        ] ++
          for {t, k} <- Enum.with_index(@t_types) do
            lanes =
              for(i <- 0..(k - 1)//1, do: d.(i + 1)) ++ [const(0xFD, 8) | cs.(8 + 8 * k, 7 - k)]

            {t, lanes, Bitwise.band(Bitwise.bsl(0xFF, k), 0xFF), one}
          end

      err_d = const(0xFEFEFEFEFEFEFEFE, 64)
      err_c = const(0xFF, 8)

      {dd, cc} =
        forms
        |> Enum.reverse()
        |> Enum.reduce({err_d, err_c}, fn {t, lanes, cm, ok}, {ad, ac} ->
          hit = ty == t and ok
          {mux(hit, cat(Enum.reverse(lanes)), ad), mux(hit, const(cm, 8), ac)}
        end)

      {mux(hdr == 1, payload, mux(hdr == 2, dd, err_d)),
       mux(hdr == 1, const(0, 8), mux(hdr == 2, cc, err_c))}
    end
  end

  @doc """
  Standalone combinational encoder `pcs10gr_enc`. A module without registers has
  no clock and reset ports, which the cycle harness needs; `clocked: true` adds an
  unused register (the module is then named `pcs10gr_enc_clk`).
  """
  def encoder(opts \\ []) do
    module "pcs10gr_enc#{if opts[:clocked], do: "_clk"}" do
      if opts[:clocked], do: tick()
      data = input(:data, 64)
      ctl = input(:ctl, 8)
      hdr = output(:hdr, 2)
      payload = output(:payload, 64)
      {h, p} = encode(data, ctl)
      hdr <~ h
      payload <~ p
    end
  end

  @doc "Standalone combinational decoder `pcs10gr_dec` (`clocked: true` as for `encoder/1`, named `pcs10gr_dec_clk`)."
  def decoder(opts \\ []) do
    module "pcs10gr_dec#{if opts[:clocked], do: "_clk"}" do
      if opts[:clocked], do: tick()
      hdr = input(:hdr, 2)
      payload = input(:payload, 64)
      data = output(:data, 64)
      ctl = output(:ctl, 8)
      {d, c} = decode(hdr, payload)
      data <~ d
      ctl <~ c
    end
  end

  defp tick do
    rtl do
      t = reg(:tick, 1, reset: 0)

      sync do
        t <~ not t
      end
    end
  end
end
