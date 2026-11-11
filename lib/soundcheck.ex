defmodule Soundcheck do
  @moduledoc """
  A LiveView-aware Credo plugin.

  soundcheck links a Phoenix LiveView application's callbacks, HEEx
  templates, and JavaScript hooks into one semantic graph per run, then
  checks the contracts between them, for example "this template emits an
  event that no handler accepts".

  ## Plugin usage

  Add the plugin to `.credo.exs`:

      %{configs: [%{
        name: "default",
        plugins: [{Soundcheck, []}]
      }]}

  Semantic checks read compiled modules, so run `mix compile` before
  `mix credo`, for example through a Mix alias:

      lint: ["compile", "credo --strict"]

  See `docs/architecture.md` for the design.
  """

  import Credo.Plugin

  alias Soundcheck.Cache
  alias Soundcheck.Credo.BuildGraphTask

  # Generated from Soundcheck.Checks, which `mix soundcheck` reads as well.
  @config_file Soundcheck.Checks.credo_config()

  @doc """
  Credo plugin callback. Starts the `:soundcheck` application, which owns
  the run cache, empties the cache, registers the default check config, builds the graph before the `suggest` and `diff`
  commands run their checks, and empties the cache again when Credo halts.
  """
  def init(exec) do
    # Hosts install soundcheck with `runtime: false`, so `mix credo` loads
    # the application without starting it.
    {:ok, _started} = Application.ensure_all_started(:soundcheck)
    Cache.clear()

    exec
    |> register_default_config(@config_file)
    |> prepend_task(Credo.CLI.Command.Suggest.SuggestCommand, :run_analysis, build_graph_task())
    |> prepend_task(Credo.CLI.Command.Diff.DiffCommand, :run_analysis, build_graph_task())
    |> append_task(:halt_execution, Soundcheck.Credo.ClearCacheTask)
  end

  # The task reads this plugin's params; passing the plugin module as a task
  # option keeps the task from referencing this module back.
  defp build_graph_task, do: {BuildGraphTask, plugin: __MODULE__}
end
