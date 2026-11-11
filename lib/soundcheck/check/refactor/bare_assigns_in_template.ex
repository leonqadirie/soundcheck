defmodule Soundcheck.Check.Refactor.BareAssignsInTemplate do
  use Soundcheck.Check,
    id: "SC301",
    base_priority: :normal,
    category: :refactor,
    confidence: :high,
    tier: :syntactic,
    default: false,
    summary: "The bare `assigns` in template expressions, which disables change tracking",
    explanations: [
      check: """
      Flags the bare `assigns` variable in template expressions. LiveView
      cannot tell which assigns such an expression depends on, so it
      re-renders it on every change, and LiveView gives no warning.

      Before:

          <p>{format_title(assigns)}</p>
          <.card {assigns} />

      After:

          <p>{format_title(@title, @subtitle)}</p>
          <.card title={@title} subtitle={@subtitle} />

      `@key`, `assigns.key`, and `assigns[:key]` are tracked and never
      reported.
      """
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Reads
  alias Soundcheck.Span

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    for template <- graph.templates,
        expression <- Reads.expressions(template),
        meta <- bare_assigns(expression) do
      {line, column} = {meta[:line], meta[:column]}
      span = Span.new(template.file, {line, column}, {line, column + String.length("assigns")})

      Diagnostic.new(
        __MODULE__,
        span,
        "The bare `assigns` disables change tracking: LiveView re-renders this expression on every change.",
        anchor: Anchors.for_template(graph, template, span)
      )
    end
  end

  # Positions of `assigns` that are not the subject of `.key` or `[:key]`.
  defp bare_assigns(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:assigns, _, context}, key]}, _, []} = node, acc
        when is_atom(context) and is_atom(key) ->
          {skip(node), acc}

        {{:., _, [Access, :get]}, _, [{:assigns, _, context}, _key]} = node, acc
        when is_atom(context) ->
          {skip(node), acc}

        {:assigns, meta, context} = node, acc when is_atom(context) ->
          {node, [meta | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  # Replaces a tracked access so the walk does not descend into its
  # `assigns` subject.
  defp skip(_node), do: :tracked_access
end
