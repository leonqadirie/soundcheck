defmodule Soundcheck.Check.Warning.LiteralLiveComponentIdInLoop do
  use Soundcheck.Check,
    id: "SC313",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :syntactic,
    default: true,
    summary:
      "`<.live_component>` with a literal `id` inside a `:for` loop, which raises once the loop renders two items",
    explanations: [
      check: """
      Flags `<.live_component>` calls with a literal `id` inside a loop: on
      an element with `:for`, or under one or a `<%= for ... %>` block.
      Every iteration renders the component under the same id, so LiveView
      raises "found duplicate ID" once the list holds two items. Tests
      whose fixtures hold zero or one item never see it.

      Before:

          <.live_component :for={post <- @posts} module={PostComponent} id="post" post={post} />

      After:

          <.live_component :for={post <- @posts} module={PostComponent} id={"post-\#{post.id}"} post={post} />

      An id counts as literal when it is a plain string or an expression
      without variables or assigns, such as `id={"post"}` or `id={:new}`.
      """
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Node

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    for template <- graph.templates,
        {id, span} <- looped_ids(template.root, false) do
      Diagnostic.new(
        __MODULE__,
        span,
        "This `<.live_component>` repeats the literal id #{inspect(id)} on every loop " <>
          "iteration, so LiveView raises once the loop renders two items.",
        suggestion: "Derive the id from the loop item, such as `id={\"post-\#{post.id}\"}`.",
        anchor: Anchors.for_template(graph, template, span)
      )
    end
  end

  # `{id, span}` for every live_component with a literal id inside a loop.
  defp looped_ids(nodes, in_loop?) when is_list(nodes),
    do: Enum.flat_map(nodes, &looped_ids(&1, in_loop?))

  defp looped_ids(%Node.Element{attrs: attrs, children: children} = element, in_loop?) do
    in_loop? = in_loop? or Enum.any?(attrs, &(&1.name == ":for"))
    own = if in_loop?, do: literal_id(element), else: []
    List.flatten([own, looped_ids(children, in_loop?)])
  end

  defp looped_ids(%Node.EexBlock{head: %{ast: ast}, clauses: clauses}, in_loop?) do
    in_loop? = in_loop? or match?({:for, _, _}, ast)
    Enum.flat_map(clauses, &looped_ids(&1.children, in_loop?))
  end

  defp looped_ids(_node, _in_loop?), do: []

  defp literal_id(%Node.Element{tag: ".live_component", attrs: attrs}) do
    Enum.flat_map(attrs, fn
      %Node.Attr{name: "id", value: {:string, id, _delimiter, span}} ->
        [{id, span}]

      %Node.Attr{name: "id", value: {:expr, ast, _source, span}} ->
        if constant?(ast), do: [{ast, span}], else: []

      _attr ->
        []
    end)
  end

  defp literal_id(_element), do: []

  # An expression without variables, assigns, or calls evaluates to the
  # same value on every iteration.
  defp constant?({:error, _reason}), do: false
  defp constant?(ast), do: Macro.quoted_literal?(ast)
end
