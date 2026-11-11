defmodule Soundcheck.Check.Warning.UndeclaredComponentAttr do
  use Soundcheck.Check,
    id: "SC203",
    base_priority: :normal,
    category: :warning,
    confidence: :high,
    tier: :syntactic,
    default: true,
    summary: "`@key` reads in function components that declare attrs but not `key`",
    param_defaults: [implicit_assigns: [:inner_block, :rest, :__changed__, :__given__]],
    explanations: [
      check: """
      Flags `@assign` reads in a function component that declares its
      interface with `attr`/`slot` but declares no attr or slot of that name.

      Phoenix only puts declared attrs (and their defaults) into a
      component's assigns, and warns at call sites that pass undeclared
      ones. An undeclared `@key` therefore raises `KeyError` on every
      render that does not happen to receive it.

      Before:

          attr :title, :string, required: true

          def card(assigns) do
            ~H"<h2>{@title}</h2><p>{@subtitle}</p>"
          end

      After:

          attr :title, :string, required: true
          attr :subtitle, :string, default: nil

          def card(assigns) do
            ~H"<h2>{@title}</h2><p>{@subtitle}</p>"
          end

      The check skips a component when:

        * it declares no `attr` or `slot` at all (its interface is
          undeclared by design);
        * it is a LiveView or LiveComponent `render/1`, whose assigns come
          from the socket rather than from attrs;
        * its body assigns keys from a non-literal source, such as
          `assign(assigns, some_map)`, `Map.merge/2`, or
          `assigns = normalize(assigns)`, because the set of keys is then
          unknown;
        * its module calls it directly as a function, which bypasses attr
          validation.

      Keys assigned in the component body before rendering
      (`assign(assigns, :key, value)`, `assign_new/3`, `update/3`) count as
      declared.
      """,
      params: [
        implicit_assigns:
          "Assign keys never reported (Phoenix-provided or global by convention).",
        strict: "Report unverifiable findings too."
      ]
    ]

  alias Soundcheck.Analysis.ComponentAssigns
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Reads

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, params) do
    implicit = MapSet.new(Keyword.fetch!(params, :implicit_assigns))

    for module <- graph.modules,
        module.name != nil,
        {fun, declarations} <- module.components,
        not ComponentAssigns.live_render?(module, fun),
        not called_directly?(module, fun),
        {:ok, assigned} <- [ComponentAssigns.keys(Map.get(module.functions, {fun, 1}, []))],
        declared = declared(declarations, assigned, implicit),
        template <- Graph.templates_of(graph, module.name, fun),
        read <- first_reads(template),
        not MapSet.member?(declared, read.key) do
      Diagnostic.new(
        __MODULE__,
        read.span,
        "`#{fun}/1` reads `@#{read.key}` but declares no `attr :#{read.key}` or `slot :#{read.key}`."
      )
    end
  end

  defp declared(declarations, assigned, implicit) do
    (declarations.attrs ++ declarations.slots)
    |> MapSet.new(& &1.name)
    |> MapSet.union(assigned)
    |> MapSet.union(implicit)
  end

  # One diagnostic per key per template, at its first read.
  defp first_reads(template), do: template |> Reads.assigns() |> Enum.uniq_by(& &1.key)

  defp called_directly?(module, fun) do
    Enum.any?(module.functions, fn {_name_arity, clauses} ->
      Enum.any?(clauses, &calls?(&1.body, fun))
    end)
  end

  defp calls?(body, fun) do
    Enum.any?(Macro.prewalker(body), &match?({^fun, _meta, [_assigns]}, &1))
  end
end
