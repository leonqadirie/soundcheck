defmodule Soundcheck.Check.Warning.UnhandledAsyncResult do
  use Soundcheck.Check,
    id: "SC104",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :semantic,
    default: true,
    summary: "`start_async/3` names with no matching `handle_async/3` clause",
    explanations: [
      check: """
      Flags `start_async/3` calls whose name no `handle_async/3` clause in
      the same LiveView or LiveComponent accepts. When the task finishes,
      LiveView calls `handle_async/3` with that name, and the missing clause
      crashes the process.

      Before:

          def mount(_params, _session, socket) do
            {:ok, start_async(socket, :load_stats, fn -> Stats.load() end)}
          end

          def handle_async(:load_users, result, socket), do: ...

      After:

          def handle_async(:load_stats, {:ok, stats}, socket), do: ...

      Names match when they are equal atoms or tuples with the same tag and
      size; a `handle_async(name, ...)` catch-all accepts every name.

      The check reads the compiled module's expanded AST, so it sees
      handlers that `use` macros inject. Handlers attached with
      `attach_hook/4` (in the module or its `on_mount` hooks) make the
      finding unverifiable; it appears only in strict mode.
      """,
      params: [
        strict: "Report unverifiable findings too."
      ]
    ]

  alias Soundcheck.Analysis.Handlers
  alias Soundcheck.Analysis.LiveModules
  alias Soundcheck.Analysis.MountHooks
  alias Soundcheck.Graph

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    routes = MountHooks.routes(graph)

    for {entry, _kind} <- LiveModules.all(graph),
        {:ok, starts} <- [Handlers.async_starts(entry.name)],
        {:ok, handlers} <- [Handlers.handler_set(entry.name, :handle_async, routes)],
        start <- starts,
        not Handlers.handles?(handlers, start.message) do
      LiveModules.unhandled(
        __MODULE__,
        entry,
        start,
        handlers,
        "`start_async` with name `#{LiveModules.describe(start.message)}` has no matching " <>
          "`handle_async/3` clause in `#{inspect(entry.name)}`."
      )
    end
  end
end
