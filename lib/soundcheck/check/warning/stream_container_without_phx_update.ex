defmodule Soundcheck.Check.Warning.StreamContainerWithoutPhxUpdate do
  use Soundcheck.Check,
    id: "SC304",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :syntactic,
    default: true,
    summary: "Stream loops whose parent element lacks `phx-update=\"stream\"`",
    explanations: [
      check: """
      Flags elements that loop over a stream whose parent lacks
      `phx-update="stream"`. Without it, LiveView replaces the container's
      children on every update instead of inserting and deleting stream
      items, so items disappear. LiveView reports this only in the browser,
      in debug mode.

      Before:

          <ul id="posts">
            <li :for={{id, post} <- @streams.posts} id={id}>{post.title}</li>
          </ul>

      After:

          <ul id="posts" phx-update="stream">
            <li :for={{id, post} <- @streams.posts} id={id}>{post.title}</li>
          </ul>

      Loops whose parent is a component or slot, or that sit at the
      template root, are skipped: the container is rendered elsewhere.
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
        %{element: element, parent: %Node.Element{kind: :html} = parent, stream: stream} <-
          Streams.loops(template),
        not stream_container?(parent) do
      Diagnostic.new(
        __MODULE__,
        parent.open_span,
        "`<#{parent.tag}>` contains a loop over `@streams.#{stream}` but has no " <>
          "`phx-update=\"stream\"`.",
        anchor: Anchors.for_template(graph, template, parent.open_span),
        related: [{element.open_span, "the stream loop"}]
      )
    end
  end

  defp stream_container?(%Node.Element{attrs: attrs}),
    do:
      Enum.any?(
        attrs,
        &match?(%Node.Attr{name: "phx-update", value: {:string, "stream", _, _}}, &1)
      )
end
