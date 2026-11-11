defmodule Soundcheck.Check.Warning.InvalidLiveRender do
  use Soundcheck.Check,
    id: "SC312",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :semantic,
    default: true,
    summary:
      "Nested `live_render(socket, ...)` calls without an `:id`, or of a module that is not a LiveView, which raise on render",
    tier_note:
      "semantic for the module check (run `mix compile` before `mix credo`); the `:id` check works without compiling",
    explanations: [
      check: """
      Flags nested `live_render(socket, View, opts)` calls that LiveView
      rejects: `opts` carry no `:id`, which raises `ArgumentError`, or
      `View` is not a LiveView, which raises when it renders.

      Before:

          {live_render(@socket, MyAppWeb.ClockLive)}

      After:

          {live_render(@socket, MyAppWeb.ClockLive, id: "clock")}

      Only calls whose first argument is the socket (`@socket` or a
      variable named `socket`) count: `live_render(conn, ...)` from a
      controller template needs no id. The `:id` check needs literal
      options; the module check expands the alias as the calling module
      expands it and skips modules it cannot load.
      """
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Analysis.Calls
  alias Soundcheck.Beam.Introspect
  alias Soundcheck.Diagnostic
  alias Soundcheck.Elixir.ModuleIndex
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Reads
  alias Soundcheck.Span

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    in_templates =
      for template <- graph.templates,
          {owner, _fun} <- [template.owner],
          ast <- Reads.expressions(template),
          {call, span} <- calls(ast, template.file),
          problem <- problems(call, aliases(graph, owner)) do
        diagnostic(span, Anchors.for_template(graph, template, span), problem)
      end

    in_code =
      for {entry, clause} <- Graph.clauses(graph),
          {call, span} <- calls(clause.body, entry.file),
          problem <- problems(call, entry.aliases) do
        diagnostic(span, span, problem)
      end

    in_templates ++ in_code
  end

  defp diagnostic(span, anchor, problem) do
    Diagnostic.new(
      __MODULE__,
      span,
      "This nested `live_render` #{problem}, so LiveView raises when it renders.",
      anchor: anchor
    )
  end

  defp aliases(graph, owner) do
    case Graph.module(graph, owner) do
      %{aliases: aliases} -> aliases
      nil -> %{}
    end
  end

  # `{args, span}` for every `live_render` call whose first argument is
  # the socket.
  defp calls(ast, file) do
    for {:live_render, meta, [socket | _] = args} <-
          Calls.named(ast, [:live_render], remote: :any),
        socket?(socket),
        do: {args, Span.covering(file, meta, "live_render")}
  end

  defp socket?({:@, _, [{:socket, _, context}]}) when is_atom(context), do: true
  defp socket?({:socket, _, context}) when is_atom(context), do: true
  defp socket?(_ast), do: false

  defp problems([_socket, view | rest], aliases) do
    List.wrap(id_problem(rest)) ++ List.wrap(view_problem(view, aliases))
  end

  defp problems(_args, _aliases), do: []

  defp id_problem([]), do: "passes no `:id`"

  defp id_problem([opts | _]) when is_list(opts) do
    if Keyword.keyword?(opts) and not Keyword.has_key?(opts, :id), do: "passes no `:id`"
  end

  defp id_problem(_dynamic), do: nil

  defp view_problem({:__aliases__, _, _} = ast, aliases) do
    module = ModuleIndex.expand(ast, aliases)

    case is_atom(module) and Introspect.live(module) do
      {:ok, %{kind: :component}} ->
        "renders `#{inspect(module)}`, a LiveComponent, not a LiveView"

      {:error, :not_live} ->
        "renders `#{inspect(module)}`, which is not a LiveView"

      _view_or_unknown ->
        nil
    end
  end

  defp view_problem(_ast, _aliases), do: nil
end
