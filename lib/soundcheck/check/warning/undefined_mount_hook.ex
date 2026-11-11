defmodule Soundcheck.Check.Warning.UndefinedMountHook do
  use Soundcheck.Check,
    id: "SC503",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :semantic,
    default: true,
    summary:
      "`on_mount` hooks whose module has no `on_mount/4` clause for the hook's argument, which crash every mount they guard",
    explanations: [
      check: """
      Flags `on_mount` hooks whose module has no `on_mount/4` clause that
      accepts the hook's argument. LiveView calls `Module.on_mount(arg,
      params, session, socket)` before every mount, so such a hook raises
      `FunctionClauseError` in every LiveView it guards. The compiler
      already warns when the module or its `on_mount/4` is missing.

      Before:

          live_session :admin, on_mount: [{MyAppWeb.UserAuth, :require_admin}] do
            live "/admin", AdminLive
          end

          # MyAppWeb.UserAuth defines on_mount(:require_authenticated, ...) only

      After:

          def on_mount(:require_admin, _params, session, socket) do
            # ...
          end

      The check reads hooks from `on_mount/1` calls in LiveViews and
      LiveComponents and from the `:on_mount` option of a router's
      `live_session`, and the hook module's compiled `on_mount/4` clauses.
      A bare module hook passes `:default`. A clause counts as accepting
      unless its first pattern is a different atom; hooks whose argument
      is not a literal are skipped.
      """
    ]

  alias Soundcheck.Analysis.MountHooks
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    for %{name: name, on_mount: [_ | _] = hooks} <- graph.modules,
        name != nil,
        %{module: module, arg: arg, span: span} <- hooks,
        is_atom(module),
        Macro.quoted_literal?(arg),
        not MountHooks.accepts_arg?(module, arg) do
      Diagnostic.new(
        __MODULE__,
        span,
        "No `#{inspect(module)}.on_mount/4` clause accepts #{inspect(arg)}, so every mount " <>
          "this hook guards raises FunctionClauseError."
      )
    end
  end
end
