defmodule Soundcheck.Check.Warning.UnhandledHookEvent do
  use Soundcheck.Check,
    id: "SC103",
    base_priority: :high,
    category: :warning,
    confidence: :medium,
    tier: :semantic,
    default: false,
    summary:
      "`pushEvent`/`pushEventTo` calls in hooks that the receiving LiveView does not handle",
    explanations: [
      check: """
      Flags events a JavaScript hook pushes that the receiving LiveView or
      LiveComponent does not handle. LiveView crashes the process when such
      an event arrives.

      Before:

          // assets/js/app.js
          Hooks.Chart = {mounted() { this.pushEvent("zoom", {}) }}

          <div id="chart" phx-hook="Chart">   <!-- in StatsLive, no "zoom" clause -->

      After:

          def handle_event("zoom", params, socket), do: ...

      `this.pushEvent` goes to the LiveView that renders the hook's element,
      also from inside a LiveComponent. `this.pushEventTo(this.el, ...)`
      goes to the LiveComponent or LiveView whose own render contains the
      element. The finding anchors at the `phx-hook` attribute, because
      Credo reports only in Elixir files.

      Pushes with dynamic event names or targets, selector targets, and
      hooks soundcheck cannot resolve to an object literal are skipped or
      unverifiable.
      """,
      params: [
        strict: "Report unverifiable findings too."
      ]
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Analysis.Components
  alias Soundcheck.Analysis.Events
  alias Soundcheck.Analysis.Events.Emitter
  alias Soundcheck.Analysis.Hooks
  alias Soundcheck.Analysis.MountHooks
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.JS.Extractor.Push

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    registry = Hooks.registry(graph)
    index = %{render: Components.render_index(graph), routes: MountHooks.routes(graph)}

    diagnostics =
      for %{name: name} = usage <- Hooks.usages(graph),
          {:ok, definition} <- [Map.fetch(registry.names, name)],
          {:ok, %{pushes: pushes}} <- [Hooks.events(graph, definition)],
          %{event: {:literal, event}} = push <- pushes,
          diagnostic <- check(graph, usage, push, event, index) do
        diagnostic
      end

    Enum.uniq_by(diagnostics, &{&1.anchor, &1.message})
  end

  defp check(graph, usage, push, event, index) do
    emitter = %Emitter{
      event: {:literal, event},
      target: target(push),
      via: call(push),
      span: push.span
    }

    with {:ok, receivers} <- Events.receivers(usage.template, emitter, index.render),
         {:missing, missing} <- Events.check_handled(receivers, event, index.routes) do
      [diagnostic(graph, usage, emitter, event, missing, :resolved)]
    else
      :handled ->
        []

      {:unverifiable, reason} ->
        [diagnostic(graph, usage, emitter, event, [], {:unverifiable, reason})]
    end
  end

  defp target(%Push{kind: :push_event}), do: :none
  defp target(%Push{target: target}), do: target

  defp call(%Push{kind: :push_event}), do: "pushEvent"
  defp call(%Push{kind: :push_event_to}), do: "pushEventTo"

  defp diagnostic(graph, usage, emitter, event, missing, resolution) do
    receivers =
      case missing do
        [] ->
          "its receiver"

        _modules ->
          Enum.map_join(missing, " and ", fn {module, _set} -> "`#{inspect(module)}`" end)
      end

    Diagnostic.new(
      __MODULE__,
      emitter.span,
      "Hook `#{usage.name}` calls `#{emitter.via}(\"#{event}\")` in #{emitter.span.file}, " <>
        "but #{receivers} has no matching `handle_event/3` clause.",
      anchor: Anchors.for_template(graph, usage.template, usage.span),
      related: [{usage.span, "the hook is attached here"}],
      resolution: resolution
    )
  end
end
