defmodule Soundcheck.Check.Warning.StreamChildWithoutId do
  use Soundcheck.Check,
    id: "SC305",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :syntactic,
    default: true,
    summary: "Children of stream containers without an `id={...}` from the stream",
    explanations: [
      check: """
      Flags direct children of a `phx-update="stream"` container that lack
      an `id={...}` expression. LiveView tracks stream items by DOM id: a
      child without one, or with a literal id that every item repeats, breaks
      inserts, updates, and deletes. LiveView reports this only in the
      browser.

      Before:

          <ul id="posts" phx-update="stream">
            <li :for={{_id, post} <- @streams.posts}>{post.title}</li>
          </ul>

      After:

          <ul id="posts" phx-update="stream">
            <li :for={{id, post} <- @streams.posts} id={id}>{post.title}</li>
          </ul>

      A static child with a literal id, such as the empty-state element
      LiveView's docs show (`<li id="posts-empty" class="only:block hidden">`),
      renders once and is fine. Component children are skipped: the element
      they render is not visible in the template.
      """
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Analysis.Streams
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Node

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    for template <- graph.templates,
        container <- Streams.containers(template),
        %Node.Element{kind: :html} = child <- container.children,
        problem = id_problem(child),
        problem != nil do
      Diagnostic.new(
        __MODULE__,
        child.open_span,
        "`<#{child.tag}>` inside a `phx-update=\"stream\"` container #{problem}.",
        anchor: Anchors.for_template(graph, template, child.open_span),
        related: [{container.open_span, "the stream container"}]
      )
    end
  end

  defp id_problem(%Node.Element{attrs: attrs}) do
    attrs = Map.new(attrs, &{&1.name, &1})

    case attrs["id"] do
      %Node.Attr{value: {:expr, _ast, _source, _span}} ->
        nil

      %Node.Attr{value: {:string, value, _, _}} ->
        if Map.has_key?(attrs, ":for"),
          do: "has the literal id `#{value}`, which every stream item repeats"

      _missing ->
        "has no `id`; stream items need `id={id}` from the stream"
    end
  end
end
