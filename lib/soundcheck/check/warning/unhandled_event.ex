defmodule Soundcheck.Check.Warning.UnhandledEvent do
  use Soundcheck.Check,
    id: "SC101",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :semantic,
    default: true,
    summary:
      "Template events (`phx-*`, `JS.push`) with no `handle_event/3` clause in the receiving LiveView or LiveComponent",
    param_defaults: [ignore_events: []],
    explanations: [
      check: """
      Flags template events that no `handle_event/3` clause in the receiving
      LiveView or LiveComponent accepts. LiveView crashes the process when
      such an event arrives.

      Before:

          <button phx-click="sav">Save</button>

          def handle_event("save", params, socket), do: ...

      After:

          <button phx-click="save">Save</button>

      The check follows LiveView's routing. Without `phx-target`, an event
      goes to the LiveView that renders the element, also from inside a
      LiveComponent or a function component (every LiveView that renders
      the component must handle it). With `phx-target={@myself}`, it goes
      to the LiveComponent that renders the element. `JS.push` events and
      their `target:` option follow the same rules.

      A finding is unverifiable, and appears only in strict mode, when the
      event name or target is dynamic, the target is a CSS selector, the
      template has no known render path, or the receiver attaches handlers
      with `attach_hook/4`. The message suggests the closest handled event
      within a few edits.

      A shared component may render an event only for some of its callers.
      When the event sits inside conditions soundcheck cannot evaluate
      (`:if={@actor.type != :service_account}`) and another receiver
      handles it, the finding is unverifiable (`guarded`): the condition
      may keep the event from rendering where it is unhandled. To have
      soundcheck verify such a component, guard the event with a boolean
      attr the callers pass as a literal:

          attr :show_admin_actions, :boolean, default: false

          <button :if={@show_admin_actions} phx-click="promote">Promote</button>

          <.member_panel show_admin_actions={true} />

      A call site that passes `false`, or omits the attr, rules the event
      out for its LiveView.
      """,
      params: [
        ignore_events: "Event names to skip: binaries or regexes.",
        strict: "Report unverifiable findings too."
      ]
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Analysis.Components
  alias Soundcheck.Analysis.Events
  alias Soundcheck.Analysis.MountHooks
  alias Soundcheck.Analysis.Suggest
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.NameFilter

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, params) do
    render_index = Components.render_index(graph)
    js_helpers = Events.js_helpers(graph)
    index = %{render: render_index, routes: MountHooks.routes(graph)}

    for template <- graph.templates,
        emitter <- Events.emitters(template, js_helpers),
        expanded <- Events.expand(template, emitter, render_index),
        not ignored?(expanded, Keyword.fetch!(params, :ignore_events)),
        diagnostic <- expanded_check(graph, template, emitter, expanded, index) do
      diagnostic
    end
  end

  defp expanded_check(graph, _template, _emitter, {:ok, site_template, site_emitter}, index),
    do: check(graph, site_template, site_emitter, index)

  defp expanded_check(graph, template, emitter, {:unverifiable, reason}, _index),
    do: [unverifiable(graph, template, emitter, reason)]

  defp ignored?({:ok, _template, %{event: {:literal, event}}}, ignore),
    do: NameFilter.matches_any?(event, ignore)

  defp ignored?(_expanded, _ignore), do: false

  defp check(graph, template, emitter, index) do
    case Events.receiver_reach(template, emitter, index.render) do
      {:ok, reach} -> resolved(graph, template, emitter, reach, index.routes)
      {:unverifiable, reason} -> [unverifiable(graph, template, emitter, reason)]
    end
  end

  defp resolved(graph, template, %{event: {:literal, event}} = emitter, reach, routes) do
    receivers = reach |> Map.keys() |> Enum.sort()

    case Events.check_handled(receivers, event, routes) do
      :handled ->
        []

      {:missing, missing} ->
        resolution = if guarded?(reach, missing), do: {:unverifiable, :guarded}, else: :resolved
        [diagnostic(graph, template, emitter, missing, resolution)]

      {:unverifiable, reason} ->
        [unverifiable(graph, template, emitter, reason)]
    end
  end

  # Another receiver handles the event, and conditions soundcheck cannot
  # evaluate guard every path to each receiver that lacks it: the event
  # may never render there.
  defp guarded?(reach, missing),
    do:
      map_size(reach) > length(missing) and
        Enum.all?(missing, fn {module, _set} -> reach[module] end)

  defp diagnostic(graph, template, %{event: {:literal, event}} = emitter, missing, resolution) do
    modules = Enum.map_join(missing, " and ", fn {module, _set} -> "`#{inspect(module)}`" end)
    known = for {_module, set} <- missing, {:literal, handled} <- set.patterns, do: handled

    Diagnostic.new(
      __MODULE__,
      emitter.span,
      "`#{emitter.via}=\"#{event}\"` has no matching `handle_event/3` clause in #{modules}.",
      suggestion: suggestion(event, known),
      anchor: Anchors.for_template(graph, template, emitter.span),
      resolution: resolution
    )
  end

  defp unverifiable(graph, template, emitter, reason) do
    event =
      case emitter.event do
        {:literal, event} -> "\"#{event}\""
        _dynamic_or_forwarded -> "(dynamic)"
      end

    Diagnostic.new(
      __MODULE__,
      emitter.span,
      "Cannot verify that `#{emitter.via}=#{event}` is handled (#{reason}).",
      anchor: Anchors.for_template(graph, template, emitter.span),
      resolution: {:unverifiable, reason}
    )
  end

  defp suggestion(event, known) do
    case Suggest.closest(event, known) do
      nil -> nil
      closest -> "Did you mean \"#{closest}\"?"
    end
  end
end
