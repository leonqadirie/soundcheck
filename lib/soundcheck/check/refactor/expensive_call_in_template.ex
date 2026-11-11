defmodule Soundcheck.Check.Refactor.ExpensiveCallInTemplate do
  use Soundcheck.Check,
    id: "SC309",
    base_priority: :normal,
    category: :refactor,
    confidence: :medium,
    tier: :syntactic,
    default: false,
    summary: "Database, HTTP, and sorting calls inside template expressions",
    param_defaults: [
      expensive_modules: [~r/\.Repo$/, ~r/^Ecto\.Query$/, ~r/^(Req|Finch|HTTPoison|Tesla)$/],
      expensive_functions: [
        {Enum, :sort},
        {Enum, :sort_by},
        {Enum, :group_by},
        {Enum, :frequencies}
      ]
    ],
    explanations: [
      check: """
      Flags database, HTTP, and sorting calls inside template expressions.
      LiveView re-evaluates an expression whenever an assign it reads
      changes, so the query or request runs again on every such change, and
      on every render when the expression reads no tracked assign.

      Before:

          <p>{Repo.aggregate(Post, :count)} posts</p>

      After:

          # in mount/3 or the event that changes the count
          assign(socket, :post_count, Repo.aggregate(Post, :count))

          <p>{@post_count} posts</p>

      Modules match `expensive_modules` (atoms or regexes on the
      alias-expanded name); `{Module, :function}` pairs in
      `expensive_functions` add individual functions.
      """,
      params: [
        expensive_modules: "Modules whose calls count as expensive: atoms or regexes.",
        expensive_functions: "`{Module, :function}` pairs that count as expensive."
      ]
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Diagnostic
  alias Soundcheck.Elixir.ModuleIndex
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Reads
  alias Soundcheck.NameFilter
  alias Soundcheck.Span

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, params) do
    for template <- graph.templates,
        aliases = aliases(graph, template),
        expression <- Reads.expressions(template),
        {module, fun, meta, written} <- remote_calls(expression, aliases),
        expensive?(module, fun, params) do
      {line, column} = {meta[:line], meta[:column]}
      span = Span.new(template.file, {line, column}, {line, column + String.length(written)})

      Diagnostic.new(
        __MODULE__,
        span,
        "`#{written}` runs inside the template, again whenever its inputs change; " <>
          "compute it in a callback and assign the result.",
        anchor: Anchors.for_template(graph, template, span)
      )
    end
  end

  defp aliases(graph, %{owner: {module, _fun}}) do
    case Graph.module(graph, module) do
      nil -> %{}
      entry -> entry.aliases
    end
  end

  defp aliases(_graph, _template), do: %{}

  defp expensive?(module, fun, params) do
    NameFilter.matches_any?(module, Keyword.fetch!(params, :expensive_modules)) or
      {module, fun} in Keyword.fetch!(params, :expensive_functions)
  end

  defp remote_calls(ast, aliases) do
    for {{:., _, [{:__aliases__, meta, _} = alias_ast, fun]}, _, args} <- Macro.prewalker(ast),
        is_atom(fun) and is_list(args),
        module <- [ModuleIndex.expand(alias_ast, aliases)],
        is_atom(module),
        do: {module, fun, meta, "#{Macro.to_string(alias_ast)}.#{fun}"}
  end
end
