defmodule Soundcheck.Check.Warning.UnhandledServerPushEvent do
  use Soundcheck.Check,
    id: "SC106",
    base_priority: :normal,
    category: :warning,
    confidence: :medium,
    tier: :syntactic,
    default: false,
    summary: "`push_event/3` events no hook `handleEvent` or `phx:` window listener receives",
    explanations: [
      check: """
      Flags `push_event/3` calls whose event no JavaScript listens for: no
      hook calls `this.handleEvent("event", ...)` and no
      `window.addEventListener("phx:event", ...)` exists. The push reaches
      the browser and does nothing.

      Before:

          {:noreply, push_event(socket, "highlite", %{id: id})}

          // app.js
          this.handleEvent("highlight", ({id}) => ...)

      After:

          {:noreply, push_event(socket, "highlight", %{id: id})}

      The check reads the JavaScript under the `js_paths` plugin param
      (default `assets/js`), colocated hooks included. When the hook
      registry includes code soundcheck cannot follow, or the project has no
      `LiveSocket`, findings are unverifiable and appear only in strict mode.
      """,
      params: [
        strict: "Report unverifiable findings too."
      ]
    ]

  alias Soundcheck.Analysis.Hooks
  alias Soundcheck.Analysis.Suggest
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Span

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    registry = Hooks.registry(graph)
    listened = Hooks.listened_events(graph, registry)

    resolution =
      cond do
        not registry.socket? -> {:unverifiable, :no_live_socket}
        registry.open == [] -> :resolved
        true -> {:unverifiable, :open_hook_registry}
      end

    for {entry, clause} <- Graph.clauses(graph),
        {event, line, column} <- pushes(clause.body),
        not MapSet.member?(listened, event) do
      span = Span.new(entry.file, {line, column}, {line, column + String.length("push_event")})

      Diagnostic.new(
        __MODULE__,
        span,
        "`push_event(socket, \"#{event}\", ...)` has no listener: no hook calls " <>
          "`handleEvent(\"#{event}\")` and no `phx:#{event}` window listener exists.",
        suggestion: suggestion(event, listened),
        resolution: resolution
      )
    end
  end

  # `push_event(socket, "e", payload)`, `socket |> push_event("e", payload)`,
  # and `Phoenix.LiveView.push_event(...)`, with a literal event name.
  defp pushes(body) do
    for node <- Macro.prewalker(body), found = push(node), do: found
  end

  defp push({:push_event, meta, args}) when is_list(args), do: literal_event(args, meta)

  defp push({{:., _, [{:__aliases__, _, [:Phoenix, :LiveView]}, :push_event]}, meta, args}),
    do: literal_event(args, meta)

  defp push(_node), do: nil

  defp literal_event([_socket, event, _payload], meta) when is_binary(event),
    do: {event, meta[:line], meta[:column]}

  defp literal_event([event, _payload], meta) when is_binary(event),
    do: {event, meta[:line], meta[:column]}

  defp literal_event(_args, _meta), do: nil

  defp suggestion(event, listened) do
    case Suggest.closest(event, MapSet.to_list(listened)) do
      nil -> nil
      closest -> "Did you mean \"#{closest}\"?"
    end
  end
end
