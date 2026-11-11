defmodule Soundcheck.Analysis.Anchors do
  @moduledoc false
  # Picks the Credo anchor for a finding located in a template.
  #
  # Credo only reports issues in files it loaded, which are Elixir files. A
  # finding in a `~H` sigil anchors at itself. A finding in a `.heex` file
  # anchors in the owning module's file: at its `embed_templates` call, or at
  # `defmodule` for a colocated LiveView template.

  alias Soundcheck.Graph
  alias Soundcheck.Heex.Template
  alias Soundcheck.Span

  @spec for_template(Graph.t(), Template.t(), Span.t()) :: Span.t()
  def for_template(_graph, %Template{origin: :sigil}, span), do: span

  def for_template(graph, %Template{owner: {module, _fun}}, span) do
    case Graph.module(graph, module) do
      nil ->
        span

      entry ->
        {line, column} =
          case entry.embed_templates do
            [%{line: line, column: column} | _] -> {line, column}
            [] -> entry.span.start
          end

        Span.new(entry.file, {line, column}, {line, column + 1})
    end
  end

  def for_template(_graph, _template, span), do: span
end
