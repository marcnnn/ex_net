defmodule ExNet.PCS.AutoNeg do
  @moduledoc """
  1000BASE-X auto-negotiation (Clause 37) at ordered-set level.

  Each `step/2` consumes one received ordered set: `{:config, reg}`, `:idle`
  or `:invalid`. `tick/1` advances the link timer by one unit (10 ms in the
  standard, `link_timer` units in the model). `tx/1` is what to transmit:
  `{:config, reg}` (alternating /C1/ /C2/ is the PCS's business), `:idle` or
  `:data`.

  Config register (bit 0 sent first, low byte first): bit 5 full duplex, 6
  half duplex, 7 PAUSE, 8 ASM_DIR, 12-13 remote fault, 14 acknowledge, 15
  next page. `reg/1` and `parse/1` convert.

  Flow: `an_enable`/`an_restart` send a zero register until the link timer
  expires (breaks the link), `ability_detect` sends our abilities until three
  identical non-zero registers arrive, `acknowledge_detect` sends them with
  Ack until three registers with Ack arrive, `complete_acknowledge` waits the
  link timer, `idle_detect` sends idles until three idle sets arrive,
  `link_ok` sends data. A partner register that changes (ignoring Ack) or a
  restarted partner (three equal registers that differ from the stored one while in `idle_detect`/`link_ok`) sends
  us back to `an_enable`. Next pages, remote fault generation and the
  link-fail-inhibit timer are not modelled; `idle_detect` has no timeout.

      iex> alias ExNet.PCS.AutoNeg, as: AN
      iex> {a, b} = {AN.new(reg: AN.reg(fd: true, pause: true)), AN.new(reg: AN.reg(fd: true))}
      iex> {a, b} = AN.connect(a, b)
      iex> {AN.link_up?(a), AN.link_up?(b), AN.resolve(a.partner, a.ability)}
      {true, true, %{duplex: :full, pause: :none}}
  """
  import Bitwise

  @ack 0x4000

  defstruct st: :an_enable,
            ability: 0,
            partner: nil,
            hist: [],
            timer: 0,
            link_timer: 10,
            tx_ack: false

  def new(opts \\ []),
    do: %__MODULE__{
      ability: Keyword.fetch!(opts, :reg),
      link_timer: Keyword.get(opts, :link_timer, 10)
    }

  @doc "Builds a base page register."
  def reg(opts) do
    b = fn k, bit -> if Keyword.get(opts, k, false), do: bit, else: 0 end

    b.(:fd, 0x20) ||| b.(:hd, 0x40) ||| b.(:pause, 0x80) ||| b.(:asym, 0x100) |||
      Keyword.get(opts, :rf, 0) <<< 12 ||| b.(:ack, @ack) ||| b.(:np, 0x8000)
  end

  def parse(r) do
    %{
      fd: (r &&& 0x20) != 0,
      hd: (r &&& 0x40) != 0,
      pause: (r &&& 0x80) != 0,
      asym: (r &&& 0x100) != 0,
      rf: r >>> 12 &&& 3,
      ack: (r &&& @ack) != 0,
      np: (r &&& 0x8000) != 0
    }
  end

  @doc "What the PCS transmits in the current state."
  def tx(%{st: st}) when st in [:an_enable, :an_restart], do: {:config, 0}
  def tx(%{st: :ability_detect} = s), do: {:config, s.ability &&& ~~~@ack}

  def tx(%{st: st} = s) when st in [:acknowledge_detect, :complete_acknowledge],
    do: {:config, s.ability ||| @ack}

  def tx(%{st: :idle_detect}), do: :idle
  def tx(%{st: :link_ok}), do: :data

  def link_up?(%{st: :link_ok}), do: true
  def link_up?(_), do: false

  @doc "Management restart (mr_restart_an)."
  def restart(s), do: enter(s, :an_restart)

  @doc "Advances the link timer by one unit."
  def tick(%{st: st} = s) when st in [:an_enable, :an_restart] do
    s = %{s | timer: s.timer + 1}
    if timer_done?(s), do: enter(s, :ability_detect), else: s
  end

  def tick(%{st: :complete_acknowledge} = s) do
    s = %{s | timer: s.timer + 1}
    if timer_done?(s), do: enter(s, :idle_detect), else: s
  end

  def tick(s), do: s

  @doc "Consumes one received ordered set."
  def step(s, rx) do
    s = %{s | hist: Enum.take([rx | s.hist], 3)}
    react(s, s.st)
  end

  defp react(s, :ability_detect) do
    case ability_match(s) do
      r when is_integer(r) and r != 0 -> enter(%{s | partner: r}, :acknowledge_detect)
      _ -> s
    end
  end

  defp react(s, :acknowledge_detect) do
    cond do
      ability_match(s) != nil and ability_match(s) != s.partner -> enter(s, :an_enable)
      ack_match(s) -> enter(s, :complete_acknowledge)
      true -> s
    end
  end

  defp react(s, :complete_acknowledge) do
    m = ability_match(s)
    if m != nil and m != s.partner, do: enter(s, :an_enable), else: s
  end

  defp react(s, :idle_detect) do
    cond do
      changed?(s) -> enter(s, :an_enable)
      idle_match(s) -> enter(s, :link_ok)
      true -> s
    end
  end

  defp react(s, :link_ok), do: if(changed?(s), do: enter(s, :an_enable), else: s)
  defp react(s, _), do: s

  # a partner still finishing with the same page is ignored, a different page restarts
  defp changed?(s) do
    m = ability_match(s)
    m != nil and m != s.partner
  end

  defp enter(s, st) do
    s = %{s | st: st, timer: 0}
    if st in [:an_enable, :an_restart], do: %{s | partner: nil, hist: []}, else: s
  end

  defp timer_done?(s), do: s.timer >= s.link_timer

  # three consecutive registers equal ignoring Ack: returns the common register (Ack cleared)
  defp ability_match(%{hist: [{:config, a}, {:config, b}, {:config, c}]})
       when (a &&& ~~~@ack) == (b &&& ~~~@ack) and (b &&& ~~~@ack) == (c &&& ~~~@ack),
       do: a &&& ~~~@ack

  defp ability_match(_), do: nil

  defp ack_match(%{hist: [{:config, a}, {:config, b}, {:config, c}]} = s),
    do: (a &&& b &&& c &&& @ack) != 0 and ability_match(s) == s.partner

  defp ack_match(_), do: false

  defp idle_match(%{hist: [:idle, :idle, :idle]}), do: true
  defp idle_match(_), do: false

  @doc """
  Duplex and pause resolution (Table 37-4): `%{duplex: :full | :half | nil,
  pause: :none | :tx | :rx | :both}` where `:tx` means this side may send
  PAUSE frames only.
  """
  def resolve(partner_reg, local_reg) do
    l = parse(local_reg)
    p = parse(partner_reg)

    duplex =
      cond do
        l.fd and p.fd -> :full
        l.hd and p.hd -> :half
        true -> nil
      end

    pause =
      case {l.pause, l.asym, p.pause, p.asym} do
        {true, _, true, _} -> :both
        {false, true, true, true} -> :tx
        {true, true, false, true} -> :rx
        _ -> :none
      end

    %{duplex: duplex, pause: pause}
  end

  @doc """
  Runs two machines against each other (one ordered set and one timer unit
  per round) until both are in `link_ok` or `max_rounds` pass.
  """
  def connect(a, b, max_rounds \\ 200), do: connect(a, b, max_rounds, 0)

  defp connect(a, b, max, n) when n >= max, do: {a, b}

  defp connect(a, b, max, n) do
    if link_up?(a) and link_up?(b) do
      {a, b}
    else
      ta = tx(a) |> as_rx()
      tb = tx(b) |> as_rx()
      a = a |> tick() |> step(tb)
      b = b |> tick() |> step(ta)
      connect(a, b, max, n + 1)
    end
  end

  defp as_rx({:config, r}), do: {:config, r}
  defp as_rx(:idle), do: :idle
  defp as_rx(:data), do: :idle
end
