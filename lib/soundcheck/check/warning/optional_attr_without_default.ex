defmodule Soundcheck.Check.Warning.OptionalAttrWithoutDefault do
  use Soundcheck.Check,
    id: "SC204",
    base_priority: :normal,
    category: :warning,
    confidence: :medium,
    tier: :syntactic,
    default: false,
    summary:
      "`@key` reads of optional attrs without a default, which raise when a caller omits them",
    explanations: [
      check: """
      Flags `@key` reads of an optional `attr` that declares no default.
      Phoenix puts only declared defaults into a component's assigns, so
      when a caller omits the attr, `@key` raises `KeyError`, even inside
      `:if={@key}`.

      Before:

          attr :icon, :string

          def badge(assigns), do: ~H"<span :if={@icon}>{@icon}</span>"

      After:

          attr :icon, :string, default: nil

          def badge(assigns), do: ~H"<span :if={@icon}>{@icon}</span>"

      Reading the attr as `assigns[:icon]` never raises and is not
      reported. Attrs marked `required: true`, `:global` attrs, keys the
      component body assigns before rendering (`assign_new/3` included),
      components whose body rebinds `assigns` through another function, and
      LiveView or LiveComponent `render/1` functions are skipped.
      """
    ]

  alias Soundcheck.Analysis.ComponentAssigns
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Reads

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    for module <- graph.modules,
        module.name != nil,
        {fun, declarations} <- module.components,
        not ComponentAssigns.live_render?(module, fun),
        clauses = Map.get(module.functions, {fun, 1}, []),
        {:ok, assigned} <- [ComponentAssigns.keys(clauses)],
        risky = risky_attrs(declarations, assigned),
        risky != MapSet.new(),
        template <- Graph.templates_of(graph, module.name, fun),
        matched = ComponentAssigns.head_keys(clauses, template),
        read <- template |> Reads.assigns() |> Enum.uniq_by(& &1.key),
        MapSet.member?(risky, read.key),
        not MapSet.member?(matched, read.key) do
      Diagnostic.new(
        __MODULE__,
        read.span,
        "`#{fun}/1` reads `@#{read.key}`, but `attr :#{read.key}` is optional without a " <>
          "default: a caller that omits it raises KeyError. Add `default: nil` or `required: true`."
      )
    end
  end

  # Optional attrs without a default that the body does not assign itself.
  defp risky_attrs(declarations, assigned) do
    for %{name: name, type: type, opts: opts} <- declarations.attrs,
        type != :global,
        is_list(opts),
        not Keyword.has_key?(opts, :default),
        opts[:required] != true,
        not MapSet.member?(assigned, name),
        into: MapSet.new(),
        do: name
  end
end
