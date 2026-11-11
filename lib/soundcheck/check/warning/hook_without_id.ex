defmodule Soundcheck.Check.Warning.HookWithoutId do
  use Soundcheck.Check,
    id: "SC1003",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :syntactic,
    default: true,
    summary: "HTML elements with `phx-hook` but no `id`, whose hook LiveView never mounts",
    explanations: [
      check: """
      Flags HTML elements with `phx-hook` but no `id`. LiveView tracks hook
      instances by DOM id: without one it logs "no DOM ID for hook" in the
      browser and never mounts the hook.

      Before:

          <div phx-hook="Chart"></div>

      After:

          <div id="revenue-chart" phx-hook="Chart"></div>

      The check skips elements that spread attributes (`{@rest}`), which
      may carry the id, and function component calls, which may set it on
      the element they render.
      """
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Heex.KeywordAttrs
  alias Soundcheck.Heex.Node
  alias Soundcheck.Heex.Walker

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    for template <- graph.templates,
        %Node.Element{kind: :html, attrs: attrs} = element <-
          Walker.elements(template.root) ++ KeywordAttrs.elements(template.root),
        names = Enum.map(attrs, & &1.name),
        "phx-hook" in names,
        "id" not in names,
        :root not in names do
      Diagnostic.new(
        __MODULE__,
        element.open_span,
        "This `<#{element.tag}>` has `phx-hook` but no `id`, so LiveView never mounts the hook.",
        suggestion: "Give it a unique `id`.",
        anchor: Anchors.for_template(graph, template, element.open_span)
      )
    end
  end
end
