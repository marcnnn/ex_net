defmodule Mix.Tasks.Compile.ExNetNif do
  @moduledoc """
  Builds the TAP NIF (`c_src/ex_net_tap_nif.c`) with `make` when `make` and a
  C compiler exist. The NIF is optional: a failed or skipped build only
  logs a notice, and `ExNet.Tap.open/2` returns `{:error, :nif_unavailable}`.
  """
  use Mix.Task.Compiler

  @impl true
  def run(_args) do
    if System.find_executable("make") &&
         (System.find_executable("cc") || System.find_executable("gcc")) do
      priv = Path.join(Mix.Project.app_path(), "priv")

      case System.cmd("make", ["-s", "PRIV_DIR=#{priv}", "ERTS_INCLUDE_DIR=#{erts_include()}"],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          load_now()
          {:ok, []}

        {out, _} ->
          Mix.shell().info("ex_net: NIF not built (optional):\n#{out}")
          {:noop, []}
      end
    else
      Mix.shell().info("ex_net: no make/cc, NIF skipped (optional)")
      {:noop, []}
    end
  end

  # on a first build the Elixir compiler has already loaded `ExNet.Tap.Nif` (its @on_load ran
  # before the shared object existed); load the NIF into that module now
  defp load_now do
    if :erlang.module_loaded(ExNet.Tap.Nif), do: ExNet.Tap.Nif.load_nif()
  end

  defp erts_include,
    do:
      Path.join([
        List.to_string(:code.root_dir()),
        "erts-#{:erlang.system_info(:version)}",
        "include"
      ])
end
