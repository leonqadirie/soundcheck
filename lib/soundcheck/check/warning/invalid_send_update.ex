defmodule Soundcheck.Check.Warning.InvalidSendUpdate do
  use Soundcheck.Check,
    id: "SC605",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :semantic,
    default: true,
    summary:
      "`send_update` calls without an `:id`, or targeting a module that is not a LiveComponent, whose update raises or goes nowhere",
    tier_note:
      "semantic for the module check (run `mix compile` before `mix credo`); the `:id` check works without compiling",
    explanations: [
      check: """
      Flags `send_update/2,3` and `send_update_after/3,4` calls that cannot
      reach a LiveComponent: the assigns name a module but carry no `:id`,
      which raises `ArgumentError`, or the module is a LiveView or a plain
      module. No rendered component matches such a module, so LiveView
      drops the update with only a debug log, or raises when the module
      does not exist.

      Before:

          send_update(MyAppWeb.PostLive.Index, id: "post-form", post: post)

      After:

          send_update(MyAppWeb.PostLive.FormComponent, id: "post-form", post: post)

      The module must be a literal alias or `__MODULE__`, expanded as the
      calling module expands it, and the `:id` check needs literal assigns
      (a keyword list or map). Calls targeting `@myself` or another CID are
      skipped.
      """
    ]

  alias Soundcheck.Analysis.Calls
  alias Soundcheck.Beam.Introspect
  alias Soundcheck.Diagnostic
  alias Soundcheck.Elixir.ModuleIndex
  alias Soundcheck.Graph
  alias Soundcheck.Span

  @functions [:send_update, :send_update_after]

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    for {entry, clause} <- Graph.clauses(graph),
        {function, meta, args} <- Calls.named(clause.body, @functions),
        {module, assigns} <- [target(args, entry)],
        problem <- problems(module, assigns) do
      span = Span.covering(entry.file, meta, Atom.to_string(function))

      Diagnostic.new(__MODULE__, span, "This `#{function}` #{problem}.")
    end
  end

  # The module and assigns ASTs: the module is the first argument that is
  # an alias or `__MODULE__`, and the assigns follow it.
  defp target(args, entry) do
    case Enum.drop_while(args, &(not module_ast?(&1))) do
      [module, assigns | _] -> {expand(module, entry), assigns}
      _cid_or_dynamic -> {nil, nil}
    end
  end

  defp module_ast?({:__aliases__, _, _}), do: true
  defp module_ast?({:__MODULE__, _, context}) when is_atom(context), do: true
  defp module_ast?(_ast), do: false

  defp expand({:__MODULE__, _, _}, entry), do: entry.name
  defp expand(ast, entry), do: ModuleIndex.expand(ast, entry.aliases)

  defp problems(nil, _assigns), do: []

  defp problems(module, assigns) do
    List.wrap(id_problem(module, assigns)) ++ List.wrap(module_problem(module))
  end

  defp id_problem(module, assigns) when is_atom(module) do
    case literal_keys(assigns) do
      {:ok, keys} ->
        if :id not in keys, do: "names `#{inspect(module)}` without an `:id`, so LiveView raises"

      :error ->
        nil
    end
  end

  defp id_problem(_module, _assigns), do: nil

  defp literal_keys(keyword) when is_list(keyword) do
    if Enum.all?(keyword, &match?({key, _} when is_atom(key), &1)),
      do: {:ok, Keyword.keys(keyword)},
      else: :error
  end

  defp literal_keys({:%{}, _, pairs}) do
    if Enum.all?(pairs, &match?({key, _} when is_atom(key), &1)),
      do: {:ok, Enum.map(pairs, &elem(&1, 0))},
      else: :error
  end

  defp literal_keys(_assigns), do: :error

  defp module_problem(module) when is_atom(module) do
    case Introspect.live(module) do
      {:ok, %{kind: :view}} ->
        "targets `#{inspect(module)}`, a LiveView, so no component receives the update"

      {:error, :not_live} ->
        "targets `#{inspect(module)}`, which is not a LiveComponent, so no component receives " <>
          "the update"

      _component_or_unknown ->
        nil
    end
  end

  defp module_problem(_module), do: nil
end
