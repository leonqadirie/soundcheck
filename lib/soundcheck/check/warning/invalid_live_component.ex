defmodule Soundcheck.Check.Warning.InvalidLiveComponent do
  use Soundcheck.Check,
    id: "SC311",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :semantic,
    default: true,
    summary:
      "`<.live_component>` calls without `id` or `module`, or whose `module` is not a LiveComponent, which raise on render",
    tier_note:
      "semantic for the module check (run `mix compile` before `mix credo`); the missing-attribute checks work without compiling",
    explanations: [
      check: """
      Flags `<.live_component>` calls that LiveView rejects when it
      renders them: a missing `id` or `module`, or a `module` that is not
      a LiveComponent. Each raises `ArgumentError` on render, and the
      compiler reports none of them.

      Before:

          <.live_component module={MyAppWeb.PostLive.FormComponent} post={@post} />

      After:

          <.live_component
            module={MyAppWeb.PostLive.FormComponent}
            id={@post.id || :new}
            post={@post}
          />

      The module check expands the alias as the template's module does and
      reads the compiled module; modules it cannot load are skipped. Calls
      that spread attributes (`{@rest}`) are skipped, since the spread may
      carry both.
      """
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Beam.Introspect
  alias Soundcheck.Diagnostic
  alias Soundcheck.Elixir.ModuleIndex
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Node
  alias Soundcheck.Heex.Walker

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    for template <- graph.templates,
        %Node.Element{tag: ".live_component", attrs: attrs} = element <-
          Walker.elements(template.root),
        attrs = Map.new(attrs, &{&1.name, &1}),
        not Map.has_key?(attrs, :root),
        problem <- problems(graph, template, attrs) do
      Diagnostic.new(
        __MODULE__,
        element.open_span,
        "This `<.live_component>` #{problem}, so LiveView raises when it renders.",
        anchor: Anchors.for_template(graph, template, element.open_span)
      )
    end
  end

  defp problems(graph, template, attrs) do
    missing = for name <- ["module", "id"], not Map.has_key?(attrs, name), do: "has no `#{name}`"
    missing ++ List.wrap(module_problem(graph, template, attrs["module"]))
  end

  defp module_problem(graph, template, %Node.Attr{value: {:expr, ast, _source, _span}}) do
    module = expand(graph, template, ast)

    case is_atom(module) and Introspect.live(module) do
      {:ok, %{kind: :view}} -> "renders `#{inspect(module)}`, a LiveView, not a LiveComponent"
      {:error, :not_live} -> "renders `#{inspect(module)}`, which is not a LiveComponent"
      _component_or_unknown -> nil
    end
  end

  defp module_problem(_graph, _template, _attr), do: nil

  defp expand(graph, %{owner: {owner, _fun}}, {:__aliases__, _, _} = ast) do
    aliases =
      case Graph.module(graph, owner) do
        %{aliases: aliases} -> aliases
        nil -> %{}
      end

    ModuleIndex.expand(ast, aliases)
  end

  defp expand(_graph, _template, _ast), do: nil
end
