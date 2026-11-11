defmodule Soundcheck.Check.Warning.LiveViewCallbackInComponent do
  use Soundcheck.Check,
    id: "SC604",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :syntactic,
    default: true,
    summary:
      "LiveView-only callbacks (`handle_info/2`, `mount/3`, `handle_params/3`, ...) in a LiveComponent, which LiveView never calls",
    explanations: [
      check: """
      Flags LiveView callbacks defined in a LiveComponent: `mount/3`,
      `handle_params/3`, `handle_info/2`, `handle_call/3`, `handle_cast/2`,
      and `terminate/2`. A LiveComponent runs in its parent LiveView's
      process and LiveView never calls these on it, so the code is dead.
      `send(self(), msg)` from a component reaches the parent's
      `handle_info/2`, not the component's.

      Before:

          # in a LiveComponent
          def handle_info({:saved, post}, socket), do: {:noreply, assign(socket, :post, post)}

      After:

          # in the parent LiveView
          def handle_info({:saved, post}, socket) do
            send_update(MyAppWeb.PostComponent, id: post.id, post: post)
            {:noreply, socket}
          end

      A function another module calls on the component, such as a parent
      that delegates `handle_info/2` to it, does not count as dead. The
      compiler already warns when the function carries `@impl true`.
      """
    ]

  alias Soundcheck.Diagnostic
  alias Soundcheck.Elixir.ModuleIndex
  alias Soundcheck.Graph
  alias Soundcheck.Span

  @callbacks [
    {:mount, 3},
    {:handle_params, 3},
    {:handle_info, 2},
    {:handle_call, 3},
    {:handle_cast, 2},
    {:terminate, 2}
  ]

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    called = remote_calls(graph)

    for %{kind: :live_component, name: module} = entry <- graph.modules,
        {name, arity} = callback <- @callbacks,
        [first | _] <- [Map.get(entry.functions, callback, [])],
        {module, name, arity} not in called do
      span = Span.new(entry.file, {first.line, first.column}, {first.line, first.column + 3})

      Diagnostic.new(
        __MODULE__,
        span,
        "`#{inspect(module)}` is a LiveComponent, so LiveView never calls its " <>
          "`#{name}/#{arity}`. #{hint(name)}"
      )
    end
  end

  defp hint(:handle_info),
    do: "Messages a component sends to `self()` reach the parent LiveView's `handle_info/2`."

  defp hint(:mount), do: "A LiveComponent's mount callback is `mount/1`."
  defp hint(_name), do: "The component runs in its parent LiveView's process."

  # `{module, function, arity}` for every remote call in the project, with
  # aliases expanded as each calling module expands them.
  defp remote_calls(graph) do
    for {entry, clause} <- Graph.clauses(graph),
        call <- calls_in(clause.body, entry.aliases),
        into: MapSet.new(),
        do: call
  end

  defp calls_in(body, aliases) do
    for {{:., _, [{:__aliases__, _, _} = alias, name]}, _, args} <- Macro.prewalker(body),
        is_list(args),
        do: {ModuleIndex.expand(alias, aliases), name, length(args)}
  end
end
