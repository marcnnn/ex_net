defmodule ExNet.RTL.BlockLock do
  @moduledoc """
  Block lock state machine, hardware version of `ExNet.PCS.BlockLock`.

  Module `pcs10gr_lock`: inputs `sh` (2, received sync header), `valid` (the
  header is valid this cycle, e.g. the gearbox's rxheadervalid; without it the
  state holds); outputs `lock` and `slip`, both combinational (latency 0) and
  equal to the model's `step/2` result of the same cycle: `lock` includes the
  effect of the current header (it rises with the 64th valid header of a clean
  window), `slip` is high for one cycle when the current header is invalid and
  the machine is unlocked, or the 16th invalid header of a window arrives.
  Without `valid`, `lock` shows the current state and `slip` is 0. State:
  `lock`, 6-bit header counter, 4-bit invalid counter; reset unlocked.
  """
  use ExHdl.RTL

  def build do
    module "pcs10gr_lock" do
      sh = input(:sh, 2)
      valid = input(:valid, 1)
      lock_o = output(:lock, 1)
      slip_o = output(:slip, 1)
      lk = reg(:lk, 1, reset: 0)
      cnt = reg(:cnt, 6, reset: 0)
      inv = reg(:inv, 4, reset: 0)

      hv = wire(:hv, valid and (sh == 1 or sh == 2))
      bad = wire(:bad, valid and not (sh == 1 or sh == 2))
      done = wire(:done, cnt == 63)
      drop = wire(:drop, inv == 15 or not lk)

      sync do
        if hv do
          if done do
            cnt <~ 0
            inv <~ 0
            if inv == 0, do: lk <~ 1
          else
            cnt <~ add_wrap(cnt, 1)
          end
        end

        if bad do
          if drop do
            lk <~ 0
            cnt <~ 0
            inv <~ 0
          else
            if done do
              cnt <~ 0
              inv <~ 0
            else
              cnt <~ add_wrap(cnt, 1)
              inv <~ add_wrap(inv, 1)
            end
          end
        end
      end

      lock_o <~ mux(hv and done and inv == 0, const(1, 1), mux(bad and drop, const(0, 1), lk))
      slip_o <~ (bad and drop)
    end
  end
end
