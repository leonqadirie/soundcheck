defmodule Soundcheck.Check.Refactor.TemplateBoundVariable do
  use Soundcheck.Check,
    id: "SC303",
    base_priority: :normal,
    category: :refactor,
    confidence: :medium,
    tier: :syntactic,
    default: false,
    summary:
      "Variables bound in templates with `<% x = ... %>` and read later, which disables change tracking",
    explanations: [
      check: """
      Flags variables a template binds with `<% name = ... %>` and reads
      afterwards. LiveView cannot track a template-local variable, so every
      expression that reads it re-renders on every change. LiveView warns
      only about variables bound outside the template.

      Before:

          <% total = Enum.sum(@prices) %>
          <p>Total: {total}</p>

      After:

          def mount(_params, _session, socket),
            do: {:ok, assign(socket, prices: prices, total: Enum.sum(prices))}

          <p>Total: {@total}</p>

      Variables bound by `:for`, `:let`, and EEx `for`/`case` clauses are
      tracked by LiveView and never reported.
      """
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Node
  alias Soundcheck.Heex.Reads
  alias Soundcheck.Span

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    for template <- graph.templates,
        %Node.Eex{ast: {:=, _, [{name, meta, context}, _value]}} = binding <-
          eex_nodes(template.root),
        is_atom(name) and is_atom(context),
        read_later?(template, name, binding.span) do
      line = meta[:line]
      column = meta[:column]

      span =
        Span.new(
          template.file,
          {line, column},
          {line, column + String.length(Atom.to_string(name))}
        )

      Diagnostic.new(
        __MODULE__,
        span,
        "Template variable `#{name}` disables change tracking for every expression that reads it; " <>
          "assign it in the LiveView or component instead.",
        anchor: Anchors.for_template(graph, template, span)
      )
    end
  end

  defp eex_nodes(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &eex_nodes/1)
  defp eex_nodes(%Node.Eex{} = eex), do: [eex]
  defp eex_nodes(%Node.Element{children: children}), do: eex_nodes(children)

  defp eex_nodes(%Node.EexBlock{clauses: clauses}),
    do: Enum.flat_map(clauses, &eex_nodes(&1.children))

  defp eex_nodes(_node), do: []

  defp read_later?(template, name, %Span{stop: binding_end}) do
    template
    |> Reads.expressions()
    |> Enum.any?(&reads_after?(&1, name, binding_end))
  end

  defp reads_after?(ast, name, binding_end) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {^name, meta, context} when is_atom(context) -> {meta[:line], meta[:column]} >= binding_end
      _node -> false
    end)
  end
end
