defmodule Soundcheck.Check.Design.UnreadAssign do
  use Soundcheck.Check,
    id: "SC205",
    base_priority: :low,
    category: :design,
    confidence: :medium,
    tier: :syntactic,
    default: false,
    summary: "Assign keys no template, layout, or callback reads",
    param_defaults: [ignore_assigns: [:page_title]],
    explanations: [
      check: """
      Flags assign keys a LiveView or LiveComponent sets but never reads:
      not in its templates, not in any layout, and not through
      `socket.assigns` in its code. Every assign lives in the process and
      goes through change tracking for nothing.

      Before:

          def mount(_params, _session, socket) do
            {:ok, assign(socket, posts: list_posts(), page_size: 20)}
          end

          # no template or callback reads @page_size

      After:

          def mount(_params, _session, socket) do
            {:ok, assign(socket, posts: list_posts())}
          end

      Only literal keys count. When code passes the assigns map along whole
      (`helper(socket.assigns)`, `<.panel {assigns} />`), any key could be
      read there, and the check skips the module. Keys read only by an
      `on_mount` hook or a parent are reported; list them in
      `ignore_assigns`.
      """,
      params: [
        ignore_assigns: "Keys never reported (atoms)."
      ]
    ]

  alias Soundcheck.Analysis.AssignUse
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Span

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, params) do
    layout_reads = AssignUse.layout_reads(graph)

    for %{kind: kind, name: name} = entry <- graph.modules,
        kind in [:live_view, :live_component],
        Graph.templates_of(graph, name) != [],
        reads = AssignUse.reads(graph, entry, layout_reads),
        not reads.open?,
        read =
          MapSet.union(
            reads.code,
            MapSet.new(reads.template ++ Keyword.fetch!(params, :ignore_assigns))
          ),
        write <- entry |> AssignUse.writes() |> Enum.uniq_by(& &1.key),
        write.key not in read do
      span =
        Span.new(
          entry.file,
          {write.line, write.column},
          {write.line, write.column + String.length(Atom.to_string(write.call))}
        )

      Diagnostic.new(
        __MODULE__,
        span,
        "`#{inspect(name)}` assigns `#{inspect(write.key)}` but no template, layout, or " <>
          "callback reads it."
      )
    end
  end
end
