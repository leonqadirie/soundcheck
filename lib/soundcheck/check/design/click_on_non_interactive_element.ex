defmodule Soundcheck.Check.Design.ClickOnNonInteractiveElement do
  use Soundcheck.Check,
    id: "SC901",
    base_priority: :normal,
    category: :design,
    confidence: :high,
    tier: :syntactic,
    default: false,
    summary: "`phx-click` on non-interactive elements without role or keyboard support",
    param_defaults: [non_interactive_tags: ~w(div span li td tr img p section article)],
    explanations: [
      check: """
      Flags `phx-click` on elements that are not interactive (`div`,
      `span`, `li`, ...) and give keyboard and assistive-technology users no
      way in: no `role`, no `tabindex`, and no `phx-keydown` or `phx-keyup`.
      Screen readers do not announce the element as clickable, and keyboard
      users cannot reach it.

      Before:

          <div phx-click="open">Details</div>

      After:

          <button type="button" phx-click="open">Details</button>

      or, when the element must stay a `div`:

          <div role="button" tabindex="0" phx-click="open" phx-keydown="open" phx-key="Enter">
      """,
      params: [
        non_interactive_tags: "HTML tags that are not interactive by default."
      ]
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Node
  alias Soundcheck.Heex.Walker

  @accessible ["role", "tabindex", "phx-keydown", "phx-keyup", "phx-window-keydown", :root]

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, params) do
    for template <- graph.templates,
        %Node.Element{kind: :html, tag: tag, attrs: attrs} = element <-
          Walker.elements(template.root),
        tag in Keyword.fetch!(params, :non_interactive_tags),
        Enum.any?(attrs, &(&1.name == "phx-click")),
        not Enum.any?(attrs, &(&1.name in @accessible)) do
      Diagnostic.new(
        __MODULE__,
        element.open_span,
        "`<#{tag} phx-click>` is not reachable by keyboard or announced as clickable; " <>
          "use a `<button>`, or add `role`, `tabindex`, and a key handler.",
        anchor: Anchors.for_template(graph, template, element.open_span)
      )
    end
  end
end
