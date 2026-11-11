defmodule Soundcheck.Check.Warning.UnscopedLookupByClientParam do
  use Soundcheck.Check,
    id: "SC401",
    base_priority: :high,
    category: :warning,
    confidence: :medium,
    tier: :syntactic,
    default: false,
    summary:
      "Repo and context lookups (`Blog.get_post!(id)`) by client-sent event or URL params in clauses that never consult the current user or scope",
    param_defaults: [
      repo_modules: [~r/\.Repo$/],
      lookup_functions: [~r/\.get_\w+!?$/, ~r/\.fetch_\w+!?$/],
      scope_assigns: [:current_scope, :current_user],
      authorizers: [~r/authoriz/, ~r/permit/, ~r/can\?$/, ~r/allowed\?$/],
      excluded_modules: [~r/Admin/]
    ],
    explanations: [
      check: """
      Flags Repo reads in `handle_event/3` and `handle_params/3` that look
      a record up by a client-sent param, in a clause that never consults
      the current user or scope. Event and URL params come from the client:
      any user can send any id.

      Before:

          def handle_event("delete", %{"id" => id}, socket) do
            post = Repo.get!(Post, id)
            {:ok, _} = Repo.delete(post)
            {:noreply, socket}
          end

      After:

          def handle_event("delete", %{"id" => id}, socket) do
            post = Blog.get_post!(socket.assigns.current_scope, id)
            {:ok, _} = Blog.delete_post(socket.assigns.current_scope, post)
            {:noreply, socket}
          end

      A param taints the variables it flows into through `=`, `<-`, and
      pipes, within the clause; calls into helpers are not followed. A
      clause that reads one of `scope_assigns` (`socket.assigns.current_user`,
      or a `%{assigns: %{current_user: user}}` pattern) or calls a function
      matching `authorizers` counts as scoped. Modules matching
      `excluded_modules` are skipped. Ash calls are not Repo calls: Ash
      policies authorize them.

      Context functions count as lookups too: a call into one of the
      project's own modules whose `Mod.fun` name matches `lookup_functions`
      (by default `get_*` and `fetch_*`, such as `Blog.get_post!(id)`).
      Calls into dependencies, the standard library, and modules that `use`
      an Ash module (domains and resources) never match.

      An app that keeps its scope under another assign, such as `:subject`
      or `:current_account`, reports every clause until `scope_assigns`
      names it:

          {Soundcheck.Check.Warning.UnscopedLookupByClientParam,
           [scope_assigns: [:subject]]}
      """,
      params: [
        repo_modules: "Repo modules: atoms or regexes on the alias-expanded name.",
        lookup_functions:
          "Context lookups in the project's own modules: `Mod.fun` names, regexes or exact.",
        scope_assigns: "Assign keys whose use counts as scoping the clause.",
        authorizers: "Function names (`fun` or `Mod.fun`, regexes or exact) that authorize.",
        excluded_modules: "Modules to skip: atoms or regexes."
      ]
    ]

  alias Soundcheck.Diagnostic
  alias Soundcheck.Elixir.ModuleIndex
  alias Soundcheck.Graph
  alias Soundcheck.NameFilter
  alias Soundcheck.Span

  # Repo functions that look records up; inserts take the client's params
  # by design, and updates and deletes act on a struct a lookup returned.
  @lookups [
    :get,
    :get!,
    :get_by,
    :get_by!,
    :one,
    :one!,
    :all,
    :exists?,
    :aggregate,
    :stream,
    :delete_all,
    :update_all
  ]

  @callbacks [{:handle_event, 3}, {:handle_params, 3}]

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, params) do
    # Ash domains and resources authorize their own calls through policies.
    contexts =
      for %{name: name, uses: uses} <- graph.modules,
          name != nil,
          not Enum.any?(uses, &ash?(&1.module)),
          into: MapSet.new(),
          do: name

    for %{kind: kind, name: module} = entry <- graph.modules,
        kind in [:live_view, :live_component],
        not NameFilter.matches_any?(module, Keyword.fetch!(params, :excluded_modules)),
        callback <- @callbacks,
        clause <- Map.get(entry.functions, callback, []),
        not scoped?(clause, entry.aliases, params),
        tainted = taint(params_pattern(callback, clause.args), clause.body),
        MapSet.size(tainted) > 0,
        {written, start} <- lookups(clause.body, tainted, entry.aliases, contexts, params) do
      {line, column} = start
      span = Span.new(entry.file, start, {line, column + String.length(written)})

      Diagnostic.new(
        __MODULE__,
        span,
        "`#{written}` in `#{callback_name(callback, clause)}` looks data up by a client-sent " <>
          "param, and the clause never checks it against the current user or scope."
      )
    end
  end

  defp params_pattern({:handle_event, 3}, [_event, params, _socket]), do: params
  defp params_pattern({:handle_params, 3}, [params, _uri, _socket]), do: params

  defp callback_name({:handle_event, 3}, %{args: [event | _]}) when is_binary(event),
    do: "handle_event(#{inspect(event)}, ...)"

  defp callback_name({name, arity}, _clause), do: "#{name}/#{arity}"

  # ── Taint ──

  # The variables bound in the params pattern, then every variable bound
  # from an expression that mentions a tainted one, until nothing changes.
  defp taint(pattern, body) do
    bindings = bindings(body)
    fixpoint(vars(pattern), bindings)
  end

  defp fixpoint(tainted, bindings) do
    grown =
      Enum.reduce(bindings, tainted, fn {pattern, expression}, acc ->
        if mentions?(expression, acc), do: MapSet.union(acc, vars(pattern)), else: acc
      end)

    if MapSet.equal?(grown, tainted), do: tainted, else: fixpoint(grown, bindings)
  end

  defp bindings(body) do
    for {op, _, [pattern, expression]} when op in [:=, :<-] <- Macro.prewalker(body),
        do: {pattern, expression}
  end

  # A pin matches an existing value and binds nothing, so the walk drops
  # the pinned subtree. Skipping it in place, not subtracting pinned names
  # afterwards, keeps the new `x` that `{^x, x} = ...` binds.
  defp vars(pattern) do
    {_ast, names} =
      Macro.prewalk(pattern, MapSet.new(), fn
        {:^, _, _pinned}, acc ->
          {nil, acc}

        {name, _, context} = node, acc when is_atom(name) and is_atom(context) ->
          if String.starts_with?(Atom.to_string(name), "_"),
            do: {node, acc},
            else: {node, MapSet.put(acc, name)}

        node, acc ->
          {node, acc}
      end)

    names
  end

  defp mentions?(ast, tainted) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {name, _, context} when is_atom(name) and is_atom(context) -> MapSet.member?(tainted, name)
      _node -> false
    end)
  end

  # ── Repo lookups ──

  defp lookups(body, tainted, aliases, contexts, params) do
    body
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {:|>, _, [left, {{:., _, _} = callee, meta, args}]} when is_list(args) ->
        lookup({callee, meta, [left | args]}, tainted, aliases, contexts, params)

      {{:., _, _}, _, args} = node when is_list(args) ->
        lookup(node, tainted, aliases, contexts, params)

      _node ->
        []
    end)
    |> Enum.uniq_by(fn {_written, start} -> start end)
    |> Enum.sort_by(&elem(&1, 1))
  end

  defp lookup(
         {{:., _, [{:__aliases__, alias_meta, _} = module_ast, fun]}, meta, args},
         tainted,
         aliases,
         contexts,
         params
       )
       when is_atom(fun) do
    module = ModuleIndex.expand(module_ast, aliases)

    if is_atom(module) and lookup?(module, fun, contexts, params) and mentions?(args, tainted) do
      start = {alias_meta[:line] || meta[:line], alias_meta[:column] || meta[:column]}
      [{"#{Macro.to_string(module_ast)}.#{fun}", start}]
    else
      []
    end
  end

  defp lookup(_call, _tainted, _aliases, _contexts, _params), do: []

  defp ash?(module) when is_atom(module),
    do: module |> Atom.to_string() |> String.starts_with?("Elixir.Ash.")

  defp ash?(_module), do: false

  defp lookup?(module, fun, contexts, params) do
    (fun in @lookups and NameFilter.matches_any?(module, Keyword.fetch!(params, :repo_modules))) or
      (MapSet.member?(contexts, module) and
         NameFilter.matches_any?(
           "#{inspect(module)}.#{fun}",
           Keyword.fetch!(params, :lookup_functions)
         ))
  end

  # ── Scope evidence ──

  defp scoped?(clause, aliases, params) do
    scope_assigns = Keyword.fetch!(params, :scope_assigns)

    {clause.args, clause.body}
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:assigns, {:%{}, _, pairs}} ->
        Enum.any?(pairs, fn {key, _value} -> key in scope_assigns end)

      {{:., _, [_base, key]}, _, []} when is_atom(key) ->
        key in scope_assigns

      {{:., _, [Access, :get]}, _, [_base, key]} when is_atom(key) ->
        key in scope_assigns

      {{:., _, [module_ast, fun]}, _, args} when is_atom(fun) and is_list(args) ->
        NameFilter.matches_any?(
          qualified(module_ast, fun, aliases),
          Keyword.fetch!(params, :authorizers)
        )

      {fun, _, args} when is_atom(fun) and is_list(args) ->
        NameFilter.matches_any?(Atom.to_string(fun), Keyword.fetch!(params, :authorizers))

      _node ->
        false
    end)
  end

  defp qualified(module_ast, fun, aliases) do
    case ModuleIndex.expand(module_ast, aliases) do
      module when is_atom(module) -> "#{inspect(module)}.#{fun}"
      _dynamic -> Atom.to_string(fun)
    end
  end
end
