defmodule Soundcheck.Check.Readability.AssignsDotAccess do
  use Soundcheck.Check,
    id: "SC302",
    base_priority: :low,
    category: :readability,
    confidence: :high,
    tier: :syntactic,
    default: false,
    summary: "`assigns.key` where `@key` is idiomatic",
    explanations: [
      check: """
      Flags `assigns.key` in template expressions where `@key` is the
      idiomatic spelling. LiveView tracks both the same way, so this is a
      consistency rule, not a performance one.

      Before:

          <p>{assigns.title}</p>

      After:

          <p>{@title}</p>

      `assigns[:key]` is not reported: it returns `nil` for a missing key
      where `@key` raises, so the two are not interchangeable.
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
        {key, meta} <- dot_accesses(expression) do
      {line, column} = {meta[:line], meta[:column]}
      written = "assigns.#{key}"
      span = Span.new(template.file, {line, column}, {line, column + String.length(written)})

      Diagnostic.new(__MODULE__, span, "Write `@#{key}` instead of `#{written}`.",
        anchor: Anchors.for_template(graph, template, span)
      )
    end
  end

  defp dot_accesses(ast) do
    for {{:., _, [{:assigns, meta, context}, key]}, _, []} <- Macro.prewalker(ast),
        is_atom(context) and is_atom(key),
        do: {key, meta}
  end
end
