defmodule ExNet.PCS.AutoNegTest do
  use ExUnit.Case, async: true
  alias ExNet.PCS.AutoNeg, as: AN

  doctest ExNet.PCS.AutoNeg

  test "register bits" do
    r = AN.reg(fd: true, hd: true, pause: true, asym: true)
    assert r == 0x1E0
    assert AN.reg(rf: 2, ack: true, np: true) == 0xE000
    assert %{fd: true, hd: false, pause: false, ack: false, rf: 0} = AN.parse(0x20)

    assert AN.parse(AN.reg(fd: true, pause: true)) |> Map.take([:fd, :pause, :asym]) == %{
             fd: true,
             pause: true,
             asym: false
           }
  end

  test "state sequence of one side against a steady partner" do
    partner = AN.reg(fd: true, pause: true)
    s = AN.new(reg: AN.reg(fd: true), link_timer: 3)
    assert {:config, 0} = AN.tx(s)
    s = s |> AN.tick() |> AN.tick()
    assert s.st == :an_enable
    s = AN.tick(s)
    assert s.st == :ability_detect
    assert AN.tx(s) == {:config, 0x20}

    # two matching registers are not enough
    s = s |> AN.step({:config, partner}) |> AN.step({:config, partner})
    assert s.st == :ability_detect
    s = AN.step(s, {:config, partner})
    assert s.st == :acknowledge_detect
    assert AN.tx(s) == {:config, 0x4020}
    assert s.partner == partner

    # acknowledge from the partner
    s = Enum.reduce(1..3, s, fn _, s -> AN.step(s, {:config, partner + 0x4000}) end)
    assert s.st == :complete_acknowledge
    s = Enum.reduce(1..3, s, fn _, s -> AN.tick(s) end)
    assert s.st == :idle_detect
    assert AN.tx(s) == :idle
    s = Enum.reduce(1..3, s, fn _, s -> AN.step(s, :idle) end)
    assert AN.link_up?(s)
    assert AN.tx(s) == :data
  end

  test "partner restart or change drops back to an_enable" do
    {a, b} = AN.connect(AN.new(reg: AN.reg(fd: true)), AN.new(reg: AN.reg(fd: true)))
    assert AN.link_up?(a) and AN.link_up?(b)
    same = Enum.reduce(1..3, a, fn _, a -> AN.step(a, {:config, 0x20}) end)
    assert same.st == :link_ok
    a = Enum.reduce(1..3, a, fn _, a -> AN.step(a, {:config, 0}) end)
    assert a.st == :an_enable

    s = AN.new(reg: 0x20, link_timer: 1) |> AN.tick() |> Map.put(:st, :ability_detect)
    s = Enum.reduce(1..3, s, fn _, s -> AN.step(s, {:config, 0x20}) end)
    assert s.st == :acknowledge_detect
    s = Enum.reduce(1..3, s, fn _, s -> AN.step(s, {:config, 0x60}) end)
    assert s.st == :an_enable
  end

  test "restart" do
    {a, _} = AN.connect(AN.new(reg: 0x20), AN.new(reg: 0x20))
    assert AN.restart(a).st == :an_restart
    assert AN.tx(AN.restart(a)) == {:config, 0}
  end

  test "two machines link up from any relative timer phase" do
    for t <- 1..6 do
      a = AN.new(reg: AN.reg(fd: true, pause: true), link_timer: 4)
      b = a |> Map.put(:link_timer, 5) |> then(&Enum.reduce(1..t, &1, fn _, s -> AN.tick(s) end))
      {a, b} = AN.connect(a, b)
      assert AN.link_up?(a) and AN.link_up?(b)
    end
  end

  test "duplex and pause resolution" do
    r = fn opts -> AN.reg(opts) end
    both = r.(fd: true, hd: true)
    assert AN.resolve(r.(fd: true), both) == %{duplex: :full, pause: :none}
    assert AN.resolve(r.(hd: true), both).duplex == :half
    assert AN.resolve(r.(hd: true), r.(fd: true)).duplex == nil

    table = [
      # local {pause, asym}, partner {pause, asym}, result
      {{false, false}, {true, true}, :none},
      {{false, true}, {true, true}, :tx},
      {{false, true}, {true, false}, :none},
      {{false, true}, {false, true}, :none},
      {{true, false}, {true, false}, :both},
      {{true, false}, {false, true}, :none},
      {{true, false}, {true, true}, :both},
      {{true, true}, {true, false}, :both},
      {{true, true}, {false, true}, :rx},
      {{true, true}, {false, false}, :none},
      {{true, true}, {true, true}, :both}
    ]

    for {{lp, la}, {pp, pa}, want} <- table do
      assert AN.resolve(r.(fd: true, pause: pp, asym: pa), r.(fd: true, pause: lp, asym: la)).pause ==
               want
    end
  end
end
