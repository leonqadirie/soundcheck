defmodule Soundcheck.Check.Design.UnusedEventHandler do
  use Soundcheck.Check,
    id: "SC102",
    base_priority: :normal,
    category: :design,
    confidence: :medium,
    tier: :semantic,
    needs: [:live_modules, :routes, :render_index, :js_helpers],
    default: false,
    summary: "`handle_event/3` clauses nothing in the project emits",
    param_defaults: [ignore_events: []],
    explanations: [
      check: """
      Flags literal `handle_event/3` clauses that no template, `JS.push`,
      or hook in the project emits to their module: dead code left behind
      after a template change.

      Before:

          <button phx-click="save">Save</button>

          def handle_event("save", params, socket), do: ...
          def handle_event("archive", params, socket), do: ...  # nothing emits it

      After: remove the `"archive"` clause, or wire up its emitter.

      The check needs a closed world to be right, so it reports nothing
      unless every event emitter in the project resolves: one dynamic event
      name (`phx-click={@action}`), selector target, unresolvable hook
      push, or `pushEvent` with a dynamic name anywhere in the project's
      JavaScript turns it off. A handler whose event name appears as a
      string anywhere else in the project's Elixir code (helpers, tests), or
      as a literal `pushEvent` name in its JavaScript, is never reported.
      """,
      params: [
        ignore_events: "Event names to skip: binaries or regexes."
      ]
    ]

  alias Soundcheck.Analysis.Events
  alias Soundcheck.Analysis.Handlers
  alias Soundcheck.Analysis.Hooks
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.NameFilter
  alias Soundcheck.Span

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, params) do
    case reached_events(graph) do
      {:ok, reached} -> unused(graph, reached, Keyword.fetch!(params, :ignore_events))
      :open_world -> []
    end
  end

  # Every `{module, event}` some emitter reaches, or `:open_world` when any
  # emitter in the project does not resolve.
  defp reached_events(graph) do
    render_index = Graph.render_index(graph)
    js_helpers = Graph.js_helpers(graph)

    expanded =
      for template <- graph.templates,
          emitter <- Events.emitters(template, js_helpers),
          result <- Events.expand(template, emitter, render_index),
          do: result

    # Pushes from helper classes (`this.hook.pushEvent(...)`) sit outside
    # any hook object, so no receiver resolves for them.
    if Enum.any?(expanded, &match?({:unverifiable, _reason}, &1)) or
         Enum.any?(graph.js, fn facts -> Enum.any?(facts.pushes, &(&1.event == :dynamic)) end) do
      :open_world
    else
      emitters = for {:ok, template, emitter} <- expanded, do: {template, emitter}

      with {:ok, reached} <- add_emitters(emitters, MapSet.new(), render_index),
           do: with_hook_pushes(graph, reached, render_index)
    end
  end

  defp with_hook_pushes(graph, reached, render_index) do
    registry = Hooks.registry(graph)

    Enum.reduce_while(Hooks.usages(graph), {:ok, reached}, fn usage, {:ok, acc} ->
      with {:ok, definition} <- Map.fetch(registry.names, usage.name),
           {:ok, %{pushes: pushes}} <- Hooks.events(graph, definition),
           emitters = Enum.map(pushes, &{usage.template, push_emitter(&1)}),
           {:ok, acc} <- add_emitters(emitters, acc, render_index) do
        {:cont, {:ok, acc}}
      else
        _unresolved -> {:halt, :open_world}
      end
    end)
  end

  defp push_emitter(push) do
    target = if push.kind == :push_event, do: :none, else: push.target
    %Events.Emitter{event: push.event, target: target, via: "hook", span: push.span}
  end

  defp add_emitters(emitters, reached, render_index) do
    Enum.reduce_while(emitters, {:ok, reached}, fn {template, emitter}, {:ok, acc} ->
      case {emitter.event, Events.receivers(template, emitter, render_index)} do
        {{:literal, event}, {:ok, modules}} ->
          {:cont, {:ok, Enum.into(modules, acc, &{&1, event})}}

        _unresolved ->
          {:halt, :open_world}
      end
    end)
  end

  defp unused(graph, reached, ignore) do
    literals = MapSet.union(string_literals(graph), js_push_names(graph))
    routes = Graph.routes(graph)

    for {entry, _kind} <- Graph.live_modules(graph),
        {:ok, set} <- [Handlers.handler_set(entry.name, :handle_event, routes)],
        set.closed?,
        {:literal, event} <- set.patterns,
        not MapSet.member?(reached, {entry.name, event}),
        not MapSet.member?(literals, event),
        not NameFilter.matches_any?(event, ignore),
        clause <- clause_for(entry, event) do
      span = Span.new(entry.file, {clause.line, clause.column}, {clause.line, clause.column + 3})

      Diagnostic.new(
        __MODULE__,
        span,
        "`handle_event(\"#{event}\", ...)` in `#{inspect(entry.name)}` has no emitter in the project."
      )
    end
  end

  defp clause_for(entry, event) do
    entry.functions
    |> Map.get({:handle_event, 3}, [])
    |> Enum.filter(&match?(%{args: [^event | _]}, &1))
    |> Enum.take(1)
  end

  # Literal event names every JavaScript push in the project sends.
  defp js_push_names(graph) do
    for facts <- graph.js,
        %{event: {:literal, event}} <- facts.pushes,
        into: MapSet.new(),
        do: event
  end

  # Binary literals in function bodies anywhere in the project. Handler heads
  # are clause arguments, not bodies, so they do not count.
  defp string_literals(graph) do
    for {_entry, clause} <- Graph.clauses(graph),
        literal when is_binary(literal) <- Macro.prewalker(clause.body),
        into: MapSet.new(),
        do: literal
  end
end
