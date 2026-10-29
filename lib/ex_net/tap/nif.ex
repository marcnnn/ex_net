defmodule ExNet.Tap.Nif do
  @moduledoc """
  Raw bindings to `c_src/ex_net_tap_nif.c`. The NIF is optional: if the shared
  object is missing the module still loads and every function raises
  `:nif_not_loaded`; use `loaded?/0` to check. Use `ExNet.Tap`.

  Errors are `{:error, reason}` with `:closed` or an errno atom (`:eacces`,
  `:eperm`, `:enoent`, `:ebusy`, `:einval`, `:eagain`, ...).
  """
  @on_load :load_nif

  @doc false
  def load_nif do
    case :code.priv_dir(:ex_net) do
      {:error, _} ->
        :ok

      dir ->
        ["", "native"]
        |> Enum.map(
          &(dir
            |> Path.join(&1)
            |> Path.join("ex_net_tap_nif")
            |> String.to_charlist())
        )
        |> Enum.find(&File.exists?(&1 ++ ~c".so"))
        |> case do
          nil -> :ok
          path -> _ = :erlang.load_nif(path, 0)
        end

        :ok
    end
  end

  @doc "True when the NIF shared object is loaded."
  @spec loaded?() :: boolean
  def loaded? do
    _ = open("")
    true
  rescue
    ArgumentError -> true
    ErlangError -> false
  end

  @doc "Opens the TAP interface `name` (TUNSETIFF, `IFF_TAP | IFF_NO_PI`, non-blocking)."
  def open(_name), do: nope()

  @doc """
  Reads up to 64 frames. `{:ok, frames, :armed}`: the queue is empty and the
  calling process gets `{:ex_net_tap_ready, tap}` when a frame arrives (one
  shot); `{:ok, frames, :more}`: call again.
  """
  def recv(_tap), do: nope()

  @doc "Writes one frame (`:ok` or `{:error, :eagain}` when the kernel queue is full)."
  def write(_tap, _frame), do: nope()

  @doc "Closes the descriptor."
  def close(_tap), do: nope()

  defp nope, do: :erlang.nif_error(:nif_not_loaded)
end
