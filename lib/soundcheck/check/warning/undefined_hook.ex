defmodule Soundcheck.Check.Warning.UndefinedHook do
  use Soundcheck.Check,
    id: "SC1001",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :syntactic,
    default: true,
    summary: "`phx-hook` names `LiveSocket` does not register",
    param_defaults: [external_hooks: []],
    explanations: [
      check: """
      Flags `phx-hook="Name"` references to hooks that the project's
      `LiveSocket` does not register. LiveView logs an error in the browser
      and the hook never mounts.

      Before:

          <div id="feed" phx-hook="InfiniteScrol">

          const Hooks = {InfiniteScroll: {...}}

      After:

          <div id="feed" phx-hook="InfiniteScroll">

      The check reads the JavaScript under the `js_paths` plugin param
      (default `assets/js`): hooks registered through
      `new LiveSocket(url, Socket, {hooks: ...})`, objects bound to variables
      and extended by assignment or `Object.assign`, relative imports, and
      colocated hooks (`<script :type={ColocatedHook} name=".Name">`, which
      `phx-hook=".Name"` refers to) when `app.js` imports
      `phoenix-colocated/<app>`.

      When the registry includes something soundcheck cannot follow (an npm
      package, a computed key), findings are unverifiable and appear only in
      strict mode. List hooks registered that way in `external_hooks` to
      make the registry closed again.
      """,
      params: [
        external_hooks: "Hook names registered by code soundcheck cannot follow.",
        strict: "Report unverifiable findings too."
      ]
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Analysis.Hooks
  alias Soundcheck.Analysis.Suggest
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, params) do
    registry = Hooks.registry(graph)
    external = Keyword.fetch!(params, :external_hooks)
    known = Map.keys(registry.names) ++ external

    resolution =
      cond do
        not registry.socket? -> {:unverifiable, :no_live_socket}
        registry.open == [] or external != [] -> :resolved
        true -> {:unverifiable, :open_hook_registry}
      end

    for %{name: name} = usage <- Hooks.usages(graph),
        is_binary(name),
        name not in known do
      Diagnostic.new(
        __MODULE__,
        usage.span,
        "`phx-hook=\"#{name}\"` names a hook that `LiveSocket` does not register.",
        suggestion: suggestion(name, known),
        anchor: Anchors.for_template(graph, usage.template, usage.span),
        resolution: resolution
      )
    end
  end

  defp suggestion(name, known) do
    case Suggest.closest(name, known) do
      nil -> nil
      closest -> "Did you mean \"#{closest}\"?"
    end
  end
end
