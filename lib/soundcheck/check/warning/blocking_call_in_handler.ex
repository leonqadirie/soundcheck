defmodule Soundcheck.Check.Warning.BlockingCallInHandler do
  use Soundcheck.Check,
    id: "SC602",
    base_priority: :normal,
    category: :warning,
    confidence: :medium,
    tier: :syntactic,
    default: false,
    summary:
      "Sleeps, awaits, HTTP calls, and unbounded `receive` in event, info, and params handlers",
    param_defaults: [
      blocking_functions: [
        {Process, :sleep},
        {:timer, :sleep},
        {Task, :await},
        {Task, :await_many},
        {Task, :yield},
        {Task, :yield_many}
      ],
      blocking_modules: [~r/^(Req|Finch|HTTPoison|Tesla)$/]
    ],
    explanations: [
      check: """
      Flags calls that block a LiveView process inside `handle_event/3`,
      `handle_info/2`, and `handle_params/3`: sleeps, `Task.await/2`, HTTP
      requests, and `receive` without `after`. A LiveView handles one
      message at a time, so while the handler waits, the page ignores
      every click, keystroke, and broadcast.

      Before:

          def handle_event("refresh", _params, socket) do
            prices = Req.get!("https://api.example.com/prices").body
            {:noreply, assign(socket, :prices, prices)}
          end

      After:

          def handle_event("refresh", _params, socket) do
            {:noreply,
             start_async(socket, :prices, fn -> Req.get!("https://api.example.com/prices").body end)}
          end

      Calls inside closures (`start_async/3`, `Task.async/1`) do not count.
      `blocking_functions` lists `{Module, :function}` pairs and
      `blocking_modules` lists modules (atoms or regexes on the
      alias-expanded name) whose every call blocks.
      """,
      params: [
        blocking_functions: "`{Module, :function}` pairs that block.",
        blocking_modules: "Modules whose calls block: atoms or regexes."
      ]
    ]

  alias Soundcheck.Analysis.Calls
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.NameFilter
  alias Soundcheck.Span

  @handlers [{:handle_event, 3}, {:handle_info, 2}, {:handle_params, 3}]

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, params) do
    for %{kind: kind} = entry <- graph.modules,
        kind in [:live_view, :live_component],
        {name, arity} = handler <- @handlers,
        clause <- Map.get(entry.functions, handler, []),
        {start, written} <- blocking(clause.body, entry.aliases, params) do
      {line, column} = start
      span = Span.new(entry.file, {line, column}, {line, column + String.length(written)})

      Diagnostic.new(
        __MODULE__,
        span,
        "`#{written}` blocks `#{name}/#{arity}`, and the LiveView handles no other message " <>
          "until it returns; move it into `start_async/3`."
      )
    end
  end

  defp blocking(body, aliases, params) do
    calls =
      for %{module: module, fun: fun} = call <- Calls.remote(body, aliases),
          module != nil,
          {module, fun} in Keyword.fetch!(params, :blocking_functions) or
            NameFilter.matches_any?(module, Keyword.fetch!(params, :blocking_modules)),
          do: {call.start, call.written}

    Enum.sort(calls ++ receives(body))
  end

  # `receive` blocks until a message arrives; an `after` clause bounds it.
  defp receives(body) do
    {_ast, found} =
      Macro.prewalk(body, [], fn
        {:fn, _, _clauses}, acc ->
          {nil, acc}

        {:receive, meta, [clauses]} = node, acc when is_list(clauses) ->
          acc =
            if Keyword.has_key?(clauses, :after),
              do: acc,
              else: [{{meta[:line], meta[:column]}, "receive"} | acc]

          {node, acc}

        node, acc ->
          {node, acc}
      end)

    found
  end
end
