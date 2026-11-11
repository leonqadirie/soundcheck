defmodule Soundcheck.Check.Refactor.TemporaryAssignCandidate do
  use Soundcheck.Check,
    id: "SC308",
    base_priority: :low,
    category: :refactor,
    confidence: :low,
    tier: :syntactic,
    default: false,
    summary: "List assigns replaced whole, rendered once with `:for`, and never read in code",
    explanations: [
      check: """
      Flags list assigns that are only replaced whole, rendered once with
      `:for`, and never read in code. The LiveView keeps the list in memory
      after rendering it, though nothing reads it again until the next
      replacement.

      Before:

          def handle_event("refresh", _params, socket) do
            {:noreply, assign(socket, :log_lines, fetch_log())}
          end

          <p :for={line <- @log_lines}>{line}</p>

      After, with a stream:

          {:noreply, stream(socket, :log_lines, fetch_log(), reset: true)}

      Or declare the key in `temporary_assigns` returned from `mount/3`.
      Keys already in `temporary_assigns`, keys written with `update/3`,
      `assign_new/3`, or `assign_async/3`, and keys read through
      `socket.assigns` are left out.
      """
    ]

  alias Soundcheck.Analysis.AssignUse
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Span

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    layout_reads = AssignUse.layout_reads(graph)

    for %{kind: :live_view} = entry <- graph.modules,
        looped = AssignUse.for_sources(graph, entry),
        MapSet.size(looped) > 0,
        reads = AssignUse.reads(graph, entry, layout_reads),
        not reads.open?,
        temporary = AssignUse.temporary(entry),
        {key, [first | _] = writes} <- entry |> AssignUse.writes() |> Enum.group_by(& &1.key),
        key in looped,
        Enum.all?(writes, &(&1.call == :assign)),
        Enum.count(reads.template, &(&1 == key)) == 1,
        key not in reads.code and key not in temporary do
      span = Span.new(entry.file, {first.line, first.column}, {first.line, first.column + 6})

      Diagnostic.new(
        __MODULE__,
        span,
        "`#{inspect(key)}` is replaced whole and rendered once with `:for`; a stream or " <>
          "`temporary_assigns` would free it after each render."
      )
    end
  end
end
