defmodule Soundcheck.Check.Warning.StreamConsumedOutsideFor do
  use Soundcheck.Check,
    id: "SC306",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :syntactic,
    default: true,
    summary: "`@streams.name` passed to `Enum`, `length/1`, and other enumerating functions",
    explanations: [
      check: """
      Flags `@streams.name` passed straight to an enumerating function
      (`Enum`, `List`, `Stream`, `Map`, `MapSet`, `Keyword`, `length/1`,
      `hd/1`, `tl/1`). LiveView raises at render time, because a stream is
      not a list: its items are not kept on the server.

      Before:

          <p>{length(@streams.posts)} posts</p>

      After: keep a separate count assign.

          <p>{@post_count} posts</p>

      Allowed: `:for={{id, item} <- @streams.name}`,
      `<%= for {id, item} <- @streams.name do %>`, and passing the stream to
      a component attribute (`<.table rows={@streams.posts}>`), which
      iterates it.
      """
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Analysis.Streams
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    for template <- graph.templates,
        read <- Streams.enumerations(template) do
      Diagnostic.new(
        __MODULE__,
        read.span,
        "`@streams.#{read.name}` is enumerated outside a comprehension; LiveView raises, " <>
          "because streams keep no items on the server.",
        anchor: Anchors.for_template(graph, template, read.span)
      )
    end
  end
end
