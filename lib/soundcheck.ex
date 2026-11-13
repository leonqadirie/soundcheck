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

  ## Plugin params

    * `js_paths` - directories scanned for `.js`, `.ts`, and `.mjs` hook
      sources (default `["assets/js"]`).
    * `graph_excluded_paths` - Elixir files Credo loaded that soundcheck
      leaves out of its analysis (default `[~r"/test/", "test"]`, the
      test directories). A file left out gets no findings and influences
      none: a LiveView in `test/support` does not count as a place that
      renders a component.

  Each check also takes `excluded_paths`, with the same default. It names
  the files that check does not report in; those files still feed the
  analysis. A file gets a finding when it is in the graph and outside the
  check's `excluded_paths`.

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
