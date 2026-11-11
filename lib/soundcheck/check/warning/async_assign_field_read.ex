defmodule Soundcheck.Check.Warning.AsyncAssignFieldRead do
  use Soundcheck.Check,
    id: "SC206",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :syntactic,
    default: true,
    summary:
      "Template reads like `@org.name` of `assign_async` assigns, which hold an `AsyncResult` and raise on render",
    explanations: [
      check: """
      Flags template reads such as `@org.name` of an assign that
      `assign_async/3,4` sets. The assign holds a
      `Phoenix.LiveView.AsyncResult`, whose only fields are `ok?`,
      `loading`, `failed`, and `result`, so any other field raises
      `KeyError` on render.

      Before:

          assign_async(socket, :org, fn -> {:ok, %{org: fetch_org!(id)}} end)

          <h1>{@org.name}</h1>

      After:

          <.async_result :let={org} assign={@org}>
            <:loading>Loading...</:loading>
            <h1>{org.name}</h1>
          </.async_result>

      The check reads the module's own writes: a key counts as async when
      `assign_async` sets it and every other write is an `update/3` or a
      value built with `AsyncResult`. Reads come from the module's
      `render/1` template, colocated or inline.
      """
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Analysis.AssignUse
  alias Soundcheck.Analysis.Components
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Reads
  alias Soundcheck.Span

  @fields [:ok?, :loading, :failed, :result]
  @async_result [[:AsyncResult], [:Phoenix, :LiveView, :AsyncResult]]

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    for %{kind: kind} = entry <- graph.modules,
        kind in [:live_view, :live_component],
        keys = async_keys(entry),
        keys != [],
        template <- Components.render_templates(graph, entry.name),
        {key, field, span} <- field_reads(template),
        key in keys,
        field not in @fields do
      Diagnostic.new(
        __MODULE__,
        span,
        "`@#{key}` comes from `assign_async`, so it holds an `AsyncResult` without a " <>
          "`#{field}` field; LiveView raises on render.",
        suggestion: "Read `@#{key}.result.#{field}` or render it through `<.async_result>`.",
        anchor: Anchors.for_template(graph, template, span)
      )
    end
  end

  defp async_keys(entry) do
    entry
    |> AssignUse.writes()
    |> Enum.group_by(& &1.key)
    |> Enum.flat_map(fn {key, writes} ->
      {async, others} = Enum.split_with(writes, &(&1.call == :assign_async))
      if async != [] and Enum.all?(others, &async_write?/1), do: [key], else: []
    end)
  end

  defp async_write?(%{call: :update}), do: true
  defp async_write?(%{value: value}), do: mentions_async_result?(value)

  defp mentions_async_result?(value) do
    value
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:__aliases__, _, segments} -> segments in @async_result
      _node -> false
    end)
  end

  defp field_reads(%{file: file} = template) do
    for ast <- Reads.expressions(template),
        {{:., _, [{:@, meta, [{key, _, context}]}, field]}, _, []} <- Macro.prewalker(ast),
        is_atom(key) and is_atom(context) and is_atom(field),
        do: {key, field, Span.covering(file, meta, "@#{key}.#{field}")}
  end
end
